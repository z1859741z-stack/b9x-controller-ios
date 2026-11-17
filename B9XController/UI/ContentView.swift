import SwiftUI

/// 应用根视图：三个底栏 tab（首页 / 自动化 / 我的），选中态为浅蓝胶囊高亮。
/// 原版截图实测（440pt @3x）：栏宽 401pt（占屏宽 91.2%）、左右边距各 19.3pt、
/// 栏高约 69pt、全胶囊、选中胶囊 127×61pt #D2DFFF、选中蓝 #025FD6、
/// 描边空心图标 22pt、文字 11pt、图标与文字间距 7.3pt（字形边沿间距）。
/// 底栏浮在内容之上，各 tab 的 ScrollView 底部留 100pt，绝不被底栏遮住。
struct ContentView: View {
    @EnvironmentObject private var controller: CoolerController
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

        /// 选中态也用描边空心图标（原版截图实测：选中房子是空心描边，
        /// 不是实心填充；上一轮误用 house.fill 已纠正）。选中与未选中
        /// 只差颜色（选中蓝 #025FD6，未选中灰）。
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            backgroundLayer

            Group {
                switch tab {
                case .home:
                    HomeView(tab: $tab)
                case .automation:
                    AutomationView()
                case .my:
                    MoreView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 底栏浮在内容之上（内容从底栏下滑过，玻璃才能透出后面的内容）：
            // 各 tab 自己的 ScrollView 底部已留 100pt，不会被底栏遮住。

            // 液态玻璃底栏（原版截图实测，440pt @3x）：
            // 栏宽 401pt（91.2%）、左右边距各 19.3pt、栏高约 69pt、全胶囊、
            // 底边距 16pt（相对安全区底边；34pt 安全区 + 16pt = 栏底离屏底 50pt，
            // 照原版全屏实测 49.3pt；fix1 的 ignoresSafeArea 把栏压低约 30pt，fix3 改回）；
            // 选中胶囊 127×60pt、浅蓝 #D2DFFF，
            // 选中图标/文字蓝 #025FD6，描边图标 20pt、文字 11pt。
            // 图标 20pt 是实测反推：原版房子字形 73×64px、人物 52×55px、
            // 六边形 59×67px，恰好是 22pt 的 20/22（0.91 倍），22pt 偏大 10%。
            // 胶囊在栏内偏上（上留白约 1pt、下留白约 7pt，照原版实测）。
            // 底栏专用液态玻璃（tabBarGlass），连接开关已改回重写版系统 Toggle，不共用。
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button {
                        withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.8)) {
                            tab = item
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon)
                                .font(.system(size: 20, weight: .semibold))
                            Text(item.title)
                                .font(.system(size: 11, weight: tab == item ? .semibold : .regular))
                        }
                        .foregroundStyle(tab == item ? Color.tabSelectionBlue : Color.b9xTextDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            tab == item ? Color.tabSelectionFill : Color.clear,
                            in: Capsule()
                        )
                        // 点按：Color.clear 背景不接点按，整格只有图标/文字那点能点，
                        // 其余空白点按穿透到底层。contentShape 把整格都变成点按区。
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 3.5)
                    .accessibilityIdentifier("tab.\(item.rawValue)")
                    // 点按测试用：记下每个 tab 按钮的全局 frame，harness 用它做 hitTest。
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                        tapTest.recordFrame(tab: item.rawValue, frame: frame)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 1)
            .padding(.bottom, 7)
            // 液态玻璃放背景层，不包按钮：.glassEffect 会在内容上方生成一个
            // UIPlatformGlassInteractionView，吃掉全部点按（三个 tab 全 MISS，
            // harness 实测）。玻璃放背景后，按钮在玻璃上方，点按直接落到按钮上；
            // 玻璃照样折射后面的内容，外观不变。
            .background(
                Capsule()
                    .fill(Color.clear)
                    .tabBarGlass()
            )
            .padding(.horizontal, 19.3)
            .padding(.bottom, 16)

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
                        .background(.ultraThinMaterial, in: Capsule())
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
        // 底栏定位：不伸进底部安全区，ZStack 底边就是安全区底边，
        // 栏底 = 安全区底边 + 16pt，离屏底 50pt（照原版实测）。
        // fix1 加的 ignoresSafeArea(edges: .bottom) 把栏底压到离屏底 20pt，
        // 比原版低约 30pt、几乎贴到 Home Indicator，fix3 删掉、改回重写版定位。
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
        // 巡游驱动（CI 截图）：TourDriver.start() 起 GCD 链，1.6 秒一步，
        // 各页面的 onChange(of: tour.step) 跟随切模式/tab。
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
        // 点按测试：把当前 tab 同步给 harness，校验 sendActions 后是否真的切过去了。
        .onChange(of: tab) { _, newValue in
            tapTest.currentTab = newValue.rawValue
        }
    }

    /// 页面背景：自定义背景图（有遮罩滑杆）或系统背景色。
    @ViewBuilder
    private var backgroundLayer: some View {
        if let image = appearance.backgroundImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .overlay(Color.black.opacity(appearance.mediaDimming))
        } else {
            Color.b9xBackground.ignoresSafeArea()
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

/// 点按穿透测试（仅启动参数含 -UITapTest 时激活，真机用户永远进不来）：
/// 测的是真实点按的落点。巡游是程序改 tab 状态，不走 hitTest，所以上轮
/// 没发现中间 tab 点按穿透到底层的问题。
/// 原理：UIKit 决定一次真实点按落到哪个 view，靠的就是 window.hitTest；
/// 这里直接对三个 tab 的中心点调 hitTest，再对命中的 UIControl 发
/// sendActions(.touchUpInside)，确认 tab 真的切过去了。两者合起来等价于
/// 一次真实点按（落点判定 + 控件动作）。XCTest 在这台 runner 上跑不起来
///（Xcode 26.6 解析不了 ui-testing 产品类型，fix1 已弃），所以用这个代替。
final class TapTestDriver: ObservableObject {
    static let shared = TapTestDriver()
    static var isEnabled: Bool { CommandLine.arguments.contains("-UITapTest") }

    /// 每个 tab 按钮的全局 frame（ContentView 用 onGeometryChange 喂进来）。
    @Published var frames: [String: CGRect] = [:]
    /// 当前 tab（ContentView 用 onChange 喂进来），校验切换用。
    @Published var currentTab: String = "home"
    /// verdicts，显示在屏上，截图可见。
    @Published var report: String = "点按测试：等待布局…"

    private var started = false

    func recordFrame(tab: String, frame: CGRect) {
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
        // 每格测 5 个点（中心/图标/文字/左/右），✓=落到该 tab 按钮上，✗=没落到。
        // 先点自动化、再点我的、最后回首页：每一步都是真切换。
        func hitControl(at point: CGPoint) -> (control: UIControl?, topClass: String) {
            let hit = window.hitTest(point, with: nil)
            var node: UIView? = hit
            var topClass = "nil"
            var depth = 0
            while let v = node, depth < 24 {
                if topClass == "nil" { topClass = String(describing: type(of: v)) }
                if let c = v as? UIControl { return (c, topClass) }
                node = v.superview
                depth += 1
            }
            return (nil, topClass)
        }
        func isTabButton(_ control: UIControl, key: String, frame: CGRect, point: CGPoint) -> Bool {
            let cFrame = control.convert(control.bounds, to: nil)
            return control.accessibilityIdentifier == "tab.\(key)"
                || (cFrame.contains(point)
                    && abs(cFrame.width - frame.width) < 20
                    && abs(cFrame.height - frame.height) < 20)
        }
        var lines = ["点按测试（hitTest + 动作）", "顺序: 中心/图标/文字/左/右"]
        for item in [ContentView.Tab.automation, ContentView.Tab.my, ContentView.Tab.home] {
            let key = item.rawValue
            guard let frame = frames[key] else {
                lines.append("\(item.title)：无 frame")
                report = lines.joined(separator: "\n")
                continue
            }
            let points: [CGPoint] = [
                CGPoint(x: frame.midX, y: frame.midY),          // 中心
                CGPoint(x: frame.midX, y: frame.minY + 22),     // 图标
                CGPoint(x: frame.midX, y: frame.maxY - 20),     // 文字
                CGPoint(x: frame.minX + 8, y: frame.midY),      // 左
                CGPoint(x: frame.maxX - 8, y: frame.midY),      // 右
            ]
            var marks = ""
            var centerControl: UIControl? = nil
            var centerTopClass = "nil"
            for (i, point) in points.enumerated() {
                let (control, topClass) = hitControl(at: point)
                let hit = control.map { isTabButton($0, key: key, frame: frame, point: point) } ?? false
                marks += hit ? "✓" : "✗"
                if i == 0 {
                    centerControl = hit ? control : nil
                    centerTopClass = topClass
                }
            }
            if let control = centerControl {
                control.sendActions(for: .touchUpInside)
                try? await Task.sleep(nanoseconds: 600_000_000)
                let switched = (currentTab == key)
                lines.append("\(item.title)：\(marks) 切换\(switched ? "✓" : "✗")")
            } else {
                lines.append("\(item.title)：\(marks) 中心->\(centerTopClass)")
            }
            report = lines.joined(separator: "\n")
        }
        // 附 frame（核对用）：自动化那格的全局 frame。
        if let f = frames["automation"] {
            report += "\n自动化 frame: (\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.size.width))x\(Int(f.size.height)))"
        }
        // 对照：探“极寒”预设按钮（用户确认能点按的 SwiftUI Button）。
        // 若它也 MISS（命中容器），说明 UIKit hitTest 根本看不见 SwiftUI 按钮，
        // harness 的 MISS 是假阴性，不能当成“按钮坏了”的证据。
        if let f = frames["preset-极寒"] {
            let center = CGPoint(x: f.midX, y: f.midY)
            let (control, topClass) = hitControl(at: center)
            if let control {
                report += "\n对照 极寒: HIT \(type(of: control))"
            } else {
                report += "\n对照 极寒: MISS -> \(topClass)"
            }
        } else {
            report += "\n对照 极寒: 无 frame"
        }
    }
}
