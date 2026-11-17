import Foundation

/// 固件镜像种类（DEEP-DIVE §5.2：bundled / official / overclock / standard）。
enum FirmwareKind: String {
    case official
    case standard
    case overclock
    /// 用户自带镜像（暂未实现导入入口）。
    case data

    var displayName: String {
        switch self {
        case .official: return "官方固件"
        case .standard: return "标准固件"
        case .overclock: return "超频固件"
        case .data: return "自带固件"
        }
    }
}

/// 固件镜像（DEEP-DIVE §1.1 `FirmwareImage`）。
struct FirmwareImage: Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let kind: FirmwareKind
    /// 包内镜像的 Bundle 地址；自带镜像为 nil。
    let url: URL?
    let size: Int

    /// 包内自带的三个镜像（从原包 `Firmware/` 只读复制，未改动）。
    /// kind 映射按文件名推断（8.4.7 官方 / 8.5.2R5 标准 / 8.5.3R5 超频），
    /// 与 UI 桩 `FirmwareImageOption.bundled` 一致；该映射未验证。
    static let bundledFileNames: [(file: String, version: String, kind: FirmwareKind)] = [
        ("8.4.7.bin", "8.4.7", .official),
        ("8.5.2R5.bin", "8.5.2R5", .standard),
        ("8.5.3R5.bin", "8.5.3R5", .overclock),
    ]

    static func bundledImages() -> [FirmwareImage] {
        bundledFileNames.compactMap { entry in
            guard let url = Bundle.main.url(forResource: (entry.file as NSString).deletingPathExtension, withExtension: "bin") else {
                return nil
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return FirmwareImage(
                id: entry.file,
                name: "\(entry.version) \(entry.kind.displayName)",
                version: entry.version,
                kind: entry.kind,
                url: url,
                size: size
            )
        }
    }

    func loadData() -> Data? {
        guard let url = url else { return nil }
        return try? Data(contentsOf: url)
    }
}

/// 固件刷写阶段（DEEP-DIVE §1.1 `FirmwareStage`）。
enum FirmwareStage: Equatable {
    case idle
    case preparing
    case validating
    case transferring
    case submitting
    case deviceAccepted
    case transferred
    case waitingForDevice
    case failed(String)
    case cancelled

    var displayName: String {
        switch self {
        case .idle: return "未开始"
        case .preparing: return "准备中"
        case .validating: return "校验固件"
        case .transferring: return "传输中"
        case .submitting: return "提交固件"
        case .deviceAccepted: return "设备已接受"
        case .transferred: return "传输完成"
        case .waitingForDevice: return "等待设备重启"
        case .failed(let message): return "失败：\(message)"
        case .cancelled: return "已取消"
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
