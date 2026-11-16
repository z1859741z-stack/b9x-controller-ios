import SwiftUI

/// 应用根视图：三个底栏 tab（设备 / 联动 / 更多），选中态为液态玻璃胶囊高亮。
/// 对照原版底栏：设备（网格）/ 联动（人像）/ 更多（六边形）。
struct ContentView: View {
    @EnvironmentObject private var controller: CoolerController
    @AppStorage("glassEnabled") private var glassEnabled = true
    @AppStorage("defaultTab") private var defaultTab = "device"
    @State private var tab: Tab = .device
    @State private var appeared = false

    enum Tab: String, CaseIterable {
        case device, automation, more

        var title: String {
            switch self {
            case .device: return "设备"
            case .automation: return "联动"
            case .more: return "更多"
            }
        }

        var icon: String {
            switch self {
            case .device: return "square.grid.2x2"
            case .automation: return "person"
            case .more: return "hexagon"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.b9xBackground.ignoresSafeArea()

            Group {
                switch tab {
                case .device:
                    DeviceView(tab: $tab)
                case .automation:
                    AutomationView()
                case .more:
                    MoreView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 104)

            // 液态玻璃底栏：选中项套一层更亮的胶囊（对照原版截图）。
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button {
                        tab = item
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
                        .background(tab == item ? Color.white.opacity(0.12) : Color.clear)
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(6)
            .conditionalGlass(glassEnabled)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        // v2：删强制深色，全 App 跟随系统外观。
        .onAppear {
            controller.bootstrap()
            if !appeared {
                appeared = true
                tab = Tab(rawValue: defaultTab) ?? .device
            }
        }
    }
}
