import CoreBluetooth
import Foundation

/// 单条 GATT 请求（DEEP-DIVE §2.2）。
/// `characteristic` 为 nil 表示用当前通道的默认写特征；
/// `isOTA` 为 true 时写 Telink OTA 特征，忽略 `characteristic`。
struct GATTRequest {
    var characteristic: CBCharacteristic?
    var isOTA: Bool = false
    var payload: Data
    var delayAfterMilliseconds: Int = 0
    var requiresFreezeOff: Bool = false
    var responseRequired: Bool = false
    var isQuery: Bool = false
    var isRead: Bool = false
}

/// B9X 散热器 BLE 协议编解码（v2）。
///
/// 帧表以 `V2-SPEC.md §1` 为准：逐字节对照原版安卓 App（v0.8.143，
/// jadx 反编译）与开源 Flutter 客户端 `feizhi-b9x-cooler-client` 核对。
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
    /// flags bit5：低温保护正在生效（动作中）。
    var coldProtection: Bool = false
    var runningInMaxLevel: Bool = false
    var timedShutdownMode: Int = 0
    var timedShutdownRunning: Bool = false
    /// flags bit4：高温保护正在生效（只是状态位，无对应开关命令）。
    var hotProtectionEnabled: Bool = false
    /// flags bit0：低温保护开关已开启。
    var coldProtectionEnabled: Bool = false
    var timedCountdownInMinute: Bool = false
    /// flags bit7：Freeze（超频体验）进行中。
    var freezeMode: Bool = false
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
    // 全部走 Secrets（混淆存储）；数值与原来一致，
    // 写/通知分工以原版安卓 + Flutter 三处实测为准，
    // 详见 Secrets.swift 头部注释。

    /// 飞智主服务。
    static var serviceUUID: String { Secrets.flydigiServiceUUID }
    /// 飞智写特征（命令上行）。
    static var writeCharUUID: String { Secrets.flydigiWriteUUID }
    /// 飞智通知特征（状态帧下行）。
    static var notifyCharUUID: String { Secrets.flydigiNotifyUUID }

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
    static let modeOverclock = 2 // 仅用于回显识别（state.runMode == 2 时按超频显示）；v2 不再发 mode 2 的 0x20 帧
    static let modeExperimentalSmart = 3
    static let modeCustom = 4

    /// 软件温控环路模式 id（存 CoolerState.softwareThermalMode）。
    static let thermalModeNone = 0
    static let thermalModeBattery = 100
    static let thermalModeCoolerTarget = 101

    // ------------------------------------------------------------ 上限与预设（§2，原版档案）

    static let maxColdLevel = 175
    static let maxWindLevel = 5700
    static let minWindLevel = 4000

    /// 智能二档：静音 id 0（target 6，wind 4000，cold 145，OC 0/0）。
    static let smartPresetSilent = (target: 6, wind: 4000, cold: 145, windOC: 0, coldOC: 0)
    /// 智能二档：极寒 id 2（target 0，wind 5500，cold 175，OC 0/0）。
    static let smartPresetExtreme = (target: 0, wind: 5500, cold: 175, windOC: 0, coldOC: 0)

    /// 手动三档：节能（cold 92，wind 4000，windOC 4000，coldOC 92）。
    static let manualPresetEco = (cold: 92, wind: 4000, windOC: 4000, coldOC: 92)
    /// 手动三档：强劲（cold 155，wind 4500，windOC 4500，coldOC 155）。
    static let manualPresetStrong = (cold: 155, wind: 4500, windOC: 4500, coldOC: 155)
    /// 手动三档：极强（cold 175，wind 4500，windOC 5700，coldOC 175）。
    static let manualPresetMax = (cold: 175, wind: 4500, windOC: 5700, coldOC: 175)

    /// 九点曲线温度点（固定）。
    static let curveTemperatures: [Int] = [-12, -9, -6, -3, 0, 3, 6, 9, 12]
    /// 九点曲线默认档位。
    static let defaultCurveLevels: [Int] = [5, 5, 5, 6, 7, 8, 8, 8, 8]

    // ------------------------------------------------------------ LED（§2）

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

    /// 各灯效模式的颜色数量（min/max）。THROB/RHYTHM 固定 8 色。
    static func ledColorCountRange(type: Int) -> (min: Int, max: Int) {
        switch type {
        case 11: return (1, 1) // ALWAYS_ON 常亮
        case 16: return (2, 3) // MULTI_ROTATION 多色旋转
        case 17, 19: return (8, 8) // THROB 跳动 / RHYTHM 律动
        case 20: return (1, 8) // CYBERPUNK 赛博朋克
        default: return (2, 8) // FLOW/BREATH/GRADIENT/CUTOVER/COLLISION 等
        }
    }

    /// UI 速度档（0 慢 / 1 中 / 2 快）→ 设备 speedRaw。
    /// CUTOVER/BREATH/MULTI_ROTATION 表 [3,5,8]（快→慢），GRADIENT [6,8,10]，
    /// COLLISION [8,5,3]，取表[2-uiSpeed]；无表模式取 [115,58,1][uiSpeed]。
    static func ledSpeedRaw(type: Int, uiSpeed: Int) -> Int {
        let speed = max(0, min(uiSpeed, 2))
        switch type {
        case 4, 5, 16: // CUTOVER / BREATH / MULTI_ROTATION
            return [3, 5, 8][2 - speed]
        case 6: // GRADIENT
            return [6, 8, 10][2 - speed]
        case 21: // COLLISION
            return [8, 5, 3][2 - speed]
        default:
            return [115, 58, 1][speed]
        }
    }

    // ------------------------------------------------------------ 命令帧

    static func setColdLevel(_ level: Int) -> Data {
        Data([0x12, UInt8(max(0, min(level, maxColdLevel)) & 0xFF)])
    }

    static func setSpeedLevel(_ level: Int) -> Data {
        Data([0x11, UInt8(level & 0xFF)])
    }

    static func lightOn() -> Data { Data([0x10, 0xFF]) }
    static func lightOff() -> Data { Data([0x10, 0x00]) }

    /// 0x13 轮询：单字节（v1 错发 [0x52,0x00]，那是读实验模式）。
    static func requestRealtimeState() -> Data { Data([0x13]) }

    /// 设置运行模式（0x20）。
    ///
    /// - 普通帧：`[0x20, mode, coldOC, windOC/100, windOC%100, target, cold, wind/100, 0]`，
    ///   第 9 字节固定发 0（原版 modeCustom；v1 错发 wind%100）。wind 只发百位。
    ///   mode 只取 0..3；mode 4 走曲线分支。target 钳到 0..255。
    /// - 曲线帧：`[0x20, 0x04, 9 个档位各 clamp 1..8]`（0x34 路径已删）。
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
            frame[1] = UInt8(modeCustom & 0xFF)
            let levels = customLevels ?? defaultCurveLevels
            for i in 0..<9 {
                let v = i < levels.count ? levels[i] : defaultCurveLevels[i]
                frame[2 + i] = UInt8(max(1, min(v, 8)) & 0xFF)
            }
            return frame
        }
        let m = max(0, min(mode, 3))
        let target = max(0, min(targetTemperature, 255))
        return Data([
            0x20,
            UInt8(m & 0xFF),
            UInt8(coldLevelOverclock & 0xFF),
            UInt8((windLevelOverclock / 100) & 0xFF),
            UInt8((windLevelOverclock % 100) & 0xFF),
            UInt8(target & 0xFF),
            UInt8(coldLevel & 0xFF),
            UInt8((windLevel / 100) & 0xFF),
            0,
        ])
    }

    static func requestRunModeParams(_ mode: Int) -> Data {
        Data([0x22, UInt8(mode & 0xFF)])
    }

    static func requestTempHistory() -> Data { Data([0x40, 0x00]) }

    static func requestMacAddress() -> Data { Data([0x24, 0x00]) }

    static func resetFlash() -> Data { Data([0xFF, 0x0A]) }

    static func handshake() -> Data { Data([0xA5, 0xA0, 0x00, 0x00]) }

    /// 0x21 快捷模式（v1 错用 0x57）。mode 只取 0/1/4。
    static func setQuickSwitchRunMode(_ mode: Int) -> Data {
        let m = (mode == 1 || mode == 4) ? mode : 0
        return Data([0x21, UInt8(m & 0xFF)])
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

    /// 定时关机（分钟制）：`[0x60, repeat, enabled, 分钟>>8, 分钟&0xFF]`。
    /// 关闭发 `[0x60, repeat, 0, 0, 0]`。
    static func setTimedShutdown(`repeat` repeatEnabled: Bool, enabled: Bool, minutes: Int) -> Data {
        let total = max(0, min(minutes, 0xFFFF))
        return Data([
            0x60,
            repeatEnabled ? 1 : 0,
            enabled ? 1 : 0,
            UInt8((total >> 8) & 0xFF),
            UInt8(total & 0xFF),
        ])
    }

    /// 读定时：`[0x61]` 单字节（v1 错发 `[0x61,0x00]`）。
    static func readTimedShutdown() -> Data { Data([0x61]) }

    /// 冻结模式：官方 `ctrlFreezeMode` → `26 01/00 00 00`。
    static func setFreezeMode(_ enabled: Bool) -> Data {
        Data([0x26, enabled ? 1 : 0, 0, 0])
    }

    /// 风开关（取反）：`[0x25, enabled ? 0 : 1]`。原版有；UI 暂不接线，备用。
    static func setWindEnabled(_ enabled: Bool) -> Data {
        Data([0x25, enabled ? 0 : 1])
    }

    /// 低温保护：只有低温保护，`[0x32, 0x00, enabled]`。
    /// 高温保护命令已删（原版无此命令；高温只是状态位）。
    static func setTempProtect(enabled: Bool) -> Data {
        Data([0x32, 0x00, enabled ? 1 : 0])
    }

    /// 设置灯效（20 字节分包 + 触发帧）。
    /// 颜色最多 8 个（超 4 色分 2 包）；亮度 clamp 0..100；
    /// byte[18] = mode==19 ? (colorful ? 2 : 1) : 0；
    /// byte[19] = checksum8 = 前 19 字节之和 mod 256。
    static func setLedColor(type: Int, period: Int = 0, colors: [Int] = [], light: Int = 0, colorful: Bool = false) -> [Data] {
        var packets: [Data] = []
        let total = min(colors.count, 8)
        let chunkCount = total > 4 ? 2 : 1
        let brightness = max(0, min(light, 100))
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
            frame[17] = UInt8(brightness & 0xFF)
            frame[18] = (type == 19) ? (colorful ? 2 : 1) : 0
            var sum = 0
            for i in 0..<19 { sum += Int(frame[i]) }
            frame[19] = UInt8(sum & 0xFF)
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
    /// flags：bit0 冷保护开关，bit1 满档运行，bit2 定时模式，bit3 定时运行中，
    /// bit4 高温保护生效，bit5 低温保护生效，bit6 倒计时按分钟，bit7 Freeze。
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
                coldProtection: (flags & 0x20) != 0,
                runningInMaxLevel: (flags & 0x02) != 0,
                timedShutdownMode: (flags >> 2) & 0x01,
                timedShutdownRunning: (flags & 0x08) != 0,
                hotProtectionEnabled: (flags & 0x10) != 0,
                coldProtectionEnabled: (flags & 0x01) != 0,
                timedCountdownInMinute: ((flags >> 6) & 0x01) != 0,
                freezeMode: ((flags >> 7) & 0x01) != 0,
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
            freezeMode: false,
            timeCountdown: 0
        )
    }

    private static func signed(_ b: UInt8) -> Int {
        let v = Int(b)
        return v > 127 ? v - 256 : v
    }
}
