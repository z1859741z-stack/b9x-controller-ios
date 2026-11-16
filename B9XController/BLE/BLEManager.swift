import CoreBluetooth
import Foundation

/// 扫描到的设备。
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int

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

/// 底层 BLE：扫描、连接、GATT 发现、FFE1 写、FFE4 通知。
///
/// 对应 Flutter 项目的 Kotlin/WinRT 两端实现 + `ble_bridge.dart` 的通道语义，
/// 用 CoreBluetooth 重写。所有回调都在主队列。
///
/// 下行队列（§5，照搬原版 BleWriteQueue）：回调驱动，一次只一个在途；
/// 前一条写完（`didWriteValueFor` 回调）才发下一条；写失败或 2.5 秒超时
/// → 重试 1 次，仍失败则丢弃并走 `onWriteError`。
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var connection: BLEConnectionState = .idle
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published var error: String?
    /// 蓝牙状态中文描述（数据与高级 → 诊断）。
    @Published private(set) var bluetoothState: String = "未知"

    /// 收到 FFE4 通知的原始字节，由上层解析。
    var onData: ((Data) -> Void)?

    /// 中央管理器就绪（蓝牙已开启）时回调。
    var onReady: (() -> Void)?

    /// 写失败 / 丢弃命令时回调（上层记日志）。主队列调用。
    var onWriteError: ((String) -> Void)?
    /// 写成功确认时回调（供 Freeze/模式事务参考）。主队列调用。
    var onWriteAck: (() -> Void)?
    /// 一般性日志（丢弃、重订阅等）。主队列调用。
    var onLog: ((String) -> Void)?

    /// 最近一次写成功确认的时间。
    private(set) var lastWriteAckAt: Date?
    /// 最近一次收到 FFE4 通知的时间。
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

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private let serviceUUID = CBUUID(string: B9XProtocol.serviceUUID)
    private let writeUUID = CBUUID(string: B9XProtocol.writeCharUUID)
    private let notifyUUID = CBUUID(string: B9XProtocol.notifyCharUUID)

    /// 是否允许断线自动重连（用户主动断开时为 false）。
    var autoReconnectEnabled = true
    private var userDisconnected = false
    private var reconnectAttempts = 0
    private var reconnectWorkItem: DispatchWorkItem?

    private static let lastDeviceKey = "b9x.lastDeviceIdentifier"

    // ------------------------------------------------------------ 下行队列

    private struct QueuedWrite {
        let data: Data
        let key: String?
        let completion: ((Bool) -> Void)?
        var retries: Int = 0
    }

    private let writeQueue = DispatchQueue(label: "com.b9x.controller.bleWrite")
    private var pending: [QueuedWrite] = []
    private var inFlight: QueuedWrite?
    private var writeTimeoutWorkItem: DispatchWorkItem?
    private var withoutResponseWorkItem: DispatchWorkItem?
    /// 写暂停（固件读取期间暂停——本工程暂不触发，结构保留）。
    private var writesSuspended = false

    private static let commandGap: TimeInterval = 0.045
    private static let writeTimeout: TimeInterval = 2.5
    private static let maxRetries = 1

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
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScan() {
        central.stopScan()
        if connection == .scanning {
            connection = .idle
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
        connection = .connecting
        self.peripheral = peripheral
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        userDisconnected = true
        reconnectWorkItem?.cancel()
        clearWriteQueue()
        connection = .disconnecting
        if let peripheral = peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            connection = .idle
        }
        UserDefaults.standard.removeObject(forKey: Self.lastDeviceKey)
    }

    /// 启动时自动连上次的设备（iOS 替代“游戏检测自动联动”的一部分：
    /// 打开 App 即恢复上次连接与模式）。
    func autoConnectLastDevice() {
        guard let idString = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
              let id = UUID(uuidString: idString),
              central.state == .poweredOn else { return }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        userDisconnected = false
        connection = .connecting
        self.peripheral = peripheral
        central.connect(peripheral, options: nil)
    }

    func hasLastDevice() -> Bool {
        UserDefaults.standard.string(forKey: Self.lastDeviceKey) != nil
    }

    /// 重新订阅 FFE4 通知（READY 超时 4 秒未收到状态时由上层调用）。
    func reenableNotifications() {
        guard let peripheral = peripheral, let notifyChar = notifyChar else { return }
        peripheral.setNotifyValue(true, for: notifyChar)
        DispatchQueue.main.async { [weak self] in
            self?.onLog?("已重新订阅 FFE4 通知")
        }
    }

    // ------------------------------------------------------------ 下行

    /// 未连接时入队的命令直接丢弃并记日志（与 Flutter 一致）。
    func enqueue(_ data: Data, key: String? = nil, completion: ((Bool) -> Void)? = nil) {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            if self.connection != .connected || self.writeChar == nil {
                DispatchQueue.main.async {
                    self.onLog?("未连接，丢弃命令 \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    completion?(false)
                }
                return
            }
            if let key = key,
               let index = self.pending.firstIndex(where: { $0.key == key }) {
                // 同 key 合并：移除旧待发项并调其回调 false。
                let old = self.pending[index]
                self.pending[index] = QueuedWrite(data: data, key: key, completion: completion)
                DispatchQueue.main.async { old.completion?(false) }
                return
            }
            self.pending.append(QueuedWrite(data: data, key: key, completion: completion))
            self.pumpLocked()
        }
    }

    func enqueueMany(_ packets: [Data]) {
        for packet in packets {
            enqueue(packet)
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
            let dropped = self.pending
            self.pending.removeAll()
            if let item = self.inFlight {
                self.inFlight = nil
                DispatchQueue.main.async { item.completion?(false) }
            }
            for item in dropped {
                DispatchQueue.main.async { item.completion?(false) }
            }
        }
    }

    /// 只在 writeQueue 上调用。
    private func pumpLocked() {
        guard !writesSuspended, inFlight == nil, let item = pending.first else { return }
        pending.removeFirst()
        guard let peripheral = peripheral,
              let writeChar = writeChar,
              connection == .connected else {
            // 队列里残留的命令在断开瞬间可能走到这里：丢弃并继续。
            DispatchQueue.main.async { item.completion?(false) }
            pumpLocked()
            return
        }
        inFlight = item
        // 写类型自适应：特征含 .write 用 .withResponse，否则用 .withoutResponse
        //（v1 无条件 withoutResponse——若特征不支持会被 iOS 静默丢弃）。
        let type: CBCharacteristicWriteType =
            writeChar.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(item.data, for: writeChar, type: type)
        if type == .withResponse {
            let workItem = DispatchWorkItem { [weak self] in
                self?.handleWriteTimeout()
            }
            writeTimeoutWorkItem = workItem
            writeQueue.asyncAfter(deadline: .now() + Self.writeTimeout, execute: workItem)
        } else {
            // withoutResponse 没有 didWriteValueFor 回调：按固定间隔推进。
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.writeQueue.async {
                    guard self.inFlight?.data == item.data else { return }
                    self.inFlight = nil
                    DispatchQueue.main.async { item.completion?(true) }
                    self.pumpLocked()
                }
            }
            withoutResponseWorkItem = workItem
            writeQueue.asyncAfter(deadline: .now() + Self.commandGap, execute: workItem)
        }
    }

    /// 只在 writeQueue 上调用（超时 / 写失败回调的公共处理）。
    private func failInFlightLocked(errorMessage: String) {
        guard var item = inFlight else { return }
        writeTimeoutWorkItem?.cancel()
        writeTimeoutWorkItem = nil
        withoutResponseWorkItem?.cancel()
        withoutResponseWorkItem = nil
        if item.retries < Self.maxRetries {
            item.retries += 1
            inFlight = item
            // 队首重入队：重试 1 次。
            if let peripheral = peripheral,
               let writeChar = writeChar,
               connection == .connected {
                let type: CBCharacteristicWriteType =
                    writeChar.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral.writeValue(item.data, for: writeChar, type: type)
                if type == .withResponse {
                    let workItem = DispatchWorkItem { [weak self] in
                        self?.handleWriteTimeout()
                    }
                    writeTimeoutWorkItem = workItem
                    writeQueue.asyncAfter(deadline: .now() + Self.writeTimeout, execute: workItem)
                } else {
                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.writeQueue.async {
                            guard self.inFlight?.data == item.data else { return }
                            self.inFlight = nil
                            DispatchQueue.main.async { item.completion?(true) }
                            self.pumpLocked()
                        }
                    }
                    withoutResponseWorkItem = workItem
                    writeQueue.asyncAfter(deadline: .now() + Self.commandGap, execute: workItem)
                }
            } else {
                inFlight = nil
                DispatchQueue.main.async { item.completion?(false) }
                pumpLocked()
            }
            return
        }
        inFlight = nil
        DispatchQueue.main.async { [weak self] in
            self?.onWriteError?(errorMessage)
            item.completion?(false)
        }
        pumpLocked()
    }

    private func handleWriteTimeout() {
        writeQueue.async { [weak self] in
            guard let self = self, self.inFlight != nil else { return }
            self.failInFlightLocked(errorMessage: "写超时（2.5 秒无确认），已丢弃")
        }
    }

    // ------------------------------------------------------------ 重连

    private func scheduleReconnect() {
        guard autoReconnectEnabled, !userDisconnected,
              let peripheral = peripheral else { return }
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(min(reconnectAttempts, 4))), 30.0)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.userDisconnected,
                  self.connection != .connected else { return }
            self.connection = .connecting
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
            if connection != .idle { connection = .idle }
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
        // 按 B9X 系列名过滤（与 Flutter 端 supportedNames 一致，另放行 Flydigi 前缀）。
        let matched = B9XProtocol.supportedNames.contains(name)
            || name.hasPrefix("Flydigi ")
        guard matched else { return }
        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        devices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.error = "连接失败：\(error?.localizedDescription ?? "未知错误")"
        connection = .idle
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        clearWriteQueue()
        writeChar = nil
        notifyChar = nil
        connection = .idle
        if let error = error {
            self.error = "连接已断开：\(error.localizedDescription)"
        }
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            self.error = "发现服务失败：\(error.localizedDescription)"
            connection = .idle
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            self.error = "未找到 FFE0 服务"
            connection = .idle
            return
        }
        peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            self.error = "发现特征失败：\(error.localizedDescription)"
            connection = .idle
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == writeUUID {
                writeChar = characteristic
            } else if characteristic.uuid == notifyUUID {
                notifyChar = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        guard writeChar != nil, notifyChar != nil else {
            self.error = "未找到 FFE1/FFE4 特征"
            connection = .idle
            return
        }
        reconnectAttempts = 0
        connection = .connected
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastDeviceKey)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              characteristic.uuid == notifyUUID,
              let data = characteristic.value else { return }
        lastNotifyAt = Date()
        onData?(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == writeUUID else { return }
        writeQueue.async { [weak self] in
            guard let self = self, self.inFlight != nil else { return }
            if let error = error {
                self.failInFlightLocked(errorMessage: "写失败：\(error.localizedDescription)")
                return
            }
            self.writeTimeoutWorkItem?.cancel()
            self.writeTimeoutWorkItem = nil
            let item = self.inFlight
            self.inFlight = nil
            self.lastWriteAckAt = Date()
            DispatchQueue.main.async { [weak self] in
                self?.onWriteAck?()
                item?.completion?(true)
            }
            self.pumpLocked()
        }
    }
}
