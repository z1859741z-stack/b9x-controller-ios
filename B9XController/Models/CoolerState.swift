import Foundation

/// 设备的实时状态快照（值类型）。
struct CoolerState {
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
    var speed: Int = 0
    var runMode: Int = B9XProtocol.modeSmart
    var overclockUsableLevel: Int = 0
    var ledType: Int = 0
    var lightOn: Bool = false
    var coldProtection: Bool = false
    var coldProtectionEnabled: Bool = false
    var hotProtectionEnabled: Bool = false
    var runningInMaxLevel: Bool = false
    var freezeModeEnabled: Bool = false
    var timedShutdownRunning: Bool = false
    var timedShutdownMode: Int = 0
    var timedCountdownInMinute: Bool = false
    var timeCountdown: Int = 0
    var quickSwitchRunMode: Int = 0
    var firmwareVersion: String = ""
    var mac: String = ""
    var experimentalModeOn: Bool = false
    var customLevels: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 0]
    var ledColors: [Int] = []
    var ledPeriod: Int = 0
    var ledLight: Int = 0
    var ledColorful: Bool = false
    var tempHistory: [Int] = []

    var temperatureValue: Double {
        Double(temperature) + Double(temperatureDecimal) / 10.0
    }

    /// 智能模式下设备实际使用超频组合值。
    var usingOverclock: Bool {
        runMode == B9XProtocol.modeSmart && overclockUsableLevel > 0
    }

    var effectiveColdLevel: Int { usingOverclock ? coldLevelOverclock : coldLevel }
    var effectiveWindLevel: Int { usingOverclock ? windLevelOverclock : windLevel }

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

    mutating func applyStateEvent(_ e: StateEventData) {
        temperature = e.temperature
        temperatureDecimal = e.temperatureDecimal
        hotSurfaceTemperature = e.hotSurfaceTemperature
        targetTemperature = e.targetTemperature
        coldLevel = e.coldLevel
        windLevel = e.windLevel
        if coldLevelOverclock == 0 { coldLevelOverclock = e.coldLevel }
        if windLevelOverclock == 0 { windLevelOverclock = e.windLevel }
        speed = e.speed
        runMode = e.runMode
        overclockUsableLevel = e.overclockUsableLevel
        ledType = e.ledType
        lightOn = e.lightOn
        coldProtection = e.coldProtection
        coldProtectionEnabled = e.coldProtectionEnabled
        hotProtectionEnabled = e.hotProtectionEnabled
        runningInMaxLevel = e.runningInMaxLevel
        freezeModeEnabled = e.freezeModeEnabled
        timedShutdownRunning = e.timedShutdownRunning
        timedShutdownMode = e.timedShutdownMode
        timedCountdownInMinute = e.timedCountdownInMinute
        timeCountdown = e.timeCountdown
        quickSwitchRunMode = e.quickSwitchRunMode
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
        s.windLevel = 77
        s.coldLevelOverclock = 134
        s.windLevelOverclock = 77
        s.speed = 2860
        s.runMode = B9XProtocol.modeSmart
        s.overclockUsableLevel = 2
        s.ledType = 3
        s.lightOn = true
        s.coldProtectionEnabled = true
        s.hotProtectionEnabled = true
        s.firmwareVersion = "1.2.9"
        s.mac = "A4:C1:38:00:00:01"
        s.customLevels = [40, 60, 80, 100, 120, 140, 155, 170, 175]
        s.ledColors = [0xFF6EE7FF, 0xFF5B8CFF, 0xFFA78BFA, 0xFFFF5D8F]
        s.ledPeriod = 40
        s.ledLight = 200
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
