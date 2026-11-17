import CoreBluetooth
import Foundation

/// 扫描到的设备。
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int

    /// 按广播名映射的通道（匹配不到按飞智处理）。
    var channel: DeviceChannel {
        DeviceChannel.fromAdvertisedName(name) ?? .flydigi
    }

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }
}

enum BLEConnectionState: String {
    case idle = "未连接"
    case scanning = "扫描中"
    case connecting = "连接中"
    case connected = "已连接"
    case disconnecting = "断开中"
}

/// 写失败原因（DEEP-DIVE §2.2 `Batch.completion` 的 Result 载荷）。
enum ControlFailure: Error {
    case timeout
    case disconnected
    case writeFailed(String)
    case freezeGateExpired
    case cancelled

    var message: String {
        switch self {
        case .timeout: return "写超时，已丢弃"
        case .disconnected: return "设备未连接，已丢弃"
        case .writeFailed(let detail): return "写失败：\(detail)"
        case .freezeGateExpired: return "等待退出超频超时，已丢弃"
        case .cancelled: return "已取消"
        }
    }
}

/// 底层 BLE：扫描、连接、GATT 发现、多通道写、通知。
///
/// 写队列（DEEP-DIVE §2.2，照搬原版 `BluetoothTransport`）：
/// Batch 分组 + pump 排空（一次一在途）+ 写前查
/// `canSendWriteWithoutResponse` 背压 + generation 代际号 +
/// Freeze 门控 + armDrainTimeout / armRequestTimeout 两套超时。
/// 所有回调都在主队列；队列状态只在 writeQueue 上改。
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var connection: BLEConnectionState = .idle
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published var error: String?
    /// 蓝牙状态中文描述（数据与高级 → 诊断）。
    @Published private(set) var bluetoothState: String = "未知"

    /// 收到通知特征的原始字节，由上层解析。
    var onData: ((Data) -> Void)?

    /// 中央管理器就绪（蓝牙已开启）时回调。
    var onReady: (() -> Void)?

    /// 写失败 / 丢弃命令时回调（上层记日志）。主队列调用。
    var onWriteError: ((String) -> Void)?
    /// 写成功确认时回调（供 Freeze/模式事务参考）。主队列调用。
    var onWriteAck: (() -> Void)?
    /// 一般性日志（丢弃、重订阅等）。主队列调用。
    var onLog: ((String) -> Void)?
    /// 连接阶段变化（供 CoolerController.phase 用）。主队列调用。
    var onPhase: ((ConnectionPhase) -> Void)?
    /// 服务发现确认通道后回调。主队列调用。
    var onChannel: ((DeviceChannel) -> Void)?
    /// Freeze 门控触发：某请求要求先退 Freeze 时回调，上层退 Freeze 后
    /// 调 `notifyFreezeOff()`（或把 `freezeOn` 置 false）恢复排空。
    /// 主队列调用。
    var onFreezeOffRequested: (() -> Void)?

    /// 最近一次写成功确认的时间。
    private(set) var lastWriteAckAt: Date?
    /// 最近一次收到通知的时间。
    private(set) var lastNotifyAt: Date?

    /// 当前写特征的实际写类型（诊断页显示）。
    var writeModeDescription: String {
        guard let writeChar = writeChar else { return "未发现写特征" }
        if writeChar.properties.contains(.write) {
            return "withResponse (.write)"
        }
        if writeChar.properties.contains(.writeWithoutResponse) {
            return "withoutResponse (.writeWithoutResponse)"
        }
        return "未知（特征无写属性）"
    }

    /// 是否已发现 Telink OTA 特征（刷固件前检查）。
    var hasOTACharacteristic: Bool { otaChar != nil }

    /// 连接代际号：每次连接 +1，过期 Batch/回调凭它丢弃。
    private(set) var generation: UInt64 = 0
    /// 当前发现的通道（由服务发现确认；扫描时先按广播名推断）。
    private(set) var activeChannel: DeviceChannel = .flydigi
    /// 设备 Freeze 状态镜像（由 CoolerController 同步）；为真时
    /// `requiresFreezeOff` 的请求先走 Freeze 门控。
    var freezeOn: Bool = false {
        didSet {
            guard freezeOn != oldValue else { return }
            writeQueue.async { [weak self] in self?.pumpLocked() }
        }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var otaChar: CBCharacteristic?

    private let serviceUUID = CBUUID(string: Secrets.flydigiServiceUUID)
    private let writeUUID = CBUUID(string: Secrets.flydigiWriteUUID)
    private let notifyUUID = CBUUID(string: Secrets.flydigiNotifyUUID)
    private let otaServiceUUID = CBUUID(string: Secrets.telinkOTAServiceUUID)
    private let otaUUID = CBUUID(string: Secrets.telinkOTACharacteristicUUID)
    private let redMagicServiceUUID = CBUUID(string: Secrets.redMagicServiceUUIDs[0])
    private let redMagicNotifyUUID = CBUUID(string: Secrets.redMagicServiceUUIDs[1])
    private let redMagicWriteUUID = CBUUID(string: Secrets.redMagicServiceUUIDs[2])
    private let blackSharkServiceUUID = CBUUID(string: Secrets.blackSharkServiceUUID)
    private let blackSharkServiceUUID2 = CBUUID(string: Secrets.blackSharkServiceUUID2)

    /// 是否允许断线自动重连（用户主动断开时为 false）。
    var autoReconnectEnabled = true
    private var userDisconnected = false
    private var reconnectAttempts = 0
    private var reconnectWorkItem: DispatchWorkItem?
    /// 自动重连上限：只恢复 BLE 会话，不自动开机、不恢复模式。
    private static let maxReconnectAttempts = 3

    private static let lastDeviceKey = "b9x.lastDeviceIdentifier"

    // ------------------------------------------------------------ 下行队列（Batch + pump）

    /// 一批 GATT 请求（DEEP-DIVE §2.2 `Batch`）。
    private final class Batch {
        let id = UUID()
        var requests: [GATTRequest]
        var index = 0
        let generation: UInt64
        let priority: Int
        /// enqueue(Data) 的同 key 合并键；批量入队为 nil。
        let key: String?
        var cancelled = false
        var retries = 0
        var completion: ((Result<Void, ControlFailure>) -> Void)?
        var freezeGateDeadline: Date?
        var freezeOffRequestedAt: Date?

        init(requests: [GATTRequest], generation: UInt64, priority: Int, key: String?,
             completion: ((Result<Void, ControlFailure>) -> Void)?) {
            self.requests = requests
            self.generation = generation
            self.priority = priority
            self.key = key
            self.completion = completion
        }
    }

    private let writeQueue = DispatchQueue(label: "com.b9x.controller.bleWrite")
    /// 待发批（按 priority 降序；同优先级保持入队顺序）。
    private var batches: [Batch] = []
    private var inFlightBatch: Batch?
    /// 在途唯一：一条写未确认前不发下一条。
    private var waitingForCallback = false
    /// 背压：无写容量时等 peripheralIsReady 回调。
    private var waitingForWriteCapacity = false
    private var writeTimeoutWorkItem: DispatchWorkItem?
    private var withoutResponseWorkItem: DispatchWorkItem?
    private var drainTimeoutWorkItem: DispatchWorkItem?
    private var requestTimeoutToken: UUID?
    private var freezeGateWorkItem: DispatchWorkItem?
    /// 写暂停（固件读取期间暂停——本工程暂不触发，结构保留）。
    private var writesSuspended = false

    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var scanTimeoutWorkItem: DispatchWorkItem?

    /// 静默看门狗：超过 5 秒没收到 notify 才补发一次单字节 [0x13]。
    private var watchdogTimer: Timer?
    private var watchdogPollSent = false

    private static let commandGap: TimeInterval = 0.045
    private static let writeTimeout: TimeInterval = 2.5
    private static let drainTimeout: TimeInterval = 15
    private static let maxRetries = 1
    private static let freezeGateTimeout: TimeInterval = 10
    private static let scanTimeout: TimeInterval = 10
    private static let connectTimeout: TimeInterval = 5
    private static let notifyWatchdogInterval: TimeInterval = 5

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.b9x.controller.central",
                CBCentralManagerOptionShowPowerAlertKey: true,
            ]
        )
    }

    // ------------------------------------------------------------ 扫描与连接

    func ensureReady() -> Bool {
        central.state == .poweredOn
    }

    func startScan() {
        error = nil
        devices = []
        guard central.state == .poweredOn else {
            error = "蓝牙未开启"
            return
        }
        connection = .scanning
        reportPhase(.scanning)
        // 不带 service 过滤（与官方一致）：didDiscover 里按名字精确匹配。
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        scanTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.connection == .scanning else { return }
            self.central.stopScan()
            self.connection = .idle
            self.reportPhase(.idle)
            self.onLog?("扫描超时（10 秒），未发现设备")
        }
        scanTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanTimeout, execute: workItem)
    }

    func stopScan() {
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        central.stopScan()
        if connection == .scanning {
            connection = .idle
            reportPhase(.idle)
        }
    }

    func connect(_ device: DiscoveredDevice) {
        error = nil
        userDisconnected = false
        reconnectAttempts = 0
        reconnectWorkItem?.cancel()
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [device.id]).first else {
            error = "找不到该设备"
            return
        }
        activeChannel = device.channel
        generation += 1
        connection = .connecting
        reportPhase(.connecting)
        self.peripheral = peripheral
        central.stopScan()
        scanTimeoutWorkItem?.cancel()
        armConnectionTimeout(for: peripheral)
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        userDisconnected = true
        reconnectWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        stopWatchdog()
        clearWriteQueue()
        connection = .disconnecting
        if let peripheral = peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            connection = .idle
            reportPhase(.disconnected)
        }
        UserDefaults.standard.removeObject(forKey: Self.lastDeviceKey)
    }

    /// 固件刷写后设备重启：不断 lastDevice、不标记用户断开，
    /// 等设备重启后由自动重连（最多 3 次）接回。
    func disconnectForFirmwareReboot() {
        reconnectAttempts = 0
        stopWatchdog()
        clearWriteQueue()
        if let peripheral = peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    /// 启动时自动连上次的设备（iOS 替代“游戏检测自动联动”的一部分：
    /// 打开 App 即恢复上次连接与模式）。
    func autoConnectLastDevice() {
        guard let idString = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
              let id = UUID(uuidString: idString),
              central.state == .poweredOn else { return }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        userDisconnected = false
        generation += 1
        connection = .connecting
        reportPhase(.connecting)
        self.peripheral = peripheral
        armConnectionTimeout(for: peripheral)
        central.connect(peripheral, options: nil)
    }

    func hasLastDevice() -> Bool {
        UserDefaults.standard.string(forKey: Self.lastDeviceKey) != nil
    }

    /// 重新订阅通知特征（READY 超时 4 秒未收到状态时由上层调用）。
    func reenableNotifications() {
        guard let peripheral = peripheral, let notifyChar = notifyChar else { return }
        peripheral.setNotifyValue(true, for: notifyChar)
        DispatchQueue.main.async { [weak self] in
            self?.onLog?("已重新订阅通知特征")
        }
    }

    /// Freeze 已退出：恢复被门控挡住的排空。
    func notifyFreezeOff() {
        freezeOn = false
        writeQueue.async { [weak self] in
            self?.freezeGateWorkItem?.cancel()
            self?.freezeGateWorkItem = nil
            self?.pumpLocked()
        }
    }

    // ------------------------------------------------------------ 下行

    /// 未连接时入队的命令直接丢弃并记日志（与 Flutter 一致）。
    func enqueue(_ data: Data, key: String? = nil, completion: ((Bool) -> Void)? = nil) {
        let request = GATTRequest(payload: data)
        enqueueBatch([request], priority: 0, key: key) { result in
            switch result {
            case .success: completion?(true)
            case .failure: completion?(false)
            }
        }
    }

    func enqueueMany(_ packets: [Data]) {
        for packet in packets {
            enqueue(packet)
        }
    }

    /// 批量入队（固件分包、LCD 上传、魔方灯效用）。按 priority 排空，
    /// 完成时回调整体结果。
    func enqueueBatch(
        _ requests: [GATTRequest],
        priority: Int = 0,
        key: String? = nil,
        completion: ((Result<Void, ControlFailure>) -> Void)? = nil
    ) {
        guard !requests.isEmpty else {
            completion?(.success(()))
            return
        }
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            if self.connection != .connected || self.writeChar == nil {
                DispatchQueue.main.async {
                    self.onLog?("未连接，丢弃命令 \(requests.map { $0.payload.map { String(format: "%02X", $0) }.joined(separator: " ") }.joined(separator: " | "))")
                    completion?(.failure(.disconnected))
                }
                return
            }
            // 同 key 合并：替换旧待发项并调其回调 false（在途项不动）。
            if let key = key,
               let index = self.batches.firstIndex(where: { $0.key == key && $0 !== self.inFlightBatch }) {
                let old = self.batches[index]
                let replacement = Batch(
                    requests: requests, generation: self.generation,
                    priority: priority, key: key, completion: completion
                )
                self.batches[index] = replacement
                let oldCompletion = old.completion
                DispatchQueue.main.async { oldCompletion?(.failure(.cancelled)) }
                return
            }
            let batch = Batch(
                requests: requests, generation: self.generation,
                priority: priority, key: key, completion: completion
            )
            // 按 priority 降序插入；同优先级保持入队顺序。
            let insertAt = self.batches.firstIndex(where: { $0.priority < priority }) ?? self.batches.endIndex
            self.batches.insert(batch, at: insertAt)
            self.armDrainTimeout()
            self.pumpLocked()
        }
    }

    /// 批量入队的 async 桥接（固件刷写用）。
    func enqueueBatch(_ requests: [GATTRequest], priority: Int = 0) async -> Result<Void, ControlFailure> {
        await withCheckedContinuation { continuation in
            enqueueBatch(requests, priority: priority) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// 取消全部待发与在途 Batch（固件取消用）。
    func cancelAllBatches() {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            self.writeTimeoutWorkItem?.cancel()
            self.writeTimeoutWorkItem = nil
            self.withoutResponseWorkItem?.cancel()
            self.withoutResponseWorkItem = nil
            self.drainTimeoutWorkItem?.cancel()
            self.drainTimeoutWorkItem = nil
            self.freezeGateWorkItem?.cancel()
            self.freezeGateWorkItem = nil
            self.requestTimeoutToken = nil
            let dropped = self.batches
            self.batches.removeAll()
            self.waitingForCallback = false
            self.waitingForWriteCapacity = false
            if let item = self.inFlightBatch {
                self.inFlightBatch = nil
                let completion = item.completion
                DispatchQueue.main.async { completion?(.failure(.cancelled)) }
            }
            for item in dropped {
                let completion = item.completion
                DispatchQueue.main.async { completion?(.failure(.cancelled)) }
            }
        }
    }

    /// 暂停写队列（固件读取期间用；本工程暂不触发）。
    func suspendWrites() {
        writeQueue.async { [weak self] in
            self?.writesSuspended = true
        }
    }

    func resumeWrites() {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            self.writesSuspended = false
            self.pumpLocked()
        }
    }

    /// 断开时调用：清队列、取消超时计时、在途项回调 false。
    private func clearWriteQueue() {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            self.writeTimeoutWorkItem?.cancel()
            self.writeTimeoutWorkItem = nil
            self.withoutResponseWorkItem?.cancel()
            self.withoutResponseWorkItem = nil
            self.drainTimeoutWorkItem?.cancel()
            self.drainTimeoutWorkItem = nil
            self.freezeGateWorkItem?.cancel()
            self.freezeGateWorkItem = nil
            self.requestTimeoutToken = nil
            self.waitingForCallback = false
            self.waitingForWriteCapacity = false
            let dropped = self.batches
            self.batches.removeAll()
            if let item = self.inFlightBatch {
                self.inFlightBatch = nil
                let completion = item.completion
                DispatchQueue.main.async { completion?(.failure(.cancelled)) }
            }
            for item in dropped {
                let completion = item.completion
                DispatchQueue.main.async { completion?(.failure(.cancelled)) }
            }
        }
    }

    private func reportPhase(_ phase: ConnectionPhase) {
        DispatchQueue.main.async { [weak self] in
            self?.onPhase?(phase)
        }
    }

    // ------------------------------------------------------------ pump 与超时

    /// 只在 writeQueue 上调用。
    private func pumpLocked() {
        guard !writesSuspended, !waitingForCallback, !waitingForWriteCapacity else { return }
        // 丢弃已取消或代际过期的队首 Batch。
        while let first = batches.first {
            if first.cancelled || first.generation != generation {
                batches.removeFirst()
                let completion = first.completion
                DispatchQueue.main.async { completion?(.failure(.cancelled)) }
                continue
            }
            break
        }
        guard let batch = batches.first else { return }
        guard batch.index < batch.requests.count else {
            finishBatch(batch, result: .success(()))
            pumpLocked()
            return
        }
        let request = batch.requests[batch.index]
        // Freeze 门控：requiresFreezeOff 的请求先退 Freeze。
        if request.requiresFreezeOff && freezeOn {
            if batch.freezeOffRequestedAt == nil {
                batch.freezeOffRequestedAt = Date()
                batch.freezeGateDeadline = Date().addingTimeInterval(Self.freezeGateTimeout)
                DispatchQueue.main.async { [weak self] in
                    self?.onFreezeOffRequested?()
                }
                // 门控截止时再跑一次 pump，届时按过期丢弃。
                let workItem = DispatchWorkItem { [weak self] in
                    self?.writeQueue.async { self?.pumpLocked() }
                }
                freezeGateWorkItem?.cancel()
                freezeGateWorkItem = workItem
                writeQueue.asyncAfter(deadline: .now() + Self.freezeGateTimeout, execute: workItem)
            } else if let deadline = batch.freezeGateDeadline, Date() > deadline {
                finishBatch(batch, result: .failure(.freezeGateExpired))
                pumpLocked()
            }
            return
        }
        guard let peripheral = peripheral,
              let characteristic = resolveCharacteristic(for: request),
              connection == .connected else {
            finishBatch(batch, result: .failure(.disconnected))
            pumpLocked()
            return
        }
        // 写类型自适应：特征含 .write 用 .withResponse，否则用 .withoutResponse
        //（v1 无条件 withoutResponse——若特征不支持会被 iOS 静默丢弃）。
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        // 背压：withoutResponse 写前查容量，没容量就等 peripheralIsReady 回调。
        if type == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
            waitingForWriteCapacity = true
            return
        }
        inFlightBatch = batch
        waitingForCallback = true
        peripheral.writeValue(request.payload, for: characteristic, type: type)
        if type == .withResponse {
            armRequestTimeout(batch: batch)
        } else {
            // withoutResponse 没有 didWriteValueFor 回调：按固定间隔推进。
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.writeQueue.async {
                    guard self.inFlightBatch === batch else { return }
                    self.lastWriteAckAt = Date()
                    DispatchQueue.main.async { self.onWriteAck?() }
                    self.advanceBatchLocked(batch)
                }
            }
            withoutResponseWorkItem?.cancel()
            withoutResponseWorkItem = workItem
            writeQueue.asyncAfter(deadline: .now() + Self.commandGap, execute: workItem)
        }
    }

    /// 只在 writeQueue 上调用：解析请求的目标特征。
    private func resolveCharacteristic(for request: GATTRequest) -> CBCharacteristic? {
        if request.isOTA { return otaChar }
        if let characteristic = request.characteristic { return characteristic }
        return writeChar
    }

    /// 只在 writeQueue 上调用：本批写完，回调并继续排空下一批。
    private func finishBatch(_ batch: Batch, result: Result<Void, ControlFailure>) {
        if let index = batches.firstIndex(where: { $0 === batch }) {
            batches.remove(at: index)
        }
        if inFlightBatch === batch {
            inFlightBatch = nil
        }
        waitingForCallback = false
        let completion = batch.completion
        if case .failure(let failure) = result {
            DispatchQueue.main.async { [weak self] in
                self?.onWriteError?(failure.message)
            }
        }
        DispatchQueue.main.async { completion?(result) }
        if batches.isEmpty {
            drainTimeoutWorkItem?.cancel()
            drainTimeoutWorkItem = nil
        }
    }

    /// 只在 writeQueue 上调用：一条写确认后推进到下一条
    ///（delayAfterMilliseconds 的延迟在这里兑现）。
    private func advanceBatchLocked(_ batch: Batch) {
        guard inFlightBatch === batch else { return }
        let finishedRequest = batch.requests[safe: batch.index]
        batch.index += 1
        batch.retries = 0
        inFlightBatch = nil
        waitingForCallback = false
        let delay = finishedRequest?.delayAfterMilliseconds ?? 0
        if delay > 0 {
            writeQueue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                self?.pumpLocked()
            }
        } else {
            pumpLocked()
        }
    }

    /// 只在 writeQueue 上调用（超时 / 写失败回调的公共处理）。
    private func failInFlightLocked(errorMessage: String) {
        guard let batch = inFlightBatch else { return }
        writeTimeoutWorkItem?.cancel()
        writeTimeoutWorkItem = nil
        withoutResponseWorkItem?.cancel()
        withoutResponseWorkItem = nil
        requestTimeoutToken = nil
        if batch.retries < Self.maxRetries {
            batch.retries += 1
            // 队首重入队：重试 1 次。
            guard let peripheral = peripheral,
                  let characteristic = resolveCharacteristic(for: batch.requests[batch.index]),
                  connection == .connected else {
                finishBatch(batch, result: .failure(.disconnected))
                pumpLocked()
                return
            }
            let request = batch.requests[batch.index]
            let type: CBCharacteristicWriteType =
                characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            if type == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
                finishBatch(batch, result: .failure(.writeFailed("无写容量")))
                pumpLocked()
                return
            }
            waitingForCallback = true
            peripheral.writeValue(request.payload, for: characteristic, type: type)
            if type == .withResponse {
                armRequestTimeout(batch: batch)
            } else {
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.writeQueue.async {
                        guard self.inFlightBatch === batch else { return }
                        self.lastWriteAckAt = Date()
                        DispatchQueue.main.async { self.onWriteAck?() }
                        self.advanceBatchLocked(batch)
                    }
                }
                withoutResponseWorkItem = workItem
                writeQueue.asyncAfter(deadline: .now() + Self.commandGap, execute: workItem)
            }
            return
        }
        finishBatch(batch, result: .failure(.writeFailed(errorMessage)))
        pumpLocked()
    }

    /// 单批超时（2.5 秒无确认）。只在 writeQueue 上调用。
    private func armRequestTimeout(batch: Batch) {
        let token = UUID()
        requestTimeoutToken = token
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.writeQueue.async {
                guard self.requestTimeoutToken == token, self.inFlightBatch === batch else { return }
                self.failInFlightLocked(errorMessage: "写超时（2.5 秒无确认），已丢弃")
            }
        }
        writeTimeoutWorkItem?.cancel()
        writeTimeoutWorkItem = workItem
        writeQueue.asyncAfter(deadline: .now() + Self.writeTimeout, execute: workItem)
    }

    /// 排空超时（15 秒队列未排空）：丢弃当前批，继续下一批。
    /// 只在 writeQueue 上调用。
    private func armDrainTimeout() {
        guard drainTimeoutWorkItem == nil, !batches.isEmpty else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.writeQueue.async {
                self.drainTimeoutWorkItem = nil
                guard let batch = self.batches.first else { return }
                self.finishBatch(batch, result: .failure(.timeout))
                self.pumpLocked()
            }
        }
        drainTimeoutWorkItem = workItem
        writeQueue.asyncAfter(deadline: .now() + Self.drainTimeout, execute: workItem)
    }

    /// 连接超时 5 秒：只复位状态与报错，不在这里重试（重连走 scheduleReconnect）。
    private func armConnectionTimeout(for peripheral: CBPeripheral) {
        connectionTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.connection == .connecting else { return }
            self.central.cancelPeripheralConnection(peripheral)
            self.error = "连接超时（5 秒）"
            self.connection = .idle
            self.reportPhase(.failed)
        }
        connectionTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: workItem)
    }

    // ------------------------------------------------------------ 静默看门狗

    private func startWatchdog() {
        stopWatchdog()
        watchdogPollSent = false
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.connection == .connected,
                  self.activeChannel == .flydigi,
                  let last = self.lastNotifyAt,
                  !self.watchdogPollSent,
                  Date().timeIntervalSince(last) > Self.notifyWatchdogInterval else { return }
            self.watchdogPollSent = true
            self.enqueue(B9XProtocol.requestRealtimeState(), key: "watchdog")
            self.onLog?("超过 5 秒未收到设备通知，补发一次状态查询")
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        watchdogPollSent = false
    }

    // ------------------------------------------------------------ 重连

    /// 断开后自动重连只恢复 BLE 会话、不自动开机、不恢复模式
    ///（模式恢复由 CoolerController 在 READY 后另行决定）。
    /// 用 retrievePeripheralsWithIdentifiers 取回已知设备，最多重试 3 次。
    private func scheduleReconnect() {
        guard autoReconnectEnabled, !userDisconnected,
              let peripheral = peripheral else { return }
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            error = "重连 3 次失败，请手动重连"
            reportPhase(.failed)
            return
        }
        reconnectAttempts += 1
        reportPhase(.recovering)
        let delay = min(pow(2.0, Double(min(reconnectAttempts, 4))), 30.0)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.userDisconnected,
                  self.connection != .connected else { return }
            guard let peripheral = self.central.retrievePeripherals(withIdentifiers: [peripheral.identifier]).first else {
                self.scheduleReconnect()
                return
            }
            self.generation += 1
            self.connection = .connecting
            self.reportPhase(.connecting)
            self.peripheral = peripheral
            self.armConnectionTimeout(for: peripheral)
            self.central.connect(peripheral, options: nil)
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothState = "已开启"
            onReady?()
        case .poweredOff:
            bluetoothState = "已关闭"
            error = "蓝牙已关闭"
            if connection != .idle {
                connection = .idle
                reportPhase(.disconnected)
            }
        case .unauthorized:
            bluetoothState = "未授权"
            error = "没有蓝牙权限，请在设置里允许"
        case .unsupported:
            bluetoothState = "不支持"
            error = "此设备不支持蓝牙低功耗"
        case .resetting:
            bluetoothState = "重置中"
        case .unknown:
            bluetoothState = "未知"
        @unknown default:
            bluetoothState = "未知"
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = peripherals.first {
            self.peripheral = peripheral
            peripheral.delegate = self
            generation += 1
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        // 名字精确匹配（飞智四款 / 红魔 / 黑鲨按广播名映射）+ RSSI > -90。
        guard DeviceChannel.fromAdvertisedName(name) != nil else { return }
        guard RSSI.intValue > -90 else { return }
        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        devices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        peripheral.delegate = self
        reportPhase(.discovering)
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        self.error = "连接失败：\(error?.localizedDescription ?? "未知错误")"
        connection = .idle
        reportPhase(.failed)
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        stopWatchdog()
        clearWriteQueue()
        writeChar = nil
        notifyChar = nil
        otaChar = nil
        connection = .idle
        if let error = error {
            self.error = "连接已断开：\(error.localizedDescription)"
        }
        if userDisconnected {
            reportPhase(.disconnected)
        } else {
            scheduleReconnect()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            self.error = "发现服务失败：\(error.localizedDescription)"
            connection = .idle
            reportPhase(.failed)
            return
        }
        let services = peripheral.services ?? []
        // 按已知服务确认通道：飞智优先，其次红魔、黑鲨。
        var matchedService: CBService?
        var channel: DeviceChannel?
        if let service = services.first(where: { $0.uuid == serviceUUID }) {
            matchedService = service
            channel = .flydigi
        } else if let service = services.first(where: { $0.uuid == redMagicServiceUUID }) {
            matchedService = service
            channel = .redMagic
        } else if let service = services.first(where: { $0.uuid == blackSharkServiceUUID || $0.uuid == blackSharkServiceUUID2 }) {
            matchedService = service
            channel = .blackShark
        }
        guard let service = matchedService, let channel = channel else {
            self.error = "未找到已知服务"
            connection = .idle
            reportPhase(.failed)
            return
        }
        activeChannel = channel
        DispatchQueue.main.async { [weak self] in
            self?.onChannel?(channel)
        }
        reportPhase(.subscribing)
        peripheral.discoverCharacteristics(nil, for: service)
        // 飞智/红魔设备若同时暴露 Telink OTA 服务，一并发现其特征。
        if let otaService = services.first(where: { $0.uuid == otaServiceUUID }) {
            peripheral.discoverCharacteristics([otaUUID], for: otaService)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            self.error = "发现特征失败：\(error.localizedDescription)"
            connection = .idle
            reportPhase(.failed)
            return
        }
        for characteristic in service.characteristics ?? [] {
            if service.uuid == serviceUUID {
                if characteristic.uuid == writeUUID {
                    writeChar = characteristic
                } else if characteristic.uuid == notifyUUID {
                    notifyChar = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if service.uuid == otaServiceUUID {
                if characteristic.uuid == otaUUID {
                    otaChar = characteristic
                }
            } else if service.uuid == redMagicServiceUUID {
                // 假设分工（未验证）：服务组第二项通知，第三项写。
                if characteristic.uuid == redMagicWriteUUID {
                    writeChar = characteristic
                } else if characteristic.uuid == redMagicNotifyUUID {
                    notifyChar = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if service.uuid == blackSharkServiceUUID || service.uuid == blackSharkServiceUUID2 {
                // 特征 UUID 未验证：按属性认领（首个通知特征 / 首个可写特征）。
                if notifyChar == nil, characteristic.properties.contains(.notify) {
                    notifyChar = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if writeChar == nil,
                          characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                    writeChar = characteristic
                }
            }
        }
        guard writeChar != nil, notifyChar != nil else { return }
        reconnectAttempts = 0
        connection = .connected
        startWatchdog()
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastDeviceKey)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        if characteristic === notifyChar {
            lastNotifyAt = Date()
            watchdogPollSent = false
            onData?(data)
        } else if characteristic === otaChar {
            // Telink OTA 回执：目前刷写流程只靠写确认推进，不解析回执；
            // 先透传给上层，留待以后按 deviceResult 解析。
            onData?(data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            DispatchQueue.main.async { [weak self] in
                self?.onLog?("订阅通知失败：\(error.localizedDescription)")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic === writeChar || characteristic === otaChar else { return }
        writeQueue.async { [weak self] in
            guard let self = self, let batch = self.inFlightBatch else { return }
            if let error = error {
                self.failInFlightLocked(errorMessage: "写失败：\(error.localizedDescription)")
                return
            }
            self.writeTimeoutWorkItem?.cancel()
            self.writeTimeoutWorkItem = nil
            self.requestTimeoutToken = nil
            self.lastWriteAckAt = Date()
            DispatchQueue.main.async { [weak self] in
                self?.onWriteAck?()
            }
            self.advanceBatchLocked(batch)
        }
    }

    /// 背压解除：有写容量了，继续排空。
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            self.waitingForWriteCapacity = false
            self.pumpLocked()
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
