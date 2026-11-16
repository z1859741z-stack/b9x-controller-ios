import Foundation

/// B9X 散热器 BLE 协议编解码。
///
/// 逐行对照开源 Flutter 项目 `feizhi-b9x-cooler-client` 的
/// `lib/core/protocol/b9x_protocol.dart`（协议逆向自官方飞智游戏厅 7.2.11）。
/// 只做纯字节运算，不依赖任何平台 API。

enum B9XEvent {
    case state(StateEventData)
    case led(LedEventData)
    case customLevels([Int])
    case mac(String)
    case tempHistoryChunk(Data)
    case tempHistoryDone
    case experimentalMode(on: Bool, value: Int)
    case timedShutdown(mode: Int, running: Bool, seconds: Int)
    case firmware(String)
}

struct StateEventData {
    var ipType: Int = 0
    var runMode: Int = 0
    var overclockUsableLevel: Int = 0
    var coldLevel: Int = 0
    var windLevel: Int = 0
    var targetTemperature: Int = 0
    var temperature: Int = 0
    var temperatureDecimal: Int = 0
    var hotSurfaceTemperature: Int = 0
    var coldRunLevel: Int = 0
    var windRunLevel: Int = 0
    var speed: Int = 0
    var lightOn: Bool = false
    var ledType: Int = 0
    var quickSwitchRunMode: Int = 0
    var coldProtection: Bool = false
    var runningInMaxLevel: Bool = false
    var timedShutdownMode: Int = 0
    var timedShutdownRunning: Bool = false
    var hotProtectionEnabled: Bool = false
    var coldProtectionEnabled: Bool = false
    var timedCountdownInMinute: Bool = false
    var freezeModeEnabled: Bool = false
    var timeCountdown: Int = 0
}

struct LedEventData {
    var type: Int = 0
    var period: Int = 0
    var colors: [Int] = []
    var light: Int = 0
    var colorful: Bool = false
}

enum B9XProtocol {
    // ------------------------------------------------------------ GATT 常量

    static let serviceUUID = "0000FFE0-0000-1000-8000-00805F9B34FB"
    static let writeCharUUID = "0000FFE1-0000-1000-8000-00805F9B34FB"
    static let notifyCharUUID = "0000FFE4-0000-1000-8000-00805F9B34FB"

    /// 扫描时用于过滤的广播名。
    static let deviceName = "Flydigi B9X"

    static let supportedNames: [String] = [
        "Flydigi B9X",
        "Flydigi B8X",
        "Flydigi B7X",
        "Flydigi B7",
        "Flydigi B6X",
        "Flydigi B6",
        "Flydigi B5X",
        "Flydigi B5Pro",
        "Flydigi B5",
        "Flydigi Waspwing2 Pro",
    ]

    // ------------------------------------------------------------ 运行模式

    static let modeSmart = 0
    static let modeManual = 1
    static let modeOverclock = 2
    static let modeExperimentalSmart = 3
    static let modeCustom = 4

    // ------------------------------------------------------------ 档位（电压）

    /// 可选档位值（0 表示关闭）。
    static let levels: [Int] = [0, 19, 38, 57, 77, 95, 115, 134]

    /// 档位值对应电压：`((level - 19) * 0.5 / 19) + 1.5`。
    static func voltsOf(_ level: Int) -> Double {
        if level <= 0 { return 0 }
        return (Double(level - 19) * 0.5 / 19.0) + 1.5
    }

    static func voltsLabel(_ level: Int) -> String {
        if level <= 0 { return "--" }
        return String(format: "%.1fV", voltsOf(level))
    }

    /// 最接近给定电压的档位值。
    static func nearestLevel(_ volts: Double) -> Int {
        var best = levels.first ?? 0
        var bestDiff = Double.infinity
        for level in levels {
            let diff = abs(voltsOf(level) - volts)
            if diff < bestDiff {
                bestDiff = diff
                best = level
            }
        }
        return best
    }

    // ------------------------------------------------------------ 灯效枚举

    static let ledTypes: [Int: String] = [
        0: "关闭",
        1: "启动光",
        2: "关机光",
        3: "彩虹流动",
        4: "光环",
        5: "呼吸",
        6: "渐变",
        7: "闪烁",
        8: "双色启动",
        9: "双色关机",
        10: "纯黑",
        11: "长亮",
        12: "智能彩虹",
        16: "多色旋转",
        17: "心跳",
        19: "音乐律动",
        20: "赛博朋克",
        21: "碰撞",
        22: "主题",
    ]

    // ------------------------------------------------------------ 命令帧

    static func setColdLevel(_ level: Int) -> Data {
        Data([0x12, UInt8(level & 0xFF)])
    }

    static func setSpeedLevel(_ level: Int) -> Data {
        Data([0x11, UInt8(level & 0xFF)])
    }

    static func lightOn() -> Data { Data([0x10, 0xFF]) }
    static func lightOff() -> Data { Data([0x10, 0x00]) }

    /// 设置运行模式。
    static func setRunMode(
        mode: Int,
        targetTemperature: Int = 0,
        windLevel: Int = 0,
        coldLevel: Int = 0,
        windLevelOverclock: Int = 0,
        coldLevelOverclock: Int = 0,
        customLevels: [Int]? = nil
    ) -> Data {
        if mode == modeCustom {
            var frame = Data(count: 11)
            frame[0] = 0x20
            frame[1] = UInt8(mode & 0xFF)
            let levels = customLevels ?? []
            for i in 0..<min(9, levels.count) {
                frame[2 + i] = UInt8(levels[i] & 0xFF)
            }
            return frame
        }
        return Data([
            0x20,
            UInt8(mode & 0xFF),
            UInt8(coldLevelOverclock & 0xFF),
            UInt8((windLevelOverclock / 100) & 0xFF),
            UInt8((windLevelOverclock % 100) & 0xFF),
            UInt8(targetTemperature & 0xFF),
            UInt8(coldLevel & 0xFF),
            UInt8((windLevel / 100) & 0xFF),
            UInt8((windLevel % 100) & 0xFF),
        ])
    }

    static func requestRunModeParams(_ mode: Int) -> Data {
        Data([0x22, UInt8(mode & 0xFF)])
    }

    static func requestTempHistory() -> Data { Data([0x40, 0x00]) }

    static func requestMacAddress() -> Data { Data([0x24, 0x00]) }

    static func resetFlash() -> Data { Data([0xFF, 0x0A]) }

    static func handshake() -> Data { Data([0xA5, 0xA0, 0x00, 0x00]) }

    static func setQuickSwitchRunMode(_ mode: Int) -> Data {
        Data([0x57, UInt8(mode & 0xFF)])
    }

    static func setExperimentalRunMode(enabled: Bool, level: Int = 0, targetTemperature: Int = 0) -> Data {
        Data([
            0x52,
            0x01,
            enabled ? UInt8(level & 0xFF) : 0,
            enabled ? UInt8((targetTemperature / 100) & 0xFF) : 0,
        ])
    }

    static func getExperimentalRunMode() -> Data { Data([0x52, 0x00]) }

    static func setMaxColdLevel(a: Int = 0, b: Int = 0, c: Int = 0, d: Int = 0, e: Int = 0, f: Int = 0) -> Data {
        Data([0x33, UInt8(a), UInt8(b), UInt8(c), UInt8(d), UInt8(e), UInt8(f)])
    }

    static func setCustomCurve(_ values: [Int]) -> Data {
        var frame = Data(count: values.count + 2)
        frame[0] = 0x34
        frame[1] = 0
        for (i, v) in values.enumerated() {
            frame[i + 2] = UInt8(v & 0xFF)
        }
        return frame
    }

    /// 定时关机。seconds 为总秒数。
    static func setTimedShutdown(once: Bool, mode: Int, seconds: Int) -> Data {
        let total = max(0, min(seconds, 0xFFFF))
        return Data([
            0x60,
            UInt8(mode & 0xFF),
            once ? 1 : 0,
            UInt8((total >> 8) & 0xFF),
            UInt8(total & 0xFF),
        ])
    }

    static func readTimedShutdown() -> Data { Data([0x61, 0x00]) }

    /// 冻结模式：官方 `ctrlFreezeMode` → `26 01/00 00 00`。
    static func setFreezeMode(_ enabled: Bool) -> Data {
        Data([0x26, enabled ? 1 : 0, 0, 0])
    }

    /// 温度保护：官方 `offTempProtect` → `32 idx value`，idx 0=低温 1=高温。
    static func setTempProtect(low: Bool, enabled: Bool) -> Data {
        Data([0x32, low ? 0 : 1, enabled ? 1 : 0])
    }

    /// 设置灯效（20 字节分包 + 触发帧）。
    static func setLedColor(type: Int, period: Int = 0, colors: [Int] = [], light: Int = 0, colorful: Bool = false) -> [Data] {
        var packets: [Data] = []
        let total = colors.count
        let chunkCount = total > 4 ? 2 : 1
        for chunk in 0..<chunkCount {
            var frame = Data(count: 20)
            frame[0] = 0x50
            frame[1] = UInt8(type & 0xFF)
            frame[2] = UInt8(period & 0xFF)
            frame[3] = UInt8(total & 0xFF)
            frame[4] = UInt8(chunk + 1)
            let start = chunk * 4
            let end = min(start + 4, total)
            for i in start..<end {
                let rgb = colors[i]
                let offset = 5 + (i - start) * 3
                frame[offset] = UInt8((rgb >> 16) & 0xFF)
                frame[offset + 1] = UInt8((rgb >> 8) & 0xFF)
                frame[offset + 2] = UInt8(rgb & 0xFF)
            }
            frame[17] = UInt8(light & 0xFF)
            frame[18] = (type == 19 && colorful) ? 2 : 0
            packets.append(frame)
        }
        packets.append(Data([0x51, UInt8(type & 0xFF)]))
        return packets
    }

    // ------------------------------------------------------------ 状态解析

    static func parse(_ value: Data) -> B9XEvent? {
        guard !value.isEmpty else { return nil }
        let cmd = value[0]
        switch cmd {
        case 0x13:
            return parseState(value).map { .state($0) }
        case 0x22:
            if value.count >= 11 && value[1] == 0x04 {
                return .customLevels((0..<9).map { Int(value[2 + $0]) })
            }
            return nil
        case 0x24:
            if value.count >= 7 {
                let mac = [value[6], value[5], value[4], value[3], value[2], value[1]]
                    .map { String(format: "%02X", $0) }
                    .joined(separator: ":")
                return .mac(mac)
            }
            return nil
        case 0x40, 0x41:
            return .tempHistoryChunk(value.subdata(in: 1..<value.count))
        case 0x42:
            return .tempHistoryDone
        case 0x51:
            return parseLed(value).map { .led($0) }
        case 0x52:
            if value.count >= 4 {
                return .experimentalMode(
                    on: value[2] == 0xE6 && value[3] == 0x39,
                    value: Int(value[2])
                )
            }
            return nil
        case 0x61:
            if value.count >= 5 {
                return .timedShutdown(
                    mode: Int(value[1]),
                    running: value[2] == 1,
                    seconds: (Int(value[3]) << 8) + Int(value[4])
                )
            }
            return nil
        default:
            if value.count > 5 && cmd >= 0x30 && cmd < 0x80 {
                return .firmware(ascii(value))
            }
            return nil
        }
    }

    private static func ascii(_ bytes: Data) -> String {
        var out = ""
        for b in bytes where b >= 0x20 && b < 0x7F {
            out.append(Character(UnicodeScalar(b)))
        }
        return out
    }

    private static func parseLed(_ value: Data) -> LedEventData? {
        guard value.count >= 19 else { return nil }
        var colors: [Int] = []
        let total = Int(value[3])
        let count: Int
        if value[4] == 1 {
            count = min(total, 4)
        } else {
            count = max(0, min(total - 4, 4))
        }
        for i in 0..<count {
            let o = 5 + i * 3
            guard o + 2 < value.count else { break }
            colors.append((Int(value[o]) << 16) | (Int(value[o + 1]) << 8) | Int(value[o + 2]))
        }
        return LedEventData(
            type: Int(value[1]),
            period: Int(value[2]),
            colors: colors,
            light: Int(value[17]),
            colorful: value[18] == 2
        )
    }

    /// 0x13 状态帧。B9X/B8X 为 20 字节布局，老型号为紧凑布局。
    private static func parseState(_ v: Data) -> StateEventData? {
        guard v.count >= 10 else { return nil }

        if v.count >= 20 {
            let flags = Int(v[17])
            return StateEventData(
                ipType: Int(v[1]),
                runMode: Int(v[2]) >> 4,
                overclockUsableLevel: Int(v[2]) & 0x0F,
                coldLevel: Int(v[3]),
                windLevel: signed(v[4]) * 100 + Int(v[5]),
                targetTemperature: Int(v[6]),
                temperature: signed(v[7]),
                temperatureDecimal: Int(v[8]),
                hotSurfaceTemperature: signed(v[9]),
                coldRunLevel: Int(v[10]),
                windRunLevel: Int(v[11]),
                speed: signed(v[12]) * 100 + Int(v[13]),
                lightOn: v[14] == 0xFF,
                ledType: Int(v[15]),
                quickSwitchRunMode: Int(v[16]),
                coldProtection: (flags & 0x01) != 0,
                runningInMaxLevel: (flags & 0x02) != 0,
                timedShutdownMode: (flags >> 2) & 0x01,
                timedShutdownRunning: (flags & 0x08) != 0,
                hotProtectionEnabled: ((flags >> 4) & 0x01) != 0 || (flags >> 4) == 2,
                coldProtectionEnabled: ((flags >> 5) & 0x01) != 0,
                timedCountdownInMinute: ((flags >> 6) & 0x01) != 0,
                freezeModeEnabled: ((flags >> 7) & 0x01) != 0,
                timeCountdown: (Int(v[18]) << 8) + Int(v[19])
            )
        }

        let wind = v.count > 18 ? Int(v[6]) * 100 + Int(v[18]) : Int(v[6])
        let speed = v.count > 11 ? Int(v[11]) * 100 + Int(v[10]) : 0
        return StateEventData(
            ipType: Int(v[1]),
            runMode: Int(v[4]),
            overclockUsableLevel: 0,
            coldLevel: Int(v[7]),
            windLevel: wind,
            targetTemperature: Int(v[9]),
            temperature: v[1] == 0 ? -Int(v[2]) : Int(v[2]),
            temperatureDecimal: Int(v[3]),
            hotSurfaceTemperature: v.count > 16 ? signed(v[16]) : 0,
            coldRunLevel: v.count > 15 ? Int(v[15]) : 0,
            windRunLevel: v.count > 14 ? Int(v[14]) : 0,
            speed: speed,
            lightOn: v[8] == 0xFF,
            ledType: 0,
            quickSwitchRunMode: 0,
            coldProtection: (v[17] & 0x0F) == 1,
            runningInMaxLevel: false,
            timedShutdownMode: 0,
            timedShutdownRunning: false,
            hotProtectionEnabled: ((v[17] >> 4) & 0x01) != 0,
            coldProtectionEnabled: false,
            timedCountdownInMinute: false,
            freezeModeEnabled: false,
            timeCountdown: 0
        )
    }

    private static func signed(_ b: UInt8) -> Int {
        let v = Int(b)
        return v > 127 ? v - 256 : v
    }
}
