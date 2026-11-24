import SwiftUI

/// 应用根视图：三个底栏 tab（首页 / 自动化 / 我的）。
/// 底栏用系统原生 iOS 26 TabView（Tab API）：系统液态玻璃 Tab 栏，
/// 比原来的自绘胶囊栏（401×69pt、浅蓝实色选中胶囊）更小、悬浮，
/// 没有自绘背板也没有不透明选中胶囊；选中着色用原来的选中蓝 #025FD6。
/// 底部安全区：系统 Tab 栏的自动 inset 在真机上没兜住最后一行，
/// 各页 ScrollView 用 .safeAreaPadding(.bottom, 80) 留够空间。
struct ContentView: View {
    @EnvironmentObject private var controller: CoolerController
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appearance = AppearanceSettings.shared
    @StateObject private var tour = TourDriver.shared
    @StateObject private var tapTest = TapTestDriver.shared
    @State private var tab: Tab = .home
    @State private var appeared = false
    @State private var showStartup = false

    enum Tab: String, CaseIterable {
        case home, automation, my

        var title: String {
            switch self {
            case .home: return "首页"
            case .automation: return "自动化"
            case .my: return "我的"
            }
        }

        var icon: String {
            switch self {
            case .home: return "house"
            case .automation: return "person"
            case .my: return "hexagon"
            }
        }
    }

    var body: some View {
        ZStack {
            // 注意：本文件里的 `Tab` 是上面的枚举，系统的 Tab 要写 SwiftUI.Tab。
            TabView(selection: $tab) {
                SwiftUI.Tab(Tab.home.title, systemImage: Tab.home.icon, value: Tab.home) {
                    HomeView(tab: $tab)
                        .background { backgroundLayer }
                }

                SwiftUI.Tab(Tab.automation.title, systemImage: Tab.automation.icon, value: Tab.automation) {
                    AutomationView()
                        .background { backgroundLayer }
                }

                SwiftUI.Tab(Tab.my.title, systemImage: Tab.my.icon, value: Tab.my) {
                    MoreView()
                        .background { backgroundLayer }
                }
            }
            .tint(Color.tabSelectionBlue)
            // 选中图标改回空心（对齐原版）：系统默认会给选中 tab 的图标加 .fill，
            // 这里关掉自动填充，选中和未选中都用描边图标。
            .environment(\.symbolVariants, .none)
            // 往下滑时 Tab 栏自动缩成小圆点（iOS 26 原生效果），给长页面腾空间。
            .tabBarMinimizeBehavior(.onScrollDown)

            if showStartup {
                startupOverlay
                    .transition(.opacity)
            }

            // 巡游角标（仅 CI 截图时显示）：截图上直接看到当前步数，
            // 步数不动就说明巡游没在跑。
            if tour.isTouring {
                VStack {
                    Text("巡游 \(tour.step)/\(TourDriver.lastStep)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.top, 54)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // 点按测试报告（仅 -UITapTest 启动时显示）：hitTest verdicts 写在屏上，
            // 截图就能看到。平时不显示，真机用户进不来；不拦点按。
            if TapTestDriver.isEnabled {
                VStack {
                    Text(tapTest.report)
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.leading)
                        .padding(12)
                        .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 60)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            controller.bootstrap()
            tour.start()
            tapTest.start()
            if !appeared {
                appeared = true
                tab = Tab(rawValue: appearance.defaultTab) ?? .home
                if appearance.startupAnimationEnabled && !tour.isTouring {
                    showStartup = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        withAnimation(.easeOut(duration: appearance.effectiveAnimationDuration)) {
                            showStartup = false
                        }
                    }
                }
            }
        }
        // 巡游（CI 截图）：按步骤切 tab（0–5 首页、6 自动化、7–8 我的、9 回首页）。
        .onChange(of: tour.step) { _, step in
            guard tour.isTouring else { return }
            withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.8)) {
                switch step {
                case 6: tab = .automation
                case 7, 8: tab = .my
                default: tab = .home
                }
            }
        }
        // 点按测试：把当前 tab 同步给 harness，校验点按后是否真的切过去了。
        .onChange(of: tab) { _, newValue in
            tapTest.currentTab = newValue.rawValue
        }
    }

    /// 页面背景：自定义背景图（有遮罩滑杆）或系统背景色。
    /// 自定义图优先；没图时浅色走很淡的蓝灰竖向渐变（顶部偏蓝灰、底部偏白，
    /// 对比克制，让玻璃在白底上也有折射感），深色跟随系统走深色。
    @ViewBuilder
    private var backgroundLayer: some View {
        if let image = appearance.backgroundImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .overlay(Color.black.opacity(appearance.mediaDimming))
        } else if colorScheme == .dark {
            Color.b9xBackground.ignoresSafeArea()
        } else {
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.95, blue: 0.98),
                    Color(red: 0.99, green: 0.99, blue: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    /// 开屏动画：白熊 logo + 应用名，短暂淡出（可在外观页关闭）。
    private var startupOverlay: some View {
        ZStack {
            Color.b9xBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                Image("BearLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                Text("引擎核心 Plus")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - 点按穿透测试驱动（CI 专用）

/// 点按穿透测试（仅启动参数含 -UITapTest 时激活，真机用户永远进不来）。
/// 底栏换成系统原生 TabView 后，没有自绘 tab 按钮可量了，改测系统 UITabBar：
/// 1. 在 keyWindow 里找到 UITabBar，报告它的 frame（核对“更小、悬浮”）；
/// 2. 把栏横向三等分，对每格中心做 window.hitTest，确认落点在 UITabBar
///    里面（✓），而不是穿透到下面的内容（✗）；
/// 3. 对照探针：“极寒”预设按钮（玻璃背板的 SwiftUI Button）的 hitTest 落点。
/// 不再模拟切 tab（系统 Tab 栏按钮是私有控件，sendActions 不可靠），
/// 真实点按切换需要真机确认。找不到 UITabBar 时只报告，不崩溃。
final class TapTestDriver: ObservableObject {
    static let shared = TapTestDriver()
    static var isEnabled: Bool { CommandLine.arguments.contains("-UITapTest") }

    /// 探针 frame（DeviceView 的预设按钮用 onGeometryChange 喂进来）。
    @Published var frames: [String: CGRect] = [:]
    /// 当前 tab（ContentView 用 onChange 喂进来）。
    @Published var currentTab: String = "home"
    /// verdicts，显示在屏上，截图可见。
    @Published var report: String = "点按测试：等待布局…"

    private var started = false

    func recordFrame(tab: String, frame: CGRect) {
        guard Self.isEnabled else { return }
        if frames[tab] != frame {
            frames[tab] = frame
        }
    }

    func start() {
        guard Self.isEnabled, !started else { return }
        started = true
        Task { [weak self] in
            // 等开屏动画消失（0.7s）+ 布局稳定，再测。
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await self?.execute()
        }
    }

    @MainActor
    private func execute() async {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })
        else {
            report = "点按测试：找不到 keyWindow"
            return
        }
        func findTabBar(in view: UIView) -> UITabBar? {
            if let bar = view as? UITabBar, !bar.isHidden { return bar }
            for sub in view.subviews {
                if let bar = findTabBar(in: sub) { return bar }
            }
            return nil
        }
        func isDescendant(_ view: UIView?, of ancestor: UIView) -> Bool {
            var node = view
            var depth = 0
            while let v = node, depth < 40 {
                if v === ancestor { return true }
                node = v.superview
                depth += 1
            }
            return false
        }
        var lines = ["点按测试（原生 TabView）", "屏宽 \(Int(window.bounds.width))pt"]
        guard let bar = findTabBar(in: window) else {
            lines.append("未找到 UITabBar")
            report = lines.joined(separator: "\n")
            return
        }
        let f = bar.convert(bar.bounds, to: nil)
        lines.append("UITabBar frame: (\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height)))")
        lines.append("items: \(bar.items?.count ?? 0)  选中: \(currentTab)")
        // 栏可能是整宽容器、玻璃胶囊在中间，取实际有子视图的范围。
        let visible = bar.subviews
            .filter { !$0.isHidden && $0.alpha > 0.01 && $0.bounds.width > 40 }
            .map { $0.convert($0.bounds, to: nil) }
            .reduce(CGRect.null) { $0.union($1) }
        let area = visible.isNull ? f : visible
        lines.append("可见范围: (\(Int(area.minX)),\(Int(area.minY)),\(Int(area.width))x\(Int(area.height)))")
        var marks = ""
        for i in 0..<3 {
            let p = CGPoint(x: area.minX + area.width * (CGFloat(i) + 0.5) / 3, y: area.midY)
            let hit = window.hitTest(p, with: nil)
            marks += isDescendant(hit, of: bar) ? "✓" : "✗(\(hit.map { String(describing: type(of: $0)) } ?? "nil"))"
        }
        lines.append("三格落点: \(marks)")
        if let pf = frames["preset-极寒"] {
            let hit = window.hitTest(CGPoint(x: pf.midX, y: pf.midY), with: nil)
            lines.append("对照 极寒: \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        } else {
            lines.append("对照 极寒: 无 frame")
        }
        report = lines.joined(separator: "\n")
    }
}
