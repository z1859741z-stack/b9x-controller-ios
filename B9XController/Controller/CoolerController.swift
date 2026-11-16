import Combine
import Foundation
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
    var customLevels: [Int] = [40, 60, 80, 100, 120, 140, 155, 170, 175]
    var ledType: Int = 3
    var ledColors: [Int] = [0xFF6EE7FF, 0xFF5B8CFF, 0xFFA78BFA, 0xFFFF5D8F]
    var ledPeriod: Int = 40
    var ledLight: Int = 200
    var runMode: Int = 0
    var freezeModeEnabled: Bool = false
    var coldProtectionEnabled: Bool = true
    var hotProtectionEnabled: Bool = true
}

/// 业务控制器：把 BLE 字节流翻译成 UI 可用的状态与命令。
/// 对照 Flutter 项目的 `cooler_controller.dart`。
@MainActor
final class CoolerController: ObservableObject {
    static let shared = CoolerController()

    @Published private(set) var state = CoolerState()
    @Published private(set) var connection: BLEConnectionState = .idle
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published var error: String?
    @Published private(set) var phoneThermal = PhoneThermalState.nominal

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
    /// 电池智能稳温：用系统热状态代替电池温度，智能变频维持目标区间。
    @Published var batterySmartTempEnabled = false
    @Published var batteryTempMin: Int = 30
    @Published var batteryTempMax: Int = 38
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
    private var pollTimer: Timer?
    private var thermalTimer: Timer?
    private var bootstrapped = false
    private var didInitAfterConnect = false

    private enum DefaultsKey {
        static let lastRunMode = "b9x.lastRunMode"
        static let lastTargetTemperature = "b9x.lastTargetTemperature"
        static let lastColdLevel = "b9x.lastColdLevel"
        static let lastWindLevel = "b9x.lastWindLevel"
        static let lastColdLevelOC = "b9x.lastColdLevelOC"
        static let lastWindLevelOC = "b9x.lastWindLevelOC"
    }

    init() {
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
        thermalTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.phoneThermal = PhoneThermalState.from(ProcessInfo.processInfo.thermalState)
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
        batteryCharging = device.batteryState == .charging || device.batteryState == .full
    }

    func log(_ message: String) {
        logs.append(LogEntry(date: Date(), message: message))
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    var isConnected: Bool { connection == .connected || demoMode }

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
        pollTimer?.invalidate()
        pollTimer = nil
        demoMode = true
        state = .demo
        log("进入宣传演示模式（不扫描、不连接、不发蓝牙指令）")
    }

    func exitDemo() {
        demoMode = false
        state = CoolerState()
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
        ble.connect(device)
    }

    func disconnect() {
        expectDisconnect = true
        pollTimer?.invalidate()
        pollTimer = nil
        ble.disconnect()
        state = CoolerState()
    }

    private func afterConnected() {
        // 握手 + 首次状态拉取。这些请求本身也会换回 0x13 状态帧。
        ble.enqueue(B9XProtocol.handshake(), key: "init")
        ble.enqueue(B9XProtocol.requestMacAddress(), key: "mac")
        ble.enqueue(B9XProtocol.readTimedShutdown(), key: "timer")
        ble.enqueue(B9XProtocol.requestRunModeParams(4), key: "curve")
        if restoreLastModeOnConnect {
            restoreLastMode()
        }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ble.enqueue(B9XProtocol.getExperimentalRunMode(), key: "poll")
            }
        }
    }

    private func restoreLastMode() {
        let defaults = UserDefaults.standard
        let mode = defaults.integer(forKey: DefaultsKey.lastRunMode)
        guard mode >= 0, mode <= 4 else { return }
        let target = defaults.integer(forKey: DefaultsKey.lastTargetTemperature)
        let cold = defaults.integer(forKey: DefaultsKey.lastColdLevel)
        let wind = defaults.integer(forKey: DefaultsKey.lastWindLevel)
        let coldOC = defaults.integer(forKey: DefaultsKey.lastColdLevelOC)
        let windOC = defaults.integer(forKey: DefaultsKey.lastWindLevelOC)
        // 只有之前确实存过模式才恢复（target/cold/wind 任一非 0 即视为存过）。
        guard target != 0 || cold != 0 || wind != 0 else { return }
        ble.enqueue(
            B9XProtocol.setRunMode(
                mode: mode,
                targetTemperature: target,
                windLevel: wind,
                coldLevel: cold,
                windLevelOverclock: windOC,
                coldLevelOverclock: coldOC
            ),
            key: "mode"
        )
    }

    private func rememberMode(_ mode: Int, target: Int, cold: Int, wind: Int, coldOC: Int, windOC: Int) {
        let defaults = UserDefaults.standard
        defaults.set(mode, forKey: DefaultsKey.lastRunMode)
        defaults.set(target, forKey: DefaultsKey.lastTargetTemperature)
        defaults.set(cold, forKey: DefaultsKey.lastColdLevel)
        defaults.set(wind, forKey: DefaultsKey.lastWindLevel)
        defaults.set(coldOC, forKey: DefaultsKey.lastColdLevelOC)
        defaults.set(windOC, forKey: DefaultsKey.lastWindLevelOC)
    }

    // ------------------------------------------------------------ 事件处理

    private func onData(_ bytes: Data) {
        guard let event = B9XProtocol.parse(bytes) else { return }
        switch event {
        case .state(let e):
            state.applyStateEvent(e)
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
            pollTimer?.invalidate()
            pollTimer = nil
            if state.connected {
                log("连接已断开")
                if !expectDisconnect {
                    notifyDisconnect()
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
        log("已刷新设备状态")
    }

    // ------------------------------------------------------------ 场景联动引擎
    // 优先级：游戏 > 电池温度 > 充电；超频体验与用户手动操作始终优先。

    private func markManualOverride() {
        manualOverrideUntil = Date().addingTimeInterval(manualOverrideSeconds)
    }

    /// 电池温控模式：开启电池智能稳温，用智能变频维持目标区间下限。
    func setBatteryTempMode() {
        batterySmartTempEnabled = true
        setRunMode(mode: B9XProtocol.modeSmart, targetTemperature: batteryTempMin)
        log("切换到电池温控模式")
    }

    func evaluateAutomation() {
        guard automationStandby, isConnected, !demoMode else { return }
        if let until = manualOverrideUntil, Date() < until { return }
        if gameLinkageEnabled && !gameLinkageNoted {
            gameLinkageNoted = true
            log("游戏联动：iOS 无法直接检测前台游戏，请用快捷指令自动化触发")
        }
        if batterySmartTempEnabled {
            switch phoneThermal {
            case .serious, .critical:
                if state.runMode != B9XProtocol.modeSmart || state.targetTemperature != batteryTempMin {
                    setRunMode(mode: B9XProtocol.modeSmart, targetTemperature: batteryTempMin, manual: false)
                    log("电池智能稳温：手机过热，目标温度调至 \(batteryTempMin)°C")
                }
                return
            case .fair:
                let mid = (batteryTempMin + batteryTempMax) / 2
                if state.runMode != B9XProtocol.modeSmart || state.targetTemperature != mid {
                    setRunMode(mode: B9XProtocol.modeSmart, targetTemperature: mid, manual: false)
                    log("电池智能稳温：手机温热，目标温度调至 \(mid)°C")
                }
                return
            case .nominal:
                break
            }
        }
        if chargeFollowEnabled && batteryCharging {
            if state.runMode != chargeFollowMode {
                setRunMode(mode: chargeFollowMode, manual: false)
                log("充电随动：正在充电，已切换指定模式")
            }
        }
    }

    // ------------------------------------------------------------ 命令

    func setColdLevel(_ level: Int) {
        state.coldLevel = level
        ble.enqueue(B9XProtocol.setColdLevel(level), key: "cold")
    }

    func setWindLevel(_ level: Int) {
        state.windLevel = level
        ble.enqueue(B9XProtocol.setSpeedLevel(level), key: "wind")
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
        if targetTemperature != 0 { state.targetTemperature = targetTemperature }
        if coldLevel != 0 { state.coldLevel = coldLevel }
        if windLevel != 0 { state.windLevel = windLevel }
        if coldLevelOverclock != 0 { state.coldLevelOverclock = coldLevelOverclock }
        if windLevelOverclock != 0 { state.windLevelOverclock = windLevelOverclock }
        if let customLevels = customLevels { state.customLevels = customLevels }
        state.runMode = mode
        if manual {
            markManualOverride()
            log("切换模式：\(modeName(mode))")
        }
        rememberMode(
            mode,
            target: targetTemperature == 0 ? state.targetTemperature : targetTemperature,
            cold: coldLevel == 0 ? state.coldLevel : coldLevel,
            wind: windLevel == 0 ? state.windLevel : windLevel,
            coldOC: coldLevelOverclock == 0 ? state.coldLevelOverclock : coldLevelOverclock,
            windOC: windLevelOverclock == 0 ? state.windLevelOverclock : windLevelOverclock
        )
        ble.enqueue(
            B9XProtocol.setRunMode(
                mode: mode,
                targetTemperature: targetTemperature,
                windLevel: windLevel,
                coldLevel: coldLevel,
                windLevelOverclock: windLevelOverclock,
                coldLevelOverclock: coldLevelOverclock,
                customLevels: customLevels
            ),
            key: "mode"
        )
    }

    /// 智能温控三档（设备内置组合：安静 / 均衡 / 强劲）。
    func setSmartLevel(_ index: Int) {
        let presets: [[Int]] = [
            [18, 77, 115, 77, 134],
            [16, 95, 115, 95, 153],
            [16, 115, 115, 134, 173],
        ]
        let p = presets[max(0, min(index, presets.count - 1))]
        setRunMode(
            mode: B9XProtocol.modeSmart,
            targetTemperature: p[0],
            windLevel: p[1],
            coldLevel: p[2],
            windLevelOverclock: p[3],
            coldLevelOverclock: p[4]
        )
    }

    func setManual(coldLevel: Int = 0, windLevel: Int = 0) {
        setRunMode(
            mode: B9XProtocol.modeManual,
            coldLevel: coldLevel == 0 ? state.coldLevel : coldLevel,
            windLevel: windLevel == 0 ? state.windLevel : windLevel
        )
    }

    func setOverclock(coldLevel: Int = 134, windLevel: Int = 77) {
        setRunMode(
            mode: B9XProtocol.modeOverclock,
            coldLevelOverclock: coldLevel,
            windLevelOverclock: windLevel
        )
    }

    func setCustomCurve(_ values: [Int]) {
        state.customLevels = values
        ble.enqueue(
            B9XProtocol.setRunMode(mode: B9XProtocol.modeCustom, customLevels: values),
            key: "curve_set"
        )
    }

    func setQuickSwitchRunMode(_ mode: Int) {
        state.quickSwitchRunMode = mode
        ble.enqueue(B9XProtocol.setQuickSwitchRunMode(mode), key: "quick")
    }

    func setExperimentalMode(enabled: Bool, level: Int = 0, targetTemperature: Int = 0) {
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
        state.lightOn = on
        ble.enqueue(on ? B9XProtocol.lightOn() : B9XProtocol.lightOff(), key: "light")
    }

    func applyLed(type: Int, period: Int = 0, colors: [Int] = [], light: Int = 0, colorful: Bool = false) {
        state.ledType = type
        state.ledPeriod = period
        state.ledColors = colors
        state.ledLight = light
        state.ledColorful = colorful
        state.lightOn = type != 0
        ble.enqueueMany(
            B9XProtocol.setLedColor(type: type, period: period, colors: colors, light: light, colorful: colorful)
        )
    }

    func setTimedShutdown(once: Bool, mode: Int, seconds: Int) {
        state.timedShutdownRunning = seconds > 0
        state.timedShutdownMode = mode
        state.timeCountdown = seconds
        ble.enqueue(
            B9XProtocol.setTimedShutdown(once: once, mode: mode, seconds: seconds),
            key: "shutdown"
        )
    }

    func readTimedShutdown() {
        ble.enqueue(B9XProtocol.readTimedShutdown(), key: "timer")
    }

    func requestTempHistory() {
        state.tempHistory = []
        ble.enqueue(B9XProtocol.requestTempHistory(), key: "history")
    }

    /// 冻结模式：设备端结霜保护开关。
    func setFreezeMode(_ enabled: Bool) {
        state.freezeModeEnabled = enabled
        ble.enqueue(B9XProtocol.setFreezeMode(enabled), key: "freeze")
    }

    /// 低温/高温保护开关（设备侧自动降档）。
    func offProtection(low: Bool? = nil, high: Bool? = nil) {
        if let low = low {
            state.coldProtectionEnabled = low
            ble.enqueue(B9XProtocol.setTempProtect(low: true, enabled: low), key: "protect_low")
        }
        if let high = high {
            state.hotProtectionEnabled = high
            ble.enqueue(B9XProtocol.setTempProtect(low: false, enabled: high), key: "protect_high")
        }
    }

    func resetFactory() {
        ble.enqueue(B9XProtocol.resetFlash(), key: "reset")
    }

    func handshake() {
        ble.enqueue(B9XProtocol.handshake(), key: "init")
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
            freezeModeEnabled: state.freezeModeEnabled,
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
        state.freezeModeEnabled = settings.freezeModeEnabled
        state.coldProtectionEnabled = settings.coldProtectionEnabled
        state.hotProtectionEnabled = settings.hotProtectionEnabled
        setRunMode(
            mode: settings.runMode,
            targetTemperature: settings.targetTemperature,
            customLevels: settings.runMode == B9XProtocol.modeCustom ? settings.customLevels : nil
        )
        applyLed(
            type: settings.ledType,
            period: settings.ledPeriod,
            colors: settings.ledColors,
            light: settings.ledLight
        )
    }

    func clearError() {
        error = nil
    }

    static func modeName(_ mode: Int) -> String {
        switch mode {
        case B9XProtocol.modeSmart: return "智能温控"
        case B9XProtocol.modeManual: return "手动"
        case B9XProtocol.modeOverclock: return "超频"
        case B9XProtocol.modeExperimentalSmart: return "实验智能"
        case B9XProtocol.modeCustom: return "自定义曲线"
        default: return "未知"
        }
    }
}
