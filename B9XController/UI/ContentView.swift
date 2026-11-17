import SwiftUI

/// 应用根视图：三个底栏 tab（首页 / 自动化 / 我的），选中态为液态玻璃胶囊高亮。
/// 内容底部留 104 点安全区，绝不被底栏遮住。
struct ContentView: View {
    @EnvironmentObject private var controller: CoolerController
    @ObservedObject private var appearance = AppearanceSettings.shared
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
            .padding(.bottom, 104)

            // 液态玻璃底栏：选中项套一层更亮的胶囊（对照原版截图）。
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button {
                        withAnimation(.easeInOut(duration: appearance.effectiveAnimationDuration)) {
                            tab = item
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon)
                                .font(.system(size: 20, weight: .semibold))
                            Text(item.title)
                                .font(.caption2)
                        }
                        .foregroundStyle(tab == item ? Color.b9xAccentLight : Color.b9xTextDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            tab == item
                                ? Color.b9xAccent.opacity(0.2 * appearance.buttonOpacity + 0.08)
                                : Color.clear
                        )
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(6)
            .tabBarGlass()
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            if showStartup {
                startupOverlay
                    .transition(.opacity)
            }
        }
        .onAppear {
            controller.bootstrap()
            if !appeared {
                appeared = true
                tab = Tab(rawValue: appearance.defaultTab) ?? .home
                if appearance.startupAnimationEnabled {
                    showStartup = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        withAnimation(.easeOut(duration: appearance.effectiveAnimationDuration)) {
                            showStartup = false
                        }
                    }
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
