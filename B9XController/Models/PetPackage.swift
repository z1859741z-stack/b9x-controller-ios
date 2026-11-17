import Foundation
import UIKit

/// 桌宠包（ZIP）解析与播放器。
///
/// 包格式（本 App 的约定；与原包的“冰环X桌宠包格式”同思路）：
///  - `manifest.json`：清单（见 `PetManifest`）。
///  - 若干 PNG 帧图，由清单里的动画引用（路径相对包根）。
///  - 帧图缺失、清单非法、包过大或动作帧超限都会拒绝并给人话错误。
///
/// 安全上限（防异常包撑爆内存）：
///  - 包 ≤ 32MB；动作帧总数 ≤ 300；单帧图边长 ≤ 1024px；帧缓存 ≤ 64 张。

// ------------------------------------------------------------ 清单

struct PetManifest: Codable, Equatable {
    var name: String
    var version: String
    var scale: Double
    var defaultAnimation: String
    var animations: [String: [String]]
    var controlKeys: [String]
    var metricKeys: [String]

    enum CodingKeys: String, CodingKey {
        case name, version, scale, defaultAnimation, animations, controlKeys, metricKeys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "桌宠"
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        defaultAnimation = try c.decodeIfPresent(String.self, forKey: .defaultAnimation) ?? "idle"
        animations = try c.decodeIfPresent([String: [String]].self, forKey: .animations) ?? [:]
        controlKeys = try c.decodeIfPresent([String].self, forKey: .controlKeys) ?? PetManifest.defaultControlKeys
        metricKeys = try c.decodeIfPresent([String].self, forKey: .metricKeys) ?? []
    }

    init(
        name: String, version: String = "1.0", scale: Double = 1.0,
        defaultAnimation: String = "idle", animations: [String: [String]] = [:],
        controlKeys: [String] = PetManifest.defaultControlKeys, metricKeys: [String] = []
    ) {
        self.name = name
        self.version = version
        self.scale = scale
        self.defaultAnimation = defaultAnimation
        self.animations = animations
        self.controlKeys = controlKeys
        self.metricKeys = metricKeys
    }

    static let defaultControlKeys = ["power", "light", "mode", "connect"]

    /// 显示参数的可选项（与原包 petMetricKeys 对应）。
    static let availableMetricKeys: [(key: String, name: String)] = [
        ("coldPlate", "冷板温度"),
        ("rpm", "转速"),
        ("power", "功率"),
        ("mode", "当前模式"),
        ("firmware", "固件版本"),
    ]

    /// 控制键的可选项（面板上的按钮）。
    static let availableControlKeys: [(key: String, name: String)] = [
        ("power", "电源"),
        ("light", "灯光"),
        ("mode", "模式"),
        ("connect", "连接"),
    ]

    var totalFrames: Int {
        animations.values.reduce(0) { $0 + $1.count }
    }

    var animationNames: [String] {
        animations.keys.sorted()
    }
}

// ------------------------------------------------------------ 桌宠包

enum PetPackageError: LocalizedError {
    case packageTooLarge(Int64)
    case tooManyFrames(Int)
    case missingManifest
    case invalidManifest(String)
    case missingFrame(animation: String, path: String)
    case frameTooLarge(String)
    case invalidImage(String)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .packageTooLarge(let bytes):
            return "桌宠包太大了（\(bytes / 1024 / 1024)MB），上限 32MB，换个小一点的包再试。"
        case .tooManyFrames(let count):
            return "这个包的动作帧太多了（\(count) 帧），上限 300 帧，换个小一点的包再试。"
        case .missingManifest:
            return "包里找不到 manifest.json，这不是一个有效的桌宠包。"
        case .invalidManifest(let detail):
            return "桌宠包的清单写错了：\(detail)"
        case .missingFrame(let animation, let path):
            return "动画“\(animation)”里引用的图片“\(path)”在包里找不到。"
        case .frameTooLarge(let path):
            return "图片“\(path)”太大了（边长超过 1024px），换张小图再打包。"
        case .invalidImage(let path):
            return "图片“\(path)”打不开，可能不是有效的 PNG/JPEG。"
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}

struct PetPackage {
    static let maxPackageBytes: Int64 = 32 * 1024 * 1024
    static let maxTotalFrames = 300
    static let maxFrameDimension: CGFloat = 1024

    let manifest: PetManifest
    /// 帧图原始数据（路径 → 数据），解包时一次读出；图片按需解码进缓存。
    let frameData: [String: Data]
    let fileName: String

    /// 从 ZIP 数据加载并校验一个桌宠包。
    static func load(data: Data, fileName: String) throws -> PetPackage {
        guard Int64(data.count) <= maxPackageBytes else {
            throw PetPackageError.packageTooLarge(Int64(data.count))
        }
        let archive: ZipArchive
        do {
            archive = try ZipArchive(data: data)
        } catch {
            throw PetPackageError.underlying(error)
        }
        guard archive.contains("manifest.json") else {
            throw PetPackageError.missingManifest
        }
        let manifestData: Data
        do {
            manifestData = try archive.read(named: "manifest.json")
        } catch {
            throw PetPackageError.underlying(error)
        }
        let manifest: PetManifest
        do {
            manifest = try JSONDecoder().decode(PetManifest.self, from: manifestData)
        } catch {
            throw PetPackageError.invalidManifest(error.localizedDescription)
        }
        guard manifest.totalFrames <= maxTotalFrames else {
            throw PetPackageError.tooManyFrames(manifest.totalFrames)
        }
        guard !manifest.animations.isEmpty else {
            throw PetPackageError.invalidManifest("清单里没有任何动画。")
        }
        // 逐帧校验存在性，并把图片读出来（只读清单引用的图，不读无关文件）。
        var frameData: [String: Data] = [:]
        for (animation, paths) in manifest.animations {
            for path in paths {
                if frameData[path] != nil { continue }
                guard let entry = archive.entry(named: path), !entry.isDirectory else {
                    throw PetPackageError.missingFrame(animation: animation, path: path)
                }
                let bytes: Data
                do {
                    bytes = try archive.read(entry)
                } catch {
                    throw PetPackageError.underlying(error)
                }
                guard let image = UIImage(data: bytes) else {
                    throw PetPackageError.invalidImage(path)
                }
                if image.size.width > maxFrameDimension || image.size.height > maxFrameDimension {
                    throw PetPackageError.frameTooLarge(path)
                }
                frameData[path] = bytes
            }
        }
        return PetPackage(manifest: manifest, frameData: frameData, fileName: fileName)
    }
}

// ------------------------------------------------------------ 帧缓存

/// 帧图片缓存：按需解码，最多留 64 张，超了先清最旧的。
final class PetFrameCache {
    private var cache: [String: UIImage] = [:]
    private var order: [String] = []
    private let capacity = 64

    func image(for path: String, data: Data) -> UIImage? {
        if let cached = cache[path] { return cached }
        guard let image = UIImage(data: data) else { return nil }
        if order.count >= capacity, let oldest = order.first {
            cache.removeValue(forKey: oldest)
            order.removeFirst()
        }
        cache[path] = image
        order.append(path)
        return image
    }

    func clear() {
        cache.removeAll()
        order.removeAll()
    }
}

// ------------------------------------------------------------ 播放器

/// 桌宠播放器：持有当前包，按动画名循环播帧（约 12fps）。
/// 离开页面/关闭桌宠时调用 `stop()`，定时器立即停，不留后台开销。
@MainActor
final class PetPlayer: ObservableObject {
    @Published private(set) var package: PetPackage?
    @Published private(set) var currentImage: UIImage?
    @Published private(set) var currentAnimation: String = "idle"
    @Published private(set) var isPlaying = false

    private let cache = PetFrameCache()
    private var timer: Timer?
    private var frameIndex = 0

    var packageName: String { package?.manifest.name ?? "未导入桌宠" }

    var animationNames: [String] {
        package?.manifest.animationNames ?? []
    }

    func load(package: PetPackage) {
        stop()
        cache.clear()
        self.package = package
        currentAnimation = package.manifest.animations[package.manifest.defaultAnimation] != nil
            ? package.manifest.defaultAnimation
            : (package.manifest.animationNames.first ?? "idle")
        play(animation: currentAnimation)
    }

    func unload() {
        stop()
        cache.clear()
        package = nil
        currentImage = nil
    }

    func play(animation name: String) {
        guard let package, package.manifest.animations[name] != nil else { return }
        currentAnimation = name
        frameIndex = 0
        showCurrentFrame()
        guard !isPlaying else { return }
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advanceFrame() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    private func advanceFrame() {
        guard let package, let frames = package.manifest.animations[currentAnimation], !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        showCurrentFrame()
    }

    private func showCurrentFrame() {
        guard let package, let frames = package.manifest.animations[currentAnimation], !frames.isEmpty else {
            currentImage = nil
            return
        }
        let path = frames[frameIndex % frames.count]
        if let data = package.frameData[path] {
            currentImage = cache.image(for: path, data: data)
        } else {
            currentImage = nil
        }
    }
}

// ------------------------------------------------------------ 桌宠设置（UserDefaults 持久化）

struct PetSettings: Codable, Equatable {
    var enabled: Bool = false
    var scale: Double = 1.0
    /// 面板上显示哪些指标（coldPlate/rpm/power/mode/firmware）。
    var visibleMetrics: [String] = ["coldPlate", "rpm", "mode"]
    /// 面板上显示哪些控制键。
    var visibleControls: [String] = PetManifest.defaultControlKeys
    /// 当前导入的包文件名（包本身存在内存/沙盒，不随设置备份走）。
    var packageName: String? = nil
    /// 桌宠在屏幕上的相对位置（0...1，相对父视图宽高）。
    var positionX: Double = 0.5
    var positionY: Double = 0.75

    static let defaultsKey = "enginecore.petSettings.v1"

    static func load() -> PetSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(PetSettings.self, from: data) else {
            return PetSettings()
        }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
