import CoreBluetooth
import Foundation

/// 设备通道：飞智 / 红魔 / 黑鲨（DEEP-DIVE §1.1 `DeviceChannel`）。
/// 飞智是唯一有硬件实测的通道；红魔/黑鲨是脚手架，未验证、无硬件可测。
enum DeviceChannel: String, CaseIterable {
    case flydigi
    case redMagic
    case blackShark

    var displayName: String {
        switch self {
        case .flydigi: return "飞智"
        case .redMagic: return "红魔"
        case .blackShark: return "黑鲨"
        }
    }

    var isFlydigi: Bool { self == .flydigi }
    var isRedMagic: Bool { self == .redMagic }
    var isBlackShark: Bool { self == .blackShark }

    /// 该通道支持的制冷模式 id。
    /// 飞智：0 智能 / 1 手动 / 4 曲线（实测）；
    /// 红魔/黑鲨：未验证，暂按 0/1 占位。
    var supportedModes: [Int] {
        switch self {
        case .flydigi: return [B9XProtocol.modeSmart, B9XProtocol.modeManual, B9XProtocol.modeCustom]
        case .redMagic: return [0, 1]
        case .blackShark: return [0, 1]
        }
    }

    /// 曲线档位点数。飞智 9 点（实测）；红魔/黑鲨未验证，暂按 9 点占位。
    var levelCount: Int {
        switch self {
        case .flydigi: return 9
        case .redMagic: return 9
        case .blackShark: return 9
        }
    }

    /// 以下能力位按 DEEP-DIVE §1.1 的成员名补齐；非飞智均为未验证的保守值。
    var supportsPowerControl: Bool {
        switch self {
        case .flydigi: return true
        case .redMagic: return true
        case .blackShark: return true
        }
    }

    var supportsPowerTelemetry: Bool {
        switch self {
        case .flydigi: return true
        case .redMagic: return false
        case .blackShark: return false
        }
    }

    /// 软件目标温控环路（目标温度/电池温控）是否可用。
    /// 只有飞智走过实测环路；红魔/黑鲨未验证。
    var supportsSoftwareTarget: Bool {
        switch self {
        case .flydigi: return true
        case .redMagic: return false
        case .blackShark: return false
        }
    }

    /// 是否支持电池温度遥测。iOS 读不到电池温度，三通道均为 false。
    var supportsBatteryTemperature: Bool { false }

    /// 飞智扫描用的精确广播名（V2-SPEC §10.1：官方按名字精确匹配）。
    static let flydigiScanNames: [String] = [
        "Flydigi B9X",
        "Flydigi B8X",
        "Flydigi B7X",
        "Flydigi B6X",
    ]

    /// 按广播名映射通道。飞智用精确匹配；红魔/黑鲨的广播名未实测，
    /// 暂按常见前缀映射（未验证），匹配不到返回 nil。
    static func fromAdvertisedName(_ name: String) -> DeviceChannel? {
        if flydigiScanNames.contains(name) { return .flydigi }
        if name.hasPrefix("RedMagic") || name.hasPrefix("REDMAGIC") { return .redMagic }
        if name.hasPrefix("BlackShark") || name.hasPrefix("Black Shark")
            || name.hasPrefix("BR52") || name.hasPrefix("BR62") {
            return .blackShark
        }
        return nil
    }

    /// 按服务 UUID 映射通道（服务发现后二次确认）。
    static func fromServiceUUID(_ uuid: CBUUID) -> DeviceChannel? {
        if uuid.uuidString == Secrets.flydigiServiceUUID { return .flydigi }
        if Secrets.redMagicServiceUUIDs.contains(uuid.uuidString) { return .redMagic }
        if uuid.uuidString == Secrets.blackSharkServiceUUID
            || uuid.uuidString == Secrets.blackSharkServiceUUID2 {
            return .blackShark
        }
        return nil
    }
}
