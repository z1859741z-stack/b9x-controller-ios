import Combine
import SwiftUI
import UIKit

/// 卡片材质三档（对照原版 AppearanceView 的 CardMaterial）：
/// 液态玻璃（iOS 26 .glassEffect）/ 磨砂模糊（.ultraThinMaterial）/ 普通（纯色卡片）。
enum CardMaterial: String, CaseIterable, Codable {
    case glass
    case frosted
    case plain

    var title: String {
        switch self {
        case .glass: return "液态玻璃"
        case .frosted: return "磨砂模糊"
        case .plain: return "普通"
        }
    }

    var subtitle: String {
        switch self {
        case .glass: return "iOS 26 液态玻璃效果"
        case .frosted: return "系统磨砂材质"
        case .plain: return "纯色卡片，无材质"
        }
    }
}

/// 首页可自选的 13 项参数（对照原版 HomeMetricPreferences / parameter.*）。
/// 功率与供电读数：设备帧里没有这两个量，UI 显示 "—"，不编造数值。
enum HomeMetric: String, CaseIterable, Codable, Identifiable {
    case coldPlate
    case hotSurface
    case rpm
    case power
    case coolingOutput
    case fanOutput
    case level
    case mode
    case targetTemp
    case battery
    case remaining
    case supply
    case targetControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coldPlate: return "冷板温度"
        case .hotSurface: return "热面温度"
        case .rpm: return "转速"
        case .power: return "功率"
        case .coolingOutput: return "制冷输出"
        case .fanOutput: return "风扇输出"
        case .level: return "当前档位"
        case .mode: return "当前模式"
        case .targetTemp: return "目标温度"
        case .battery: return "手机电量"
        case .remaining: return "剩余时间"
        case .supply: return "供电读数"
        case .targetControl: return "目标温控"
        }
    }

    /// 设备未上报、只能显示 "—" 的项。
    var isUnavailable: Bool {
        switch self {
        case .power, .supply: return true
        default: return false
        }
    }

    var unavailableNote: String? {
        switch self {
        case .power: return "设备未上报功率"
        case .supply: return "设备未上报供电读数"
        default: return nil
        }
    }
}

/// 语言：仅简体中文（对照原版 LanguageView 的“跟随系统”，但本 App 只有中文文案）。
enum AppLanguage: String, CaseIterable {
    case system
    case zhHans = "zh-Hans"

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .zhHans: return "简体中文"
        }
    }
}

/// 外观与主页偏好：@AppStorage 键与旧版保持一致（glassEnabled / animationsEnabled /
/// defaultTab / notifyOnDisconnect），老用户升级后设置不丢。
/// 用 @Published + UserDefaults 手动同步（@AppStorage 在 ObservableObject 里不触发刷新）。
final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()

    private enum Key {
        static let cardMaterial = "appearance.cardMaterial"
        static let cardOpacity = "appearance.cardOpacity"
        static let buttonOpacity = "appearance.buttonOpacity"
        static let animationDuration = "appearance.animationDuration"
        static let animationsEnabled = "animationsEnabled"
        static let startupAnimationEnabled = "appearance.startupAnimationEnabled"
        static let glassEnabled = "glassEnabled"
        static let defaultTab = "defaultTab"
        static let language = "appearance.language"
        static let mediaDimming = "appearance.mediaDimming"
        static let hasCustomBackground = "appearance.hasCustomBackground"
        static let checkUpdateOnLaunch = "appearance.checkUpdateOnLaunch"
        static let liveActivityEnabled = "liveActivityEnabled"
        static let primaryMetric = "home.primaryMetric"
        static let secondaryMetric = "home.secondaryMetric"
        static let visibleMetrics = "home.visibleMetrics"
    }

    private let defaults = UserDefaults.standard

    @Published var cardMaterial: CardMaterial {
        didSet { defaults.set(cardMaterial.rawValue, forKey: Key.cardMaterial) }
    }
    @Published var cardOpacity: Double {
        didSet { defaults.set(cardOpacity, forKey: Key.cardOpacity) }
    }
    @Published var buttonOpacity: Double {
        didSet { defaults.set(buttonOpacity, forKey: Key.buttonOpacity) }
    }
    @Published var animationDuration: Double {
        didSet { defaults.set(animationDuration, forKey: Key.animationDuration) }
    }
    @Published var animationsEnabled: Bool {
        didSet { defaults.set(animationsEnabled, forKey: Key.animationsEnabled) }
    }
    @Published var startupAnimationEnabled: Bool {
        didSet { defaults.set(startupAnimationEnabled, forKey: Key.startupAnimationEnabled) }
    }
    /// 液态玻璃总开关（旧键 glassEnabled）：关掉后全 App 用磨砂材质。
    @Published var glassEnabled: Bool {
        didSet { defaults.set(glassEnabled, forKey: Key.glassEnabled) }
    }
    /// 打开时默认页面：home / automation / my（旧值 device→home、more→my 自动迁移）。
    @Published var defaultTab: String {
        didSet { defaults.set(defaultTab, forKey: Key.defaultTab) }
    }
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }
    @Published var mediaDimming: Double {
        didSet { defaults.set(mediaDimming, forKey: Key.mediaDimming) }
    }
    @Published var hasCustomBackground: Bool {
        didSet { defaults.set(hasCustomBackground, forKey: Key.hasCustomBackground) }
    }
    @Published var checkUpdateOnLaunch: Bool {
        didSet { defaults.set(checkUpdateOnLaunch, forKey: Key.checkUpdateOnLaunch) }
    }
    @Published var liveActivityEnabled: Bool {
        didSet { defaults.set(liveActivityEnabled, forKey: Key.liveActivityEnabled) }
    }
    @Published var primaryMetric: HomeMetric {
        didSet { defaults.set(primaryMetric.rawValue, forKey: Key.primaryMetric) }
    }
    @Published var secondaryMetric: HomeMetric {
        didSet { defaults.set(secondaryMetric.rawValue, forKey: Key.secondaryMetric) }
    }
    @Published private(set) var visibleMetrics: [HomeMetric] {
        didSet { saveVisibleMetrics() }
    }
    /// 自定义背景图（缓存在内存，文件在 Application Support 目录）。
    @Published private(set) var backgroundImage: UIImage?

    /// 动画关闭时动画时长按 0 算。
    var effectiveAnimationDuration: Double {
        animationsEnabled ? animationDuration : 0
    }

    /// 实际生效的卡片材质：玻璃总开关关掉，或选了非玻璃档，就不用液态玻璃。
    var effectiveMaterial: CardMaterial {
        glassEnabled ? cardMaterial : .frosted
    }

    init() {
        let materialRaw = defaults.string(forKey: Key.cardMaterial) ?? CardMaterial.glass.rawValue
        cardMaterial = CardMaterial(rawValue: materialRaw) ?? .glass
        cardOpacity = defaults.object(forKey: Key.cardOpacity) as? Double ?? 0.9
        buttonOpacity = defaults.object(forKey: Key.buttonOpacity) as? Double ?? 0.9
        animationDuration = defaults.object(forKey: Key.animationDuration) as? Double ?? 0.3
        animationsEnabled = defaults.object(forKey: Key.animationsEnabled) as? Bool ?? true
        startupAnimationEnabled = defaults.object(forKey: Key.startupAnimationEnabled) as? Bool ?? true
        glassEnabled = defaults.object(forKey: Key.glassEnabled) as? Bool ?? true
        let storedTab = defaults.string(forKey: Key.defaultTab) ?? "home"
        switch storedTab {
        case "device": defaultTab = "home"
        case "more": defaultTab = "my"
        case "home", "automation", "my": defaultTab = storedTab
        default: defaultTab = "home"
        }
        let languageRaw = defaults.string(forKey: Key.language) ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: languageRaw) ?? .system
        mediaDimming = defaults.object(forKey: Key.mediaDimming) as? Double ?? 0.3
        hasCustomBackground = defaults.object(forKey: Key.hasCustomBackground) as? Bool ?? false
        checkUpdateOnLaunch = defaults.object(forKey: Key.checkUpdateOnLaunch) as? Bool ?? true
        liveActivityEnabled = defaults.object(forKey: Key.liveActivityEnabled) as? Bool ?? false
        let primaryRaw = defaults.string(forKey: Key.primaryMetric) ?? HomeMetric.coldPlate.rawValue
        primaryMetric = HomeMetric(rawValue: primaryRaw) ?? .coldPlate
        let secondaryRaw = defaults.string(forKey: Key.secondaryMetric) ?? HomeMetric.rpm.rawValue
        secondaryMetric = HomeMetric(rawValue: secondaryRaw) ?? .rpm
        if let data = defaults.data(forKey: Key.visibleMetrics),
           let decoded = try? JSONDecoder().decode([HomeMetric].self, from: data),
           !decoded.isEmpty {
            visibleMetrics = decoded
        } else {
            visibleMetrics = [.coldPlate, .hotSurface, .rpm, .coolingOutput, .fanOutput, .battery, .mode, .targetTemp]
        }
        backgroundImage = Self.loadBackgroundImageFromDisk()
        if backgroundImage == nil {
            hasCustomBackground = false
        }
    }

    private func saveVisibleMetrics() {
        if let data = try? JSONEncoder().encode(visibleMetrics) {
            defaults.set(data, forKey: Key.visibleMetrics)
        }
    }

    func setMetricVisible(_ metric: HomeMetric, _ visible: Bool) {
        if visible {
            if !visibleMetrics.contains(metric) {
                visibleMetrics.append(metric)
                visibleMetrics.sort { HomeMetric.allCases.firstIndex(of: $0)! < HomeMetric.allCases.firstIndex(of: $1)! }
            }
        } else {
            // 至少留一项，避免参数格全空。
            guard visibleMetrics.count > 1 else { return }
            visibleMetrics.removeAll { $0 == metric }
        }
    }

    func isMetricVisible(_ metric: HomeMetric) -> Bool {
        visibleMetrics.contains(metric)
    }

    // ------------------------------------------------------------ 自定义背景图

    private static var backgroundFileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("custom-background.jpg")
    }

    private static func loadBackgroundImageFromDisk() -> UIImage? {
        guard let url = backgroundFileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 存入自定义背景图（JPEG 压缩到合理大小，单个文件不做 32MB 上限校验，由 PhotosPicker 选图决定）。
    @discardableResult
    func saveBackgroundImage(_ image: UIImage) -> Bool {
        guard let url = Self.backgroundFileURL,
              let data = image.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            backgroundImage = UIImage(data: data)
            hasCustomBackground = true
            return true
        } catch {
            return false
        }
    }

    func clearBackgroundImage() {
        if let url = Self.backgroundFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        backgroundImage = nil
        hasCustomBackground = false
    }
}

/// App 版本信息（Bundle 里读，读不到时回退到写死的当前版本）。
enum AppInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.8.143"
        let build = info?["CFBundleVersion"] as? String ?? "227"
        return "\(version)（\(build)）"
    }

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.8.143"
    }

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.enginecore.plus"
    }
}
