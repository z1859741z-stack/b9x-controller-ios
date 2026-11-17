import Foundation

/// 设备的实时状态快照（值类型）。
struct CoolerState {
    /// 连接阶段（与 CoolerController.phase 同步；UI 可读 state.phase）。
    var phase: ConnectionPhase = .idle
    /// 设备通道（与 CoolerController.channel 同步）。
    var channel: DeviceChannel = .flydigi

    var connected: Bool = false
    var deviceName: String = "Flydigi B9X"
    var temperature: Int = 0
    var temperatureDecimal: Int = 0
    var hotSurfaceTemperature: Int = 0
    var targetTemperature: Int = 0
    var coldLevel: Int = 0
    var windLevel: Int = 0
    var coldLevelOverclock: Int = 0
    var windLevelOverclock: Int = 0
    /// 运行档位（状态帧 v[10]/v[11]；首页百分比用这两个换算）。
    var coldRunLevel: Int = 0
    var windRunLevel: Int = 0
    var speed: Int = 0
    var runMode: Int = B9XProtocol.modeSmart
    var overclockUsableLevel: Int = 0
    var ledType: Int = 0
    var lightOn: Bool = false
    var coldProtection: Bool = false
    var coldProtectionEnabled: Bool = false
    var hotProtectionEnabled: Bool = false
    var runningInMaxLevel: Bool = false
    /// Freeze（超频体验）进行中（flags bit7；v1 的 freezeModeEnabled 改名而来）。
    var freezeMode: Bool = false
    /// 本地 Freeze 意图（用户在本 App 里想要的状态；nil = 未表态）。
    var freezeRequested: Bool? = nil
    /// 模式切换事务进行中的目标模式（界面立即反馈用）。
    var pendingRunMode: Int? = nil
    /// READY：已收到第一帧 0x13。
    var ready: Bool = false
    var lastStateAt: Date? = nil
    var timedShutdownRunning: Bool = false
    var timedShutdownMode: Int = 0
    var timedCountdownInMinute: Bool = false
    /// 倒计时，单位秒（分钟×60）。
    var timeCountdown: Int = 0
    var quickSwitchRunMode: Int = 0
    var firmwareVersion: String = ""
    var mac: String = ""
    var experimentalModeOn: Bool = false
    var customLevels: [Int] = B9XProtocol.defaultCurveLevels
    var ledColors: [Int] = []
    var ledPeriod: Int = 0
    var ledLight: Int = 0
    var ledColorful: Bool = false
    var tempHistory: [Int] = []

    /// 软件温控环路模式：0=无，100=电池温控，101=目标温控。
    var softwareThermalMode: Int = B9XProtocol.thermalModeNone
    var batteryTargetC: Int = 20
    var coolerTargetC: Int = 0
    /// 当前选中的智能预设：0=静音，2=极寒（默认极寒）。
    var smartPreset: Int = 2
    /// 当前选中的手动预设：0=节能，1=强劲，2=极强（默认极强）。
    var manualPreset: Int = 2

    /// 首页横幅：假连提示 / Freeze 遗留提示。
    var connectionNote: String? = nil
    var lastError: String? = nil

    /// 本地优先：刚由用户改过的值在若干秒内不被回显覆盖。
    /// key："target" / "cold" / "wind" / "runMode"。
    var localHoldUntil: [String: Date] = [:]

    mutating func holdLocal(_ key: String, seconds: TimeInterval) {
        localHoldUntil[key] = Date().addingTimeInterval(seconds)
    }

    func isLocalHeld(_ key: String) -> Bool {
        if let until = localHoldUntil[key] { return Date() < until }
        return false
    }

    /// 运行档位（不是设定档位）：冷面温度按 §1 公式，负温减小数。
    var temperatureValue: Double {
        let decimal = Double(temperatureDecimal) / 100.0
        return temperature < 0 ? Double(temperature) - decimal : Double(temperature) + decimal
    }

    /// 智能模式下设备实际使用超频组合值。
    var usingOverclock: Bool {
        runMode == B9XProtocol.modeSmart && overclockUsableLevel > 0
    }

    var effectiveColdLevel: Int { usingOverclock ? coldLevelOverclock : coldLevel }
    var effectiveWindLevel: Int { usingOverclock ? windLevelOverclock : windLevel }

    /// 首页制冷强度（运行档位）：round(raw×100/184)。
    var coldPercent: Int {
        min(100, max(0, (coldRunLevel * 100 + 92) / 184))
    }

    /// 首页风扇强度（运行档位）：round(raw×100/255)。
    var windPercent: Int {
        min(100, max(0, (windRunLevel * 100 + 127) / 255))
    }

    /// 设定值百分比：冷设定 coldLevel×100/175。
    var coldSetPercent: Int {
        min(100, max(0, coldLevel * 100 / B9XProtocol.maxColdLevel))
    }

    /// 设定值百分比：风设定 windLevel×100/5700。
    var windSetPercent: Int {
        min(100, max(0, windLevel * 100 / B9XProtocol.maxWindLevel))
    }

    var runModeName: String {
        switch runMode {
        case B9XProtocol.modeSmart: return "智能温控"
        case B9XProtocol.modeManual: return "手动"
        case B9XProtocol.modeOverclock: return "超频"
        case B9XProtocol.modeExperimentalSmart: return "实验智能"
        case B9XProtocol.modeCustom: return "自定义曲线"
        default: return "未知"
        }
    }

    /// 当前模式的显示判定：Freeze 优先，其次软件温控环路，最后 runMode。
    var displayModeName: String {
        if freezeMode { return "超频模式" }
        switch softwareThermalMode {
        case B9XProtocol.thermalModeBattery: return "电池温控"
        case B9XProtocol.thermalModeCoolerTarget: return "目标温控"
        default: break
        }
        return runModeName
    }

    mutating func applyStateEvent(_ e: StateEventData) {
        // 本地刚改过 3 秒内的设定值不被回显覆盖；其余一律以回显为准。
        temperature = e.temperature
        temperatureDecimal = e.temperatureDecimal
        hotSurfaceTemperature = e.hotSurfaceTemperature
        if !isLocalHeld("target") {
            // 设备帧内目标只有 0..16：本地 -20（最冷）进帧前钳成 0，
            // 回显 0 就是“最冷”的设备表示，不能把它覆盖回本地的 -20。
            if !(targetTemperature < 0 && e.targetTemperature == 0) {
                targetTemperature = e.targetTemperature
            }
        }
        if !isLocalHeld("cold") { coldLevel = e.coldLevel }
        if !isLocalHeld("wind") { windLevel = e.windLevel }
        // 运行档位（v1 漏填）：一律以回显为准。
        coldRunLevel = e.coldRunLevel
        windRunLevel = e.windRunLevel
        speed = e.speed
        if !isLocalHeld("runMode") { runMode = e.runMode }
        overclockUsableLevel = e.overclockUsableLevel
        ledType = e.ledType
        lightOn = e.lightOn
        coldProtection = e.coldProtection
        coldProtectionEnabled = e.coldProtectionEnabled
        hotProtectionEnabled = e.hotProtectionEnabled
        runningInMaxLevel = e.runningInMaxLevel
        freezeMode = e.freezeMode
        timedShutdownRunning = e.timedShutdownRunning
        timedShutdownMode = e.timedShutdownMode
        timedCountdownInMinute = e.timedCountdownInMinute
        timeCountdown = e.timeCountdown
        quickSwitchRunMode = e.quickSwitchRunMode
        ready = true
        lastStateAt = Date()
    }

    /// 演示数据：没有硬件时预览完整界面。
    static var demo: CoolerState {
        var s = CoolerState()
        s.connected = true
        s.deviceName = "Flydigi B9X"
        s.temperature = -3
        s.temperatureDecimal = 2
        s.hotSurfaceTemperature = 38
        s.targetTemperature = 16
        s.coldLevel = 115
        s.windLevel = 4500
        s.coldLevelOverclock = 134
        s.windLevelOverclock = 4500
        s.coldRunLevel = 150
        s.windRunLevel = 200
        s.speed = 4500
        s.runMode = B9XProtocol.modeSmart
        s.overclockUsableLevel = 2
        s.ledType = 3
        s.lightOn = true
        s.coldProtectionEnabled = true
        s.hotProtectionEnabled = true
        s.ready = true
        s.firmwareVersion = "1.2.9"
        s.mac = "A4:C1:38:00:00:01"
        s.customLevels = B9XProtocol.defaultCurveLevels
        s.ledColors = [0xFF6EE7FF, 0xFF5B8CFF, 0xFFA78BFA, 0xFFFF5D8F]
        s.ledPeriod = 40
        s.ledLight = 80
        s.phase = .ready
        s.channel = .flydigi
        return s
    }
}

/// 手机温度状态（iOS 读不到 CPU/GPU 温度，用系统热状态替代）。
enum PhoneThermalState: String {
    case nominal = "正常"
    case fair = "温热"
    case serious = "过热"
    case critical = "严重过热"

    static func from(_ state: ProcessInfo.ThermalState) -> PhoneThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
