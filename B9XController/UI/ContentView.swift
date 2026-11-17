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
            // 底边距 20pt；选中胶囊 127×61pt、浅蓝 #D2DFFF，
            // 选中图标/文字蓝 #025FD6，描边图标 22pt，文字 11pt。
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
                                .font(.system(size: 22, weight: .semibold))
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
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 3.5)
                    .accessibilityIdentifier("tab.\(item.rawValue)")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 1)
            .padding(.bottom, 7)
            .tabBarGlass()
            .padding(.horizontal, 19.3)
            .padding(.bottom, 20)

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
        }
        // 底栏贴到离屏底 20pt，须伸进底部安全区。
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            controller.bootstrap()
            tour.start()
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
