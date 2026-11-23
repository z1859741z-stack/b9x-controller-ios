import Combine
import CryptoKit
import Foundation
import UIKit
import UserNotifications

/// 运行日志条目（数据与高级 → 运行日志）。
struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String

    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// 可导入导出的设置（对等原版“设置导入导出”）。
struct B9XSettingsExport: Codable {
    var targetTemperature: Int = 16
    var customLevels: [Int] = B9XProtocol.defaultCurveLevels
    var ledType: Int = 3
    var ledColors: [Int] = [0xFF6EE7FF, 0xFF5B8CFF, 0xFFA78BFA, 0xFFFF5D8F]
    var ledPeriod: Int = 40
    var ledLight: Int = 80
    var runMode: Int = 0
    var freezeMode: Bool = false
    var coldProtectionEnabled: Bool = true
    var hotProtectionEnabled: Bool = true
}

/// 更新信息（checkForUpdate 返回）。
struct UpdateInfo {
    let version: String
    let notes: String
    let url: URL
}

/// 业务控制器：把 BLE 字节流翻译成 UI 可用的状态与命令。
/// 行为以 `V2-SPEC.md §3–§5` 为准。
@MainActor
final class CoolerController: ObservableObject {
    static let shared = CoolerController()

    @Published private(set) var state = CoolerState()
    @Published private(set) var connection: BLEConnectionState = .idle
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published var error: String?
    @Published private(set) var phoneThermal = PhoneThermalState.nominal

    /// 连接阶段（BLE 回调映射；READY 只由 onReadyState 置位）。
    @Published private(set) var phase: ConnectionPhase = .idle
    /// 设备通道（由扫描到的广播名 / 服务发现确认）。
    @Published private(set) var channel: DeviceChannel = .flydigi

    /// 固件刷写阶段 / 进度 / 包内镜像。
    @Published private(set) var firmwareStage: FirmwareStage = .idle
    @Published private(set) var firmwareProgress: Double = 0
    @Published private(set) var firmwareImages: [FirmwareImage] = []
    /// 红魔制冷曲线（尽力而为，帧结构未验证）。
    @Published private(set) var redMagicCurveLevels: [Int] = B9XProtocol.defaultCurveLevels
    /// 红魔音频律动 pattern 索引（尽力而为，帧结构未验证）。
    @Published private(set) var redMagicAudioPatternIndex: Int = 0

    /// 刷固件确认短语（UI 原样展示，用户照打）。
    static let firmwareConsentPhrase = "刷固件导致的问题由我自行承担"

    /// 演示模式：没有硬件时预览完整界面。
    @Published var demoMode = false

    /// 连接后自动恢复上次模式（iOS 替代“游戏检测自动联动”的核心：
    /// iOS 不允许读取其他 App 状态，改用“打开即恢复上次模式”+ 快捷指令）。
    @Published var restoreLastModeOnConnect = true

    // ------------------------------------------------------------ 电池与联动
    // iOS 能读到：电池电量、充电状态；读不到：电池温度、CPU/GPU 温度、前台 App。
    @Published private(set) var batteryLevel: Int = -1
    @Published private(set) var batteryCharging: Bool = false

    /// 超频体验 · 自动化待机（联动总开关）。
    @Published var automationStandby = true
    /// 充电随动：手机充电时连接散热器并切换指定模式。
    @Published var chargeFollowEnabled = false
    @Published var chargeFollowMode: Int = B9XProtocol.modeSmart
    /// 游戏联动：iOS 上只能由快捷指令自动化触发，App 内无法直接检测前台游戏。
    @Published var gameLinkageEnabled = false
    /// 手动接管窗口（秒）：手动切换模式后联动暂时不抢回控制。
    @Published var manualOverrideSeconds: Double = 60

    @Published private(set) var logs: [LogEntry] = []

    private var manualOverrideUntil: Date?
    private var automationTimer: Timer?
    private var gameLinkageNoted = false
    private var expectDisconnect = false
    private var notificationTokens: [NSObjectProtocol] = []

    let ble = BLEManager()

    private var cancellables = Set<AnyCancellable>()
    private var thermalLoopTimer: Timer?
    private var thermalTimer: Timer?
    private var bootstrapped = false
    private var didInitAfterConnect = false

    // ------------------------------------------------------------ 事务状态（§3）
    /// 模式切换请求（Freeze 暂存 / 退出后补发 / 恢复上次模式共用）。
    private struct ModeRequest {
        var mode: Int
        var target: Int
        var cold: Int
        var wind: Int
        var coldOC: Int
        var windOC: Int
        var curve: [Int]?
        var manual: Bool
        /// 本地优先时长（模式切换 3 秒；风量滑块 1.5 秒）。
        var localHoldSeconds: TimeInterval = 3
    }

    /// 最近一帧 0x13 回显（事务校验的唯一依据；本地乐观值不参与校验）。
    private var lastEcho: StateEventData?
    private var lastEchoLightOn: Bool?
    /// Freeze 为真时暂存的模式请求（退出确认后补发）。
    private var pendingModeRequest: ModeRequest?
    /// 本地 Freeze 意图（持久化；重连后判断是遗留 Freeze 还是本 App 开的）。
    private var freezeDesired = false
    private var freezeTxInFlight = false
    private var freezeTxTarget = false
    private var freezeSettledHandler: ((Bool) -> Void)?
    private var freezeVerifyWorkItem: DispatchWorkItem?
    private var lastFreezeReassertAt: Date?
    private var modeTxWorkItems: [DispatchWorkItem] = []
    private var lightWorkItems: [DispatchWorkItem] = []
    private var readyWorkItems: [DispatchWorkItem] = []
    private var shutdownWorkItems: [DispatchWorkItem] = []
    private var lightTxAttempt = 0

    /// 软件温控环路：上次下发的档位（去重用）与 Freeze 退出后待补的档位。
    private var thermalLastLevel: Int?
    private var pendingThermalLevel: Int?

    /// 会话状态机（DEEP-DIVE §3）：事件由控制器喂入，效果由控制器执行。
    private var machine = SessionMachine()
    /// 固件刷写取消标志（刷写循环每批检查）。
    private var firmwareFlashCancelled = false
    /// 刷写后等待设备重启重连（该期间断连不记“连接已断开”）。
    private var firmwareReconnectExpected = false
    /// 正在刷的镜像（刷后核对版本用）。
    private var flashingImage: FirmwareImage?
    private var firmwareWaitWorkItem: DispatchWorkItem?

    private enum DefaultsKey {
        static let lastRunMode = "b9x.lastRunMode"
        static let lastTargetTemperature = "b9x.lastTargetTemperature"
        static let lastColdLevel = "b9x.lastColdLevel"
        static let lastWindLevel = "b9x.lastWindLevel"
        static let lastColdLevelOC = "b9x.lastColdLevelOC"
        static let lastWindLevelOC = "b9x.lastWindLevelOC"
        static let hasLastMode = "b9x.hasLastMode"
        static let lastCustomLevels = "b9x.lastCustomLevels"
        static let freezeDesired = "b9x.freezeDesired"
    }

    init() {
        freezeDesired = UserDefaults.standard.bool(forKey: DefaultsKey.freezeDesired)
        ble.$connection.assign(to: &$connection)
        ble.$devices.assign(to: &$devices)
        ble.$error.assign(to: &$error)
        ble.$connection
            .sink { [weak self] newValue in
                Task { @MainActor [weak self] in
                    self?.handleConnectionChange(newValue)
                }
            }
            .store(in: &cancellables)
        ble.onData = { [weak self] data in
            Task { @MainActor [weak self] in
                self?.onData(data)
            }
        }
        ble.onReady = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, !self.demoMode else { return }
                self.ble.autoConnectLastDevice()
            }
        }
        ble.onWriteError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.log("蓝牙写失败：\(message)")
            }
        }
        ble.onLog = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.log(message)
            }
        }
        ble.onPhase = { [weak self] phase in
            Task { @MainActor [weak self] in
                self?.setPhase(phase)
            }
        }
        ble.onChannel = { [weak self] channel in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.channel = channel
                self.state.channel = channel
            }
        }
        ble.onFreezeOffRequested = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // BLE 层有请求被 Freeze 门控挡住：退 Freeze 后排空自动恢复。
                if self.state.freezeMode {
                    self.setFreezeEnabled(false)
                } else {
                    self.ble.notifyFreezeOff()
                }
            }
        }
        ble.onWriteAck = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.applySessionEffects(self.machine.handle(.commandAcknowledged(generation: self.ble.generation), now: Date()))
            }
        }
        firmwareImages = FirmwareImage.bundledImages()
        thermalTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.phoneThermal = PhoneThermalState.from(ProcessInfo.processInfo.thermalState)
                // 电量 5 秒轮询刷新：只靠 batteryLevelDidChangeNotification 时
                // 系统通知可能合并/延迟，轮询兜底保证数值不 stale。
                self.updateBatteryStatus()
            }
        }
        phoneThermal = PhoneThermalState.from(ProcessInfo.processInfo.thermalState)
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBatteryStatus()
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateBatteryStatus() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateBatteryStatus()
                self?.evaluateAutomation()
            }
        })
        automationTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateAutomation() }
        }
    }

    private func updateBatteryStatus() {
        let device = UIDevice.current
        batteryLevel = device.batteryLevel >= 0 ? Int(device.batteryLevel * 100) : -1
        let charging = device.batteryState == .charging || device.batteryState == .full
        if charging != batteryCharging {
            batteryCharging = charging
            applySessionEffects(machine.handle(charging ? .chargingStarted : .chargingEnded, now: Date()))
        } else {
            batteryCharging = charging
        }
    }

    /// 连接阶段同步（controller.phase 与 state.phase 保持一致）。
    /// READY 期间 BLE 层不再上报阶段，.ready 只由 onReadyState 置位，
    /// 避免迟到的 .subscribing 覆盖它。
    private func setPhase(_ newPhase: ConnectionPhase) {
        if phase == .ready, newPhase == .subscribing { return }
        phase = newPhase
        state.phase = newPhase
    }

    /// 执行状态机的效果（发命令 / 启定时器 / 读回 / 报错 / 取消 / 恢复）。
    /// 状态机本身不碰 BLE，只做决策。
    private func applySessionEffects(_ effects: [SessionEffect]) {
        for effect in effects {
            switch effect {
            case .sendCommand(let data, let key):
                ble.enqueue(data, key: key)
            case .startTimer(let interval, let token):
                _ = schedule(after: Int(interval * 1000)) { [weak self] in
                    guard let self = self else { return }
                    self.applySessionEffects(self.machine.handle(.timerFired(token), now: Date()))
                }
            case .readBack:
                requestRealtimeState()
            case .reportError(let message):
                state.lastError = message
                log(message)
            case .cancelPending:
                cancelModeTxWorkItems()
                pendingModeRequest = nil
            case .resumePausedTarget:
                flushDeferredModeRequest()
                flushPendingThermalLevel()
            }
        }
    }

    func log(_ message: String) {
        logs.append(LogEntry(date: Date(), message: message))
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    var isConnected: Bool { connection == .connected || demoMode }

    /// 主队列延时任务（事务校验/补发轮询用；调用方保存返回的 WorkItem 以便取消）。
    private func schedule(after ms: Int, execute: @escaping @MainActor () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem {
            Task { @MainActor in
                execute()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: item)
        return item
    }

    private func cancelModeTxWorkItems() {
        modeTxWorkItems.forEach { $0.cancel() }
        modeTxWorkItems.removeAll()
    }

    private func cancelLightWorkItems() {
        lightWorkItems.forEach { $0.cancel() }
        lightWorkItems.removeAll()
    }

    private func cancelReadyWorkItems() {
        readyWorkItems.forEach { $0.cancel() }
        readyWorkItems.removeAll()
    }

    private func cancelShutdownWorkItems() {
        shutdownWorkItems.forEach { $0.cancel() }
        shutdownWorkItems.removeAll()
    }

    private func cancelAllWorkItems() {
        cancelModeTxWorkItems()
        cancelLightWorkItems()
        cancelReadyWorkItems()
        cancelShutdownWorkItems()
        freezeVerifyWorkItem?.cancel()
        freezeVerifyWorkItem = nil
    }

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        _ = ble.ensureReady()
    }

    func enterDemo() {
        // 宣传演示模式：模拟真实设备状态，不扫描、不连接、不发蓝牙指令。
        if connection == .connected {
            expectDisconnect = true
            ble.disconnect()
        }
        thermalLoopTimer?.invalidate()
        thermalLoopTimer = nil
        cancelAllWorkItems()
        freezeTxInFlight = false
        freezeSettledHandler = nil
        pendingModeRequest = nil
        pendingThermalLevel = nil
        thermalLastLevel = nil
        demoMode = true
        state = .demo
        phase = .ready
        channel = .flydigi
        log("进入宣传演示模式（不扫描、不连接、不发蓝牙指令）")
    }

    func exitDemo() {
        demoMode = false
        state = CoolerState()
        phase = .idle
        channel = .flydigi
        log("退出宣传演示模式")
    }

    // ------------------------------------------------------------ 扫描与连接

    func scan() {
        guard !demoMode else { return }
        error = nil
        ble.startScan()
    }

    func stopScan() {
        ble.stopScan()
    }

    func connect(_ device: DiscoveredDevice) {
        error = nil
        channel = device.channel
        state.channel = device.channel
        state.deviceName = device.name
        setPhase(.connecting)
        ble.connect(device)
    }

    func disconnect() {
        cancelFirmwareFlash()
        expectDisconnect = true
        thermalLoopTimer?.invalidate()
        thermalLoopTimer = nil
        cancelAllWorkItems()
        freezeTxInFlight = false
        freezeSettledHandler = nil
        pendingModeRequest = nil
        pendingThermalLevel = nil
        thermalLastLevel = nil
        ble.disconnect()
        state = CoolerState()
        phase = .disconnected
    }

    private func afterConnected() {
        // 握手 + 首次状态拉取。不立即恢复模式（等 READY）。
        ble.enqueue(B9XProtocol.handshake(), key: "init")
        ble.enqueue(B9XProtocol.requestMacAddress(), key: "mac")
        ble.enqueue(B9XProtocol.readTimedShutdown(), key: "timer")
        ble.enqueue(B9XProtocol.requestRunModeParams(4), key: "curve")
        // READY 前若 120/420/900/1600/2600ms 还没收到状态 → 各补发一次 [0x13]。
        for ms in [120, 420, 900, 1600, 2600] {
            readyWorkItems.append(schedule(after: ms) { [weak self] in
                guard let self, !self.state.ready else { return }
                self.ble.enqueue(B9XProtocol.requestRealtimeState(), key: "poll")
            })
        }
        // 4 秒仍未收到 → 重订阅 + 再发 [0x13] + 假连提示。
        readyWorkItems.append(schedule(after: 4000) { [weak self] in
            guard let self, !self.state.ready else { return }
            self.ble.reenableNotifications()
            self.ble.enqueue(B9XProtocol.requestRealtimeState(), key: "poll")
            self.state.connectionNote = "已连接但收不到设备状态：可能原版 App 还在另一台手机上占着连接，请先在那边彻底断开"
            self.log("已连接但收不到设备状态：可能原版 App 还在另一台手机上占着连接")
        })
    }

    /// READY（收到第一帧 0x13）后的收尾：启动本地温控评估、清遗留 Freeze、恢复模式。
    private func onReadyState() {
        cancelReadyWorkItems()
        state.connectionNote = nil
        setPhase(.ready)
        startThermalLoopTimer()
        if firmwareStage == .waitingForDevice, let image = flashingImage {
            firmwareWaitWorkItem?.cancel()
            firmwareWaitWorkItem = nil
            firmwareReconnectExpected = false
            // 刷后核对版本：红魔的版本号回读未验证，能读到才比对，
            // 读不到只记日志、不判失败。
            if !state.firmwareVersion.isEmpty, state.firmwareVersion == image.version {
                firmwareStage = .deviceAccepted
                log("固件刷写完成，设备版本已核对：\(image.version)")
            } else {
                firmwareStage = .transferred
                log("固件刷写完成，设备已重连（版本号未读到，请在设备页核对）")
            }
            flashingImage = nil
        }
        if state.freezeMode, !freezeDesired {
            // 重连后遗留 Freeze 清除：原版 App 没退出的超频状态。
            log("检测到原版 App 遗留的超频状态，已退出")
            state.connectionNote = "检测到原版 App 遗留的超频状态，已退出"
            setFreezeEnabled(false)
        } else if freezeDesired, !state.freezeMode {
            // 本 App 里开过 Freeze：重连后 420ms 重申一次（900ms 内只重申一次）。
            let now = Date()
            if let last = lastFreezeReassertAt, now.timeIntervalSince(last) < 0.9 {
                // 已在 900ms 内重申过，跳过。
            } else {
                lastFreezeReassertAt = now
                readyWorkItems.append(schedule(after: 420) { [weak self] in
                    guard let self, self.state.ready, !self.state.freezeMode else { return }
                    self.setFreezeEnabled(true)
                })
            }
        }
        if restoreLastModeOnConnect {
            restoreLastMode()
        }
    }

    /// READY 后启动本地温控评估循环（2 秒一次，只算档位、不发 BLE 轮询）。
    /// 遥测改为 notify 驱动：设备主动推送状态帧；超过 5 秒没通知时
    /// BLEManager 的静默看门狗才会补发一次 [0x13]。
    private func startThermalLoopTimer() {
        thermalLoopTimer?.invalidate()
        thermalLoopTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.evaluateSoftwareThermal()
            }
        }
    }

    /// 恢复上次模式：只发 UserDefaults 里存过的完整值；没存过不发。
    /// mode 2 是 v1 的作废值，跳过（超频现走 Freeze）。
    private func restoreLastMode() {
        guard restoreLastModeOnConnect else { return }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: DefaultsKey.hasLastMode) else { return }
        let mode = defaults.integer(forKey: DefaultsKey.lastRunMode)
        guard mode >= 0, mode <= 4, mode != B9XProtocol.modeOverclock else { return }
        let target = defaults.integer(forKey: DefaultsKey.lastTargetTemperature)
        let cold = defaults.integer(forKey: DefaultsKey.lastColdLevel)
        let wind = defaults.integer(forKey: DefaultsKey.lastWindLevel)
        let coldOC = defaults.integer(forKey: DefaultsKey.lastColdLevelOC)
        let windOC = defaults.integer(forKey: DefaultsKey.lastWindLevelOC)
        let req: ModeRequest
        if mode == B9XProtocol.modeCustom {
            let curve = (defaults.array(forKey: DefaultsKey.lastCustomLevels) as? [Int])
                ?? B9XProtocol.defaultCurveLevels
            req = ModeRequest(mode: 4, target: target, cold: cold, wind: wind, coldOC: coldOC, windOC: windOC, curve: curve, manual: false)
        } else {
            req = ModeRequest(mode: mode, target: target, cold: cold, wind: wind, coldOC: coldOC, windOC: windOC, curve: nil, manual: false)
        }
        log("已恢复上次模式：\(Self.modeName(mode))")
        sendMode(req)
    }

    private func rememberMode(_ req: ModeRequest) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: DefaultsKey.hasLastMode)
        defaults.set(req.mode, forKey: DefaultsKey.lastRunMode)
        defaults.set(req.target, forKey: DefaultsKey.lastTargetTemperature)
        defaults.set(req.cold, forKey: DefaultsKey.lastColdLevel)
        defaults.set(req.wind, forKey: DefaultsKey.lastWindLevel)
        defaults.set(req.coldOC, forKey: DefaultsKey.lastColdLevelOC)
        defaults.set(req.windOC, forKey: DefaultsKey.lastWindLevelOC)
        if req.mode == B9XProtocol.modeCustom {
            defaults.set(req.curve ?? state.customLevels, forKey: DefaultsKey.lastCustomLevels)
        }
    }

    // ------------------------------------------------------------ 事件处理

    private func onData(_ bytes: Data) {
        // 红魔/黑鲨帧结构未验证：只透传给对应 Codec 尝试解析（目前返回 nil），
        // 不按 B9X 帧表解析，避免误读。
        if channel != .flydigi {
            switch channel {
            case .redMagic: _ = RedMagicCodec.decode(bytes)
            case .blackShark: _ = BlackSharkCodec.decode(bytes)
            case .flydigi: break
            }
            return
        }
        guard let event = B9XProtocol.parse(bytes) else { return }
        switch event {
        case .state(let e):
            let wasReady = state.ready
            let wasFreeze = state.freezeMode
            lastEcho = e
            lastEchoLightOn = e.lightOn
            state.applyStateEvent(e)
            ble.freezeOn = state.freezeMode
            applySessionEffects(machine.handle(.telemetry(e), now: Date()))
            if state.freezeMode != wasFreeze {
                applySessionEffects(machine.handle(.freezeChanged(state.freezeMode), now: Date()))
                if !state.freezeMode {
                    ble.notifyFreezeOff()
                }
            }
            if !wasReady && state.ready {
                onReadyState()
            } else {
                evaluateSoftwareThermal()
            }
            // Freeze 退出确认后补发暂存的模式请求（事务成功路径之外再兜一层）。
            if !state.freezeMode, pendingModeRequest != nil {
                flushDeferredModeRequest()
            }
        case .led(let e):
            state.ledType = e.type
            state.ledColors = e.colors
            state.ledPeriod = e.period
            state.ledLight = e.light
            state.ledColorful = e.colorful
        case .customLevels(let levels):
            state.customLevels = levels
        case .mac(let mac):
            state.mac = mac
        case .firmware(let version):
            if version.count >= 3 {
                state.firmwareVersion = String(version.prefix(5))
            }
        case .experimentalMode(let on, _):
            state.experimentalModeOn = on
        case .timedShutdown(let mode, let running, let seconds):
            state.timedShutdownRunning = running
            state.timedShutdownMode = mode
            state.timeCountdown = seconds
        case .tempHistoryChunk(let chunk):
            state.tempHistory += chunk.map { Int($0) }
        case .tempHistoryDone:
            break
        }
    }

    /// BLE 连接状态变化时的收尾（由 BLEManager 的 connection 发布驱动）。
    func handleConnectionChange(_ newValue: BLEConnectionState) {
        switch newValue {
        case .connected:
            state.connected = true
            log("已连接 \(state.deviceName)")
            if !didInitAfterConnect {
                didInitAfterConnect = true
                afterConnected()
            }
        case .idle:
            didInitAfterConnect = false
            thermalLoopTimer?.invalidate()
            thermalLoopTimer = nil
            cancelAllWorkItems()
            freezeTxInFlight = false
            freezeSettledHandler = nil
            pendingThermalLevel = nil
            thermalLastLevel = nil
            state.ready = false
            state.pendingRunMode = nil
            applySessionEffects(machine.handle(.connectionLost, now: Date()))
            if state.connected {
                if firmwareReconnectExpected {
                    // 刷写后设备重启：等自动重连，不记断开、不发通知。
                    log("设备重启，等待重连以核对固件版本")
                } else {
                    log("连接已断开")
                    if !expectDisconnect {
                        notifyDisconnect()
                    }
                }
            }
            expectDisconnect = false
            if !demoMode {
                state.connected = false
            }
        default:
            break
        }
    }

    /// 断连本地通知（需在“系统集成”里开启）。
    private func notifyDisconnect() {
        guard UserDefaults.standard.bool(forKey: "notifyOnDisconnect") else { return }
        let content = UNMutableNotificationContent()
        content.title = "散热器已断开"
        content.body = "与飞智散热器的蓝牙连接已断开。"
        let request = UNNotificationRequest(
            identifier: "b9x-disconnect", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 数据与高级 → 刷新：重新拉取设备状态。
    func refreshState() {
        guard isConnected, !demoMode else { return }
        handshake()
        ble.enqueue(B9XProtocol.requestMacAddress(), key: "mac")
        ble.enqueue(B9XProtocol.readTimedShutdown(), key: "timer")
        ble.enqueue(B9XProtocol.requestRunModeParams(4), key: "curve")
        ble.enqueue(B9XProtocol.requestRealtimeState(), key: "poll")
        log("已刷新设备状态")
    }

    /// 立即拉一次实时状态（2 秒轮询与手动刷新共用）。
    func requestRealtimeState() {
        guard isConnected, !demoMode else { return }
        ble.enqueue(B9XProtocol.requestRealtimeState(), key: "poll")
    }

    // ------------------------------------------------------------ 场景联动引擎
    // 优先级：游戏 > 电池温度 > 充电；超频体验与用户手动操作始终优先。
    // 软件温控环路（state.softwareThermalMode != 0）接管期间，联动不抢。

    private func markManualOverride() {
        manualOverrideUntil = Date().addingTimeInterval(manualOverrideSeconds)
    }

    func evaluateAutomation() {
        guard automationStandby, isConnected, !demoMode else { return }
        if state.softwareThermalMode != 0 { return }
        if let until = manualOverrideUntil, Date() < until { return }
        if gameLinkageEnabled && !gameLinkageNoted {
            gameLinkageNoted = true
            log("游戏联动：iOS 无法直接检测前台游戏，请用快捷指令自动化触发")
        }
        if chargeFollowEnabled && batteryCharging {
            if state.runMode != chargeFollowMode {
                applyChargeFollowMode(chargeFollowMode)
                log("充电随动：正在充电，已切换指定模式")
            }
        }
    }

    private func applyChargeFollowMode(_ mode: Int) {
        var req: ModeRequest?
        switch mode {
        case B9XProtocol.modeSmart:
            req = smartPresetRequest(state.smartPreset)
        case B9XProtocol.modeManual:
            req = manualPresetRequest(state.manualPreset)
        case B9XProtocol.modeCustom:
            req = curveRequest(state.customLevels)
        default:
            break
        }
        if var req = req {
            req.manual = false
            sendMode(req)
        } else {
            setRunMode(mode: mode, manual: false)
        }
    }

    // ------------------------------------------------------------ 软件温控环路（§3.4）

    /// 软件温控环路：0=无，100=电池温控，101=目标温控。
    func setSoftwareThermalMode(_ mode: Int) {
        guard mode == 0 || mode == B9XProtocol.thermalModeBattery
                || mode == B9XProtocol.thermalModeCoolerTarget else { return }
        let previous = state.softwareThermalMode
        guard previous != mode else { return }
        if mode == 0 {
            state.softwareThermalMode = 0
            thermalLastLevel = nil
            pendingThermalLevel = nil
            if state.freezeMode { setFreezeEnabled(false) }
            log("已退出\(Self.thermalModeName(previous))")
            return
        }
        // 开启环路是用户的明确选择：清掉之前的手动接管窗口，立即生效。
        manualOverrideUntil = nil
        state.softwareThermalMode = mode
        thermalLastLevel = nil
        log("已开启\(Self.thermalModeName(mode))")
        evaluateSoftwareThermal()
    }

    func exitSoftwareThermalMode() {
        setSoftwareThermalMode(0)
    }

    /// 目标温控的目标冷面温度（-20..16）。
    func setCoolerTargetC(_ celsius: Int) {
        state.coolerTargetC = max(-20, min(celsius, 16))
        evaluateSoftwareThermal()
    }

    /// 电池温控的目标温度（0..60；电池温度 iOS 不提供，以系统热状态估算）。
    func setBatteryTargetC(_ celsius: Int) {
        state.batteryTargetC = max(0, min(celsius, 60))
        evaluateSoftwareThermal()
    }

    /// 电池/冷面目标温度一起改（UI 两处调整 sheet 共用；改完立即重算环路）。
    func setSoftwareTargets(batteryTargetC: Int, coolerTargetC: Int) {
        setBatteryTargetC(batteryTargetC)
        setCoolerTargetC(coolerTargetC)
    }

    /// 用户手动操作（模式/滑块/步进器）时退出环路；灯效不退出，只暂停 60 秒。
    private func exitSoftwareThermalIfNeeded() {
        guard state.softwareThermalMode != 0 else { return }
        let previous = state.softwareThermalMode
        state.softwareThermalMode = 0
        thermalLastLevel = nil
        pendingThermalLevel = nil
        if state.freezeMode { setFreezeEnabled(false) }
        log("已退出\(Self.thermalModeName(previous))")
    }

    /// 目标温控档位：温差 ≤1→1，≤2→2，≤4→3，≤6→5，≤8→7，≤10→8，>10→9。
    private func decideCoolerTargetLevel(coldTemperature: Double, target: Int) -> Int {
        let diff = coldTemperature - Double(target)
        if diff <= 1 { return 1 }
        if diff <= 2 { return 2 }
        if diff <= 4 { return 3 }
        if diff <= 6 { return 5 }
        if diff <= 8 { return 7 }
        if diff <= 10 { return 8 }
        return 9
    }

    /// 每收到 0x13 或每 2 秒算一次档位。
    private func evaluateSoftwareThermal() {
        guard state.softwareThermalMode != 0, state.ready, !demoMode, isConnected else { return }
        if let until = manualOverrideUntil, Date() < until { return }
        let level: Int
        switch state.softwareThermalMode {
        case B9XProtocol.thermalModeBattery:
            // iOS 读不到电池温度，用系统热状态估算。
            switch phoneThermal {
            case .nominal: level = 1
            case .fair: level = 3
            case .serious: level = 7
            case .critical: level = 9
            }
        case B9XProtocol.thermalModeCoolerTarget:
            level = decideCoolerTargetLevel(coldTemperature: state.temperatureValue, target: state.coolerTargetC)
        default:
            return
        }
        applyThermalLevel(level)
    }

    private func applyThermalLevel(_ level: Int) {
        if level == 9 {
            // 9 档 = Freeze ON。已在 Freeze 里则保持，不重复发。
            if state.freezeMode {
                thermalLastLevel = 9
                return
            }
            if freezeTxInFlight && freezeTxTarget { return }
            setFreezeEnabled(true)
            return
        }
        // 档位不变且设备已保持（回显 runMode==4）时不重复发。
        if thermalLastLevel == level, state.runMode == 4 { return }
        if state.freezeMode {
            // 0x20 帧在 Freeze 下会被设备拒绝：先退 Freeze，确认后再补曲线。
            pendingThermalLevel = level
            setFreezeEnabled(false)
            return
        }
        sendFlatCurve(level: level)
    }

    /// 平坦九点曲线 [档位×9]（走 0x20/4 事务；不标记手动接管、不退出环路）。
    private func sendFlatCurve(level: Int) {
        thermalLastLevel = level
        let req = ModeRequest(
            mode: B9XProtocol.modeCustom,
            target: state.targetTemperature,
            cold: state.coldLevel,
            wind: state.windLevel,
            coldOC: state.coldLevelOverclock,
            windOC: state.windLevelOverclock,
            curve: Array(repeating: level, count: 9),
            manual: false
        )
        executeModeSend(req)
    }

    private func flushPendingThermalLevel() {
        guard !state.freezeMode, let level = pendingThermalLevel else { return }
        pendingThermalLevel = nil
        sendFlatCurve(level: level)
    }

    // ------------------------------------------------------------ 模式事务（§3.1–§3.2）

    private func smartPresetRequest(_ preset: Int) -> ModeRequest {
        let p = preset == 0 ? B9XProtocol.smartPresetSilent : B9XProtocol.smartPresetExtreme
        return ModeRequest(mode: B9XProtocol.modeSmart, target: p.target, cold: p.cold, wind: p.wind, coldOC: p.coldOC, windOC: p.windOC, curve: nil, manual: true)
    }

    private func manualPresetRequest(_ preset: Int) -> ModeRequest {
        let p: (cold: Int, wind: Int, windOC: Int, coldOC: Int)
        switch preset {
        case 0: p = B9XProtocol.manualPresetEco
        case 1: p = B9XProtocol.manualPresetStrong
        default: p = B9XProtocol.manualPresetMax
        }
        // target 取当前 state target，钳 0..16；尚未 READY 时缺省 16。
        let target = state.ready ? max(0, min(state.targetTemperature, 16)) : 16
        return ModeRequest(mode: B9XProtocol.modeManual, target: target, cold: p.cold, wind: p.wind, coldOC: p.coldOC, windOC: p.windOC, curve: nil, manual: true)
    }

    private func curveRequest(_ values: [Int]) -> ModeRequest {
        var curve = values.map { max(1, min($0, 8)) }
        if curve.count < 9 {
            curve += Array(B9XProtocol.defaultCurveLevels[curve.count...])
        }
        return ModeRequest(
            mode: B9XProtocol.modeCustom,
            target: state.targetTemperature,
            cold: state.coldLevel,
            wind: state.windLevel,
            coldOC: state.coldLevelOverclock,
            windOC: state.windLevelOverclock,
            curve: Array(curve.prefix(9)),
            manual: true
        )
    }

    /// §3.1 填充规则：cold/wind 为 0 时用当前 state 值填；state 也没有时用
    /// 当前模式的预设值填（SMART→极寒档，MANUAL→强劲档）。target 为 0 合法，
    /// OC 0/0 合法，不填充。
    private func fillModeParams(_ req: ModeRequest) -> ModeRequest {
        var r = req
        guard r.mode != B9XProtocol.modeCustom else { return r }
        if r.cold == 0 { r.cold = state.coldLevel }
        if r.cold == 0 {
            r.cold = r.mode == B9XProtocol.modeManual
                ? B9XProtocol.manualPresetStrong.cold
                : B9XProtocol.smartPresetExtreme.cold
        }
        if r.wind == 0 { r.wind = state.windLevel }
        if r.wind == 0 {
            r.wind = r.mode == B9XProtocol.modeManual
                ? B9XProtocol.manualPresetStrong.wind
                : B9XProtocol.smartPresetExtreme.wind
        }
        return r
    }

    /// SMART/MANUAL 帧的 target 钳到 0..16；其余帧内钳到 0..255（协议层兜底）。
    private func frameTarget(for req: ModeRequest) -> Int {
        if req.mode == B9XProtocol.modeSmart || req.mode == B9XProtocol.modeManual {
            return max(0, min(req.target, 16))
        }
        return max(0, min(req.target, 255))
    }

    private func modeFrameFor(_ req: ModeRequest) -> Data {
        if req.mode == B9XProtocol.modeCustom {
            return B9XProtocol.setRunMode(mode: B9XProtocol.modeCustom, customLevels: req.curve ?? B9XProtocol.defaultCurveLevels)
        }
        return B9XProtocol.setRunMode(
            mode: req.mode,
            targetTemperature: frameTarget(for: req),
            windLevel: req.wind,
            coldLevel: req.cold,
            windLevelOverclock: req.windOC,
            coldLevelOverclock: req.coldOC
        )
    }

    /// 模式是否已相同（快捷路径判定）：mode 相同 + target 精确相同 +
    /// cold ±5、wind ±300（原版容差；Freeze 回显 wind 可能读到 6000，
    /// 相对名义档 5700 的偏差 300 以内都算同一档）。
    private func isSameModeParams(_ req: ModeRequest) -> Bool {
        guard let echo = lastEcho else { return false }
        if req.mode == B9XProtocol.modeCustom {
            return echo.runMode == B9XProtocol.modeCustom
                && state.customLevels == (req.curve ?? B9XProtocol.defaultCurveLevels)
        }
        guard echo.runMode == req.mode else { return false }
        return echo.targetTemperature == frameTarget(for: req)
            && abs(echo.coldLevel - req.cold) <= 5
            && abs(echo.windLevel - req.wind) <= 300
    }

    /// 模式切换入口（事务）：本地立即反馈 → 发 0x20 全参数帧 →
    /// 180/420/850ms 补发 [0x13] → 1150ms 校验回显 → 失败重试一次。
    private func sendMode(_ req: ModeRequest) {
        // mode 2 已作废：超频现走 Freeze，不再发 mode 2 的 0x20 帧。
        guard req.mode != B9XProtocol.modeOverclock else {
            log("超频模式已改为 Freeze（超频体验），不再发 mode 2")
            return
        }
        if demoMode {
            let r = fillModeParams(req)
            if r.mode == B9XProtocol.modeCustom {
                state.customLevels = r.curve ?? B9XProtocol.defaultCurveLevels
            } else {
                state.targetTemperature = r.target
                state.coldLevel = r.cold
                state.windLevel = r.wind
                state.coldLevelOverclock = r.coldOC
                state.windLevelOverclock = r.windOC
            }
            state.runMode = r.mode
            state.pendingRunMode = nil
            if req.manual { markManualOverride() }
            return
        }
        guard isConnected else {
            state.lastError = "设备未连接"
            return
        }
        if req.manual {
            exitSoftwareThermalIfNeeded()
            markManualOverride()
        }
        // Freeze=ON 时设备拒绝 0x20：暂存请求，等 Freeze 退出确认后再补发。
        if state.freezeMode {
            freezeDesired = false
            UserDefaults.standard.set(false, forKey: DefaultsKey.freezeDesired)
            pendingModeRequest = req
            // 界面立即显示目标模式（不等 Freeze 退出确认）；退出失败时清掉。
            state.pendingRunMode = req.mode
            state.lastError = "正在等待退出超频…"
            log("正在等待退出超频，模式请求已暂存")
            setFreezeEnabled(false)
            return
        }
        executeModeSend(req)
    }

    private func executeModeSend(_ req: ModeRequest) {
        cancelModeTxWorkItems()
        let r = fillModeParams(req)
        // 记入会话状态机（目标与归属）；本事件只记账不产生效果，
        // 发送仍走下面的模式事务。
        let machineTarget = ModeTarget(
            mode: r.mode,
            targetCelsius: r.target,
            level: r.cold,
            curveLevels: r.curve ?? B9XProtocol.defaultCurveLevels,
            isSoftwareControlled: !r.manual
        )
        applySessionEffects(machine.handle(.userRequest(machineTarget), now: Date()))
        // 本地立即更新（pendingRunMode 供界面立即反馈；runMode 本身不乐观写，
        // 校验只认回显 lastEcho）。
        if r.mode == B9XProtocol.modeCustom {
            state.customLevels = r.curve ?? B9XProtocol.defaultCurveLevels
        } else {
            state.targetTemperature = r.target
            state.coldLevel = r.cold
            state.windLevel = r.wind
            state.coldLevelOverclock = r.coldOC
            state.windLevelOverclock = r.windOC
            state.holdLocal("target", seconds: r.localHoldSeconds)
            state.holdLocal("cold", seconds: r.localHoldSeconds)
            state.holdLocal("wind", seconds: r.localHoldSeconds)
            state.holdLocal("runMode", seconds: r.localHoldSeconds)
        }
        state.pendingRunMode = r.mode
        rememberMode(r)
        // 快捷路径：已在目标模式且参数相同 → 只发一遍帧，不校验、不记日志。
        if isSameModeParams(r) {
            ble.enqueue(modeFrameFor(r), key: "mode")
            state.pendingRunMode = nil
            return
        }
        let modeBefore = lastEcho?.runMode ?? state.runMode
        // 前置保护事务：max(cold, coldOC) >= 175 且低温保护未开 → 先开保护，400ms 后再发模式帧。
        if max(r.cold, r.coldOC) >= 175, !state.coldProtectionEnabled {
            ble.enqueue(B9XProtocol.setTempProtect(enabled: true), key: "protect_low")
            state.coldProtectionEnabled = true
            log("已开启低温保护（模式要求冷档 ≥ 175）")
            modeTxWorkItems.append(schedule(after: 400) { [weak self] in
                self?.sendModeFrameAndVerify(r, modeBefore: modeBefore, attempt: 0)
            })
        } else {
            sendModeFrameAndVerify(r, modeBefore: modeBefore, attempt: 0)
        }
    }

    private func sendModeFrameAndVerify(_ req: ModeRequest, modeBefore: Int, attempt: Int) {
        ble.enqueue(modeFrameFor(req), key: "mode")
        for ms in [180, 420, 850] {
            modeTxWorkItems.append(schedule(after: ms) { [weak self] in
                self?.ble.enqueue(B9XProtocol.requestRealtimeState(), key: "poll")
            })
        }
        modeTxWorkItems.append(schedule(after: 1150) { [weak self] in
            self?.verifyMode(req, modeBefore: modeBefore, attempt: attempt)
        })
    }

    private func verifyMode(_ req: ModeRequest, modeBefore: Int, attempt: Int) {
        if lastEcho?.runMode == req.mode {
            // 成功：清 pending；回显确认后把 runMode 写成目标值（本地 hold 会挡
            // 住 3 秒内的回显，靠这里同步一次）。
            state.runMode = req.mode
            state.pendingRunMode = nil
            if state.lastError == "模式切换未确认，请重试" || state.lastError == "正在等待退出超频…" {
                state.lastError = nil
            }
            if modeBefore != req.mode {
                log("切换模式：\(Self.modeName(req.mode))")
            }
            return
        }
        if attempt == 0 {
            sendModeFrameAndVerify(req, modeBefore: modeBefore, attempt: 1)
            return
        }
        state.pendingRunMode = nil
        state.lastError = "模式切换未确认，请重试"
        log("模式切换未确认：\(Self.modeName(req.mode))，请重试")
    }

    private func flushDeferredModeRequest() {
        guard !state.freezeMode, let req = pendingModeRequest else { return }
        pendingModeRequest = nil
        state.lastError = nil
        executeModeSend(req)
    }

    // ------------------------------------------------------------ 命令

    func setColdLevel(_ level: Int) {
        let clamped = max(0, min(level, B9XProtocol.maxColdLevel))
        exitSoftwareThermalIfNeeded()
        markManualOverride()
        state.coldLevel = clamped
        state.holdLocal("cold", seconds: 1.5)
        guard !demoMode, isConnected else { return }
        ble.enqueue(B9XProtocol.setColdLevel(clamped), key: "cold")
    }

    /// 风量滑块：wind 4000..5700、步进 100；发当前模式的 0x20 全参数帧
    ///（只改 wind，其余按 §3.1 填充）。当前模式为曲线/专家时按 SMART 发。
    func setWindLevelViaMode(_ wind: Int) {
        let stepped = max(B9XProtocol.minWindLevel, min((wind + 50) / 100 * 100, B9XProtocol.maxWindLevel))
        let mode = (state.runMode == B9XProtocol.modeSmart || state.runMode == B9XProtocol.modeManual)
            ? state.runMode : B9XProtocol.modeSmart
        let req = ModeRequest(
            mode: mode,
            target: state.targetTemperature,
            cold: state.coldLevel,
            wind: stepped,
            coldOC: state.coldLevelOverclock,
            windOC: state.windLevelOverclock,
            curve: nil,
            manual: true,
            localHoldSeconds: 1.5
        )
        sendMode(req)
    }

    func setRunMode(
        mode: Int,
        targetTemperature: Int = 0,
        windLevel: Int = 0,
        coldLevel: Int = 0,
        windLevelOverclock: Int = 0,
        coldLevelOverclock: Int = 0,
        customLevels: [Int]? = nil,
        manual: Bool = true
    ) {
        // 沿用 v1 语义：传 0 表示“保持当前值”（显式 target 0 请走 setSmartPreset 极寒档）。
        if mode == B9XProtocol.modeCustom {
            var req = curveRequest(customLevels ?? state.customLevels)
            req.manual = manual
            sendMode(req)
            return
        }
        let req = ModeRequest(
            mode: mode,
            target: targetTemperature == 0 ? state.targetTemperature : targetTemperature,
            cold: coldLevel,
            wind: windLevel,
            coldOC: coldLevelOverclock,
            windOC: windLevelOverclock,
            curve: nil,
            manual: manual
        )
        sendMode(req)
    }

    /// 智能变频预设：0=静音，2=极寒（原版二档；Flutter 三档已作废）。
    func setSmartPreset(_ preset: Int) {
        let p = preset == 0 ? 0 : 2
        state.smartPreset = p
        sendMode(smartPresetRequest(p))
    }

    /// 固定功率预设：0=节能，1=强劲，2=极强。
    func setManualPreset(_ preset: Int) {
        let p = max(0, min(preset, 2))
        state.manualPreset = p
        sendMode(manualPresetRequest(p))
    }

    /// 手动模式：走当前选中的手动预设（setManualPreset 选档，默认极强）。
    func setManual() {
        setManualPreset(state.manualPreset)
    }

    /// 自由变频曲线：9 档 clamp 1..8，发 [0x20,0x04,…]，走同一模式事务。
    func setCustomCurve(_ values: [Int]) {
        sendMode(curveRequest(values))
    }

    /// 目标温度步进器：t 范围 -20..16；本地立即更新 + 保存；发 SMART 全参数帧
    ///（target 帧内钳 0..16，-20 进帧前钳到 0；本地显示仍保留 -20）。
    func setTargetTemperature(_ t: Int) {
        let target = max(-20, min(t, 16))
        let req = ModeRequest(mode: B9XProtocol.modeSmart, target: target, cold: 0, wind: 0, coldOC: 0, windOC: 0, curve: nil, manual: true)
        sendMode(req)
    }

    func setQuickSwitchRunMode(_ mode: Int) {
        let m = (mode == 1 || mode == 4) ? mode : 0
        if demoMode {
            state.quickSwitchRunMode = m
            return
        }
        guard isConnected else { return }
        exitSoftwareThermalIfNeeded()
        markManualOverride()
        state.quickSwitchRunMode = m
        ble.enqueue(B9XProtocol.setQuickSwitchRunMode(m), key: "quick")
    }

    func setExperimentalMode(enabled: Bool, level: Int = 0, targetTemperature: Int = 0) {
        guard !demoMode, isConnected else { return }
        markManualOverride()
        ble.enqueue(
            B9XProtocol.setExperimentalRunMode(
                enabled: enabled,
                level: level,
                targetTemperature: targetTemperature
            ),
            key: "exp"
        )
    }

    func setLightEnabled(_ on: Bool) {
        if demoMode {
            state.lightOn = on
            return
        }
        guard isConnected else { return }
        markManualOverride()
        state.lightOn = on
        ble.enqueue(on ? B9XProtocol.lightOn() : B9XProtocol.lightOff(), key: "light")
        lightTxAttempt = 0
        scheduleLightVerify(on: on)
    }

    private func scheduleLightVerify(on: Bool) {
        cancelLightWorkItems()
        for ms in [220, 520, 900] {
            lightWorkItems.append(schedule(after: ms) { [weak self] in
                self?.ble.enqueue(B9XProtocol.requestRealtimeState(), key: "poll")
            })
        }
        lightWorkItems.append(schedule(after: 1250) { [weak self] in
            self?.verifyLight(on: on)
        })
    }

    private func verifyLight(on: Bool) {
        // 校验只认回显（lastEchoLightOn），不认本地乐观值。
        if lastEchoLightOn == on { return }
        if lightTxAttempt == 0 {
            lightTxAttempt = 1
            ble.enqueue(on ? B9XProtocol.lightOn() : B9XProtocol.lightOff(), key: "light")
            scheduleLightVerify(on: on)
            return
        }
        state.lastError = "灯光切换未确认，请重试"
        log("灯光切换未确认，请重试")
    }

    func applyLed(type: Int, period: Int = 0, colors: [Int] = [], light: Int = 0, colorful: Bool = false) {
        state.ledType = type
        state.ledPeriod = period
        state.ledColors = colors
        state.ledLight = light
        state.ledColorful = colorful
        state.lightOn = type != 0
        markManualOverride()
        guard !demoMode, isConnected else { return }
        ble.enqueueMany(
            B9XProtocol.setLedColor(type: type, period: period, colors: colors, light: light, colorful: colorful)
        )
    }

    /// 定时关机（分钟制）。关闭发 [0x60, repeat, 0, 0, 0]；
    /// 发后 250ms 读 [0x61]、600ms 补 [0x13]。
    func setTimedShutdown(`repeat` repeatEnabled: Bool, enabled: Bool, minutes: Int) {
        if demoMode {
            state.timedShutdownMode = repeatEnabled ? 1 : 0
            state.timedShutdownRunning = enabled
            state.timeCountdown = enabled ? max(0, minutes) * 60 : 0
            return
        }
        guard isConnected else { return }
        state.timedShutdownMode = repeatEnabled ? 1 : 0
        state.timedShutdownRunning = enabled
        state.timeCountdown = enabled ? max(0, minutes) * 60 : 0
        ble.enqueue(
            B9XProtocol.setTimedShutdown(repeat: repeatEnabled, enabled: enabled, minutes: enabled ? minutes : 0),
            key: "shutdown"
        )
        cancelShutdownWorkItems()
        shutdownWorkItems.append(schedule(after: 250) { [weak self] in
            self?.ble.enqueue(B9XProtocol.readTimedShutdown(), key: "timer")
        })
        shutdownWorkItems.append(schedule(after: 600) { [weak self] in
            self?.ble.enqueue(B9XProtocol.requestRealtimeState(), key: "poll")
        })
    }

    func readTimedShutdown() {
        guard !demoMode, isConnected else { return }
        ble.enqueue(B9XProtocol.readTimedShutdown(), key: "timer")
    }

    func requestTempHistory() {
        state.tempHistory = []
        ble.enqueue(B9XProtocol.requestTempHistory(), key: "history")
    }

    /// 超频体验 = Freeze 开关（原版机制；不是 mode 2）。
    /// 未 READY 时拒绝并提示“设备未就绪”。
    func setFreezeEnabled(_ enabled: Bool) {
        freezeTx(enabled: enabled, attempt: 0, onSettled: nil)
    }

    private func freezeTx(enabled: Bool, attempt: Int, onSettled: ((Bool) -> Void)?) {
        if demoMode {
            state.freezeMode = enabled
            state.freezeRequested = enabled
            log(enabled ? "已进入超频体验（演示）" : "已退出超频体验（演示）")
            onSettled?(true)
            return
        }
        guard state.ready else {
            state.lastError = "设备未就绪"
            log("设备未就绪，超频请求已拒绝")
            onSettled?(false)
            return
        }
        freezeDesired = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.freezeDesired)
        state.freezeRequested = enabled
        if state.freezeMode == enabled {
            onSettled?(true)
            return
        }
        if freezeTxInFlight, freezeTxTarget == enabled {
            // 同一方向的事务已在进行中：只更新回调，不重复发帧。
            if let onSettled = onSettled { freezeSettledHandler = onSettled }
            return
        }
        freezeTxInFlight = true
        freezeTxTarget = enabled
        freezeSettledHandler = onSettled
        freezeVerifyWorkItem?.cancel()
        ble.enqueue(B9XProtocol.setFreezeMode(enabled), key: "freeze")
        freezeVerifyWorkItem = schedule(after: 1450) { [weak self] in
            self?.verifyFreeze(enabled: enabled, attempt: attempt)
        }
    }

    /// 1450ms 校验：回显 state.freezeMode==目标才算成功；失败重试最多 2 次（间隔 1100ms）。
    private func verifyFreeze(enabled: Bool, attempt: Int) {
        if state.freezeMode == enabled {
            freezeTxInFlight = false
            let handler = freezeSettledHandler
            freezeSettledHandler = nil
            if state.lastError == "设备未确认进入超频体验，请检查供电"
                || state.lastError == "设备未确认退出超频体验；已阻止后续模式切换" {
                state.lastError = nil
            }
            log(enabled ? "已进入超频体验" : "已退出超频体验")
            handler?(true)
            if !enabled {
                flushDeferredModeRequest()
                flushPendingThermalLevel()
            }
            return
        }
        if attempt < 2 {
            freezeVerifyWorkItem = schedule(after: 1100) { [weak self] in
                guard let self else { return }
                self.ble.enqueue(B9XProtocol.setFreezeMode(enabled), key: "freeze")
                self.freezeVerifyWorkItem = self.schedule(after: 1450) { [weak self] in
                    self?.verifyFreeze(enabled: enabled, attempt: attempt + 1)
                }
            }
            return
        }
        freezeTxInFlight = false
        let handler = freezeSettledHandler
        freezeSettledHandler = nil
        if enabled {
            state.lastError = "设备未确认进入超频体验，请检查供电"
            log("设备未确认进入超频体验，请检查供电")
        } else {
            // 退出失败：丢弃暂存的模式请求，界面回落到真实状态（超频）。
            pendingModeRequest = nil
            state.pendingRunMode = nil
            state.lastError = "设备未确认退出超频体验；已阻止后续模式切换"
            log("设备未确认退出超频体验；已阻止后续模式切换")
        }
        handler?(false)
    }

    /// 低温保护开关（只此一个；高温保护命令已删，高温只是状态位）。
    func setColdProtectionEnabled(_ enabled: Bool) {
        if demoMode {
            state.coldProtectionEnabled = enabled
            return
        }
        guard isConnected else { return }
        state.coldProtectionEnabled = enabled
        ble.enqueue(B9XProtocol.setTempProtect(enabled: enabled), key: "protect_low")
    }

    func resetFactory() {
        ble.enqueue(B9XProtocol.resetFlash(), key: "reset")
    }

    func handshake() {
        ble.enqueue(B9XProtocol.handshake(), key: "init")
    }

    // ------------------------------------------------------------ 固件刷写（Telink OTA）

    /// 红魔 8 Pro 判定：按设备名推断（广播名未验证），含 "8 Pro"/"8Pro" 才放行。
    private var isRedMagic8Pro: Bool {
        state.deviceName.contains("8 Pro") || state.deviceName.contains("8Pro")
    }

    /// 固件刷写：仅红魔 8 Pro 可用，其他机型直接 failed。
    /// 流程：核对 consent → SHA256 校验 → 分包下发 → 刷后静默重连核对版本。
    /// OTA 帧结构未验证（见 TelinkOTA.swift），真机验证前谨慎使用。
    func startFirmwareFlash(image: FirmwareImage, consent: String) async {
        guard !demoMode else {
            firmwareStage = .failed("演示模式下不能刷固件")
            return
        }
        guard channel == .redMagic, isRedMagic8Pro else {
            firmwareStage = .failed("仅红魔 8 Pro 支持刷固件（当前设备：\(state.deviceName)）")
            log("固件刷写被拒：仅红魔 8 Pro 可用")
            return
        }
        guard consent == Self.firmwareConsentPhrase else {
            firmwareStage = .failed("请先输入确认短语“\(Self.firmwareConsentPhrase)”")
            return
        }
        guard isConnected else {
            firmwareStage = .failed("设备未连接")
            return
        }
        guard let data = image.loadData() else {
            firmwareStage = .failed("读不到固件镜像")
            return
        }
        firmwareFlashCancelled = false
        flashingImage = image
        firmwareProgress = 0
        setPhase(.flashing)
        firmwareStage = .preparing
        // SHA256 校验：包内暂无参考哈希，先算出摘要记入日志，
        // 再走 TelinkOTA.validate（大小 + CRC32）。
        let digest = SHA256.hash(data: data)
        let shaHex = digest.map { String(format: "%02x", $0) }.joined()
        log("固件 SHA256：\(shaHex)")
        firmwareStage = .validating
        guard TelinkOTA.validate(data) else {
            firmwareStage = .failed("固件校验失败（大小或 CRC32 异常）")
            flashingImage = nil
            setPhase(state.ready ? .ready : .idle)
            return
        }
        guard ble.hasOTACharacteristic else {
            firmwareStage = .failed("未发现 OTA 特征，请确认设备处于可刷写状态")
            flashingImage = nil
            setPhase(state.ready ? .ready : .idle)
            return
        }
        firmwareStage = .transferring
        let startResult = await ble.enqueueBatch(
            TelinkOTA.startRequests(imageSize: data.count, crc32: TelinkOTA.storedCRC32(data)),
            priority: 100
        )
        guard !firmwareFlashCancelled else { return }
        guard case .success = startResult else {
            firmwareStage = .failed("刷写起始命令失败")
            flashingImage = nil
            setPhase(state.ready ? .ready : .idle)
            return
        }
        // 分包下发：每 20 包一批，逐批等确认并更新进度。
        let packets = TelinkOTA.packets(for: data)
        let chunkSize = 20
        var sent = 0
        var failed = false
        for chunkStart in stride(from: 0, to: packets.count, by: chunkSize) {
            if firmwareFlashCancelled { return }
            let chunk = Array(packets[chunkStart..<min(chunkStart + chunkSize, packets.count)])
            let requests = chunk.map { GATTRequest(isOTA: true, payload: $0, responseRequired: true) }
            let result = await ble.enqueueBatch(requests, priority: 100)
            if firmwareFlashCancelled { return }
            guard case .success = result else { failed = true; break }
            sent += chunk.count
            firmwareProgress = Double(sent) / Double(packets.count) * 0.9
        }
        if failed {
            firmwareStage = .failed("固件传输中断")
            flashingImage = nil
            setPhase(state.ready ? .ready : .idle)
            return
        }
        firmwareProgress = 0.95
        firmwareStage = .submitting
        let endResult = await ble.enqueueBatch([TelinkOTA.end()], priority: 100)
        if firmwareFlashCancelled { return }
        guard case .success = endResult else {
            firmwareStage = .failed("固件提交失败")
            flashingImage = nil
            setPhase(state.ready ? .ready : .idle)
            return
        }
        firmwareProgress = 1
        firmwareStage = .waitingForDevice
        firmwareReconnectExpected = true
        log("固件已提交，等待设备重启重连")
        ble.disconnectForFirmwareReboot()
        // 30 秒等不到重连 → failed（设备可能需要手动重连后核对版本）。
        firmwareWaitWorkItem?.cancel()
        let waitItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.firmwareStage == .waitingForDevice else { return }
            self.firmwareReconnectExpected = false
            self.firmwareStage = .failed("设备重启后未重连，请手动重连后核对版本")
            self.flashingImage = nil
            self.setPhase(.idle)
        }
        firmwareWaitWorkItem = waitItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: waitItem)
    }

    /// 取消固件刷写（仅在刷写进行中有效）。
    func cancelFirmwareFlash() {
        switch firmwareStage {
        case .preparing, .validating, .transferring, .submitting, .waitingForDevice:
            firmwareFlashCancelled = true
            firmwareWaitWorkItem?.cancel()
            firmwareWaitWorkItem = nil
            firmwareReconnectExpected = false
            flashingImage = nil
            ble.cancelAllBatches()
            firmwareStage = .cancelled
            setPhase(state.ready ? .ready : .idle)
            log("固件刷写已取消")
        default:
            break
        }
    }

    // ------------------------------------------------------------ 红魔 / 黑鲨扩展控制

    /// LCD 上传：黑鲨 6 Pro 专属。图片转 RGB565 后分包上传。
    /// 目标尺寸与上传协议未验证（见 BlackSharkCodec），真机验证前谨慎使用。
    func uploadLCD(image: UIImage) async -> Bool {
        guard channel == .blackShark, isConnected, !demoMode else {
            log("LCD 上传被拒：仅黑鲨 6 Pro 可用（当前通道：\(channel.displayName)）")
            return false
        }
        guard let rgb565 = BlackSharkCodec.rgb565(from: image) else {
            log("LCD 上传失败：图片转换失败")
            return false
        }
        let packets = BlackSharkCodec.lcdUploadPackets(rgb565: rgb565)
        guard !packets.isEmpty else { return false }
        log("LCD 上传开始（\(packets.count) 包，协议未验证）")
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let requests = packets.map { GATTRequest(payload: $0) }
            ble.enqueueBatch(requests, priority: 50) { batchResult in
                guard !resumed else { return }
                resumed = true
                switch batchResult {
                case .success: continuation.resume(returning: true)
                case .failure: continuation.resume(returning: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: false)
            }
        }
        log(result ? "LCD 上传完成（设备是否显示未验证）" : "LCD 上传失败或超时")
        return result
    }

    /// 魔方灯效逐帧：像素为 0xRRGGBB。红魔专属，帧结构未验证。
    func sendCubeFrame(pixels: [UInt32]) {
        guard channel == .redMagic, isConnected, !demoMode else {
            log("魔方灯效被拒：仅红魔可用（当前通道：\(channel.displayName)）")
            return
        }
        let packets = RedMagicCodec.cubeFrame(pixels: pixels)
        guard !packets.isEmpty else { return }
        let requests = packets.map { GATTRequest(payload: $0) }
        ble.enqueueBatch(requests, priority: 50) { [weak self] result in
            Task { @MainActor [weak self] in
                if case .failure(let failure) = result {
                    self?.log("魔方灯效发送失败：\(failure.message)")
                }
            }
        }
    }

    /// 红魔制冷曲线（尽力而为，帧结构未验证）。未连红魔时只保存不发送。
    func setRedMagicCurve(_ levels: [Int]) {
        let clamped = levels.map { max(1, min($0, 8)) }
        redMagicCurveLevels = clamped
        guard channel == .redMagic, isConnected, !demoMode else {
            log("红魔曲线已保存（当前未连接红魔设备）")
            return
        }
        ble.enqueue(RedMagicCodec.encodeCoolingCurve(clamped), key: "redmagic-curve")
    }

    /// 红魔音频律动 pattern（尽力而为，帧结构未验证）。未连红魔时只保存不发送。
    func setRedMagicAudioPattern(_ index: Int) {
        let clamped = max(0, min(index, 255))
        redMagicAudioPatternIndex = clamped
        guard channel == .redMagic, isConnected, !demoMode else {
            log("红魔音频律动已保存（当前未连接红魔设备）")
            return
        }
        ble.enqueue(RedMagicCodec.encodeAudioPattern(clamped), key: "redmagic-audio")
    }

    /// 检查更新：拉自家仓库 GitHub Releases latest，解析
    /// tag_name/body/html_url；无新版或失败返回 nil。
    func checkForUpdate() async -> UpdateInfo? {
        guard let url = URL(string: Secrets.updateCheckURL) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let htmlURLString = json["html_url"] as? String,
                  let htmlURL = URL(string: htmlURLString) else { return nil }
            let notes = json["body"] as? String ?? ""
            let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.isVersion(remote, newerThan: Self.currentVersion) else { return nil }
            return UpdateInfo(version: remote, notes: notes, url: htmlURL)
        } catch {
            return nil
        }
    }

    /// 当前版本（与工程 MARKETING_VERSION 保持一致）。
    private static let currentVersion = "0.8.143"

    private static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // ------------------------------------------------------------ 设置导入导出

    func currentSettingsExport() -> B9XSettingsExport {
        B9XSettingsExport(
            targetTemperature: state.targetTemperature,
            customLevels: state.customLevels,
            ledType: state.ledType,
            ledColors: state.ledColors,
            ledPeriod: state.ledPeriod,
            ledLight: state.ledLight,
            runMode: state.runMode,
            freezeMode: state.freezeMode,
            coldProtectionEnabled: state.coldProtectionEnabled,
            hotProtectionEnabled: state.hotProtectionEnabled
        )
    }

    func applySettingsImport(_ settings: B9XSettingsExport) {
        state.targetTemperature = settings.targetTemperature
        state.customLevels = settings.customLevels
        state.ledType = settings.ledType
        state.ledColors = settings.ledColors
        state.ledPeriod = settings.ledPeriod
        state.ledLight = settings.ledLight
        state.runMode = settings.runMode
        state.freezeRequested = settings.freezeMode
        state.coldProtectionEnabled = settings.coldProtectionEnabled
        state.hotProtectionEnabled = settings.hotProtectionEnabled
        if settings.runMode == B9XProtocol.modeCustom {
            setCustomCurve(settings.customLevels)
        } else {
            setRunMode(
                mode: settings.runMode,
                targetTemperature: settings.targetTemperature
            )
        }
        if isConnected && state.ready {
            setFreezeEnabled(settings.freezeMode)
        }
        applyLed(
            type: settings.ledType,
            period: settings.ledPeriod,
            colors: settings.ledColors,
            light: settings.ledLight
        )
    }

    func clearError() {
        error = nil
        state.lastError = nil
    }

    nonisolated static func modeName(_ mode: Int) -> String {
        switch mode {
        case B9XProtocol.modeSmart: return "智能温控"
        case B9XProtocol.modeManual: return "手动"
        case B9XProtocol.modeOverclock: return "超频"
        case B9XProtocol.modeExperimentalSmart: return "实验智能"
        case B9XProtocol.modeCustom: return "自定义曲线"
        default: return "未知"
        }
    }

    nonisolated static func thermalModeName(_ mode: Int) -> String {
        switch mode {
        case B9XProtocol.thermalModeBattery: return "电池温控"
        case B9XProtocol.thermalModeCoolerTarget: return "目标温控"
        default: return "温控"
        }
    }
}
