import SwiftUI

/// “我的”/ 设置页（对照原版 MyView / SettingsView）：
/// 顶部应用卡 + 关于作者 / 开源与许可 / 用户协议与免责声明 + 系统信息 +
/// 外观 / 语言 / 媒体背景 / 通知与实时活动 / 备份恢复 + 设备与连接 + 数据与高级。
/// 注意：原版设置页里的“特别鸣谢”行这里根本没有（重写不建那一行）；
/// “抖音主页、支持作者”也只在原版 AuthorView 里有，这里不建。
struct MoreView: View {
    @EnvironmentObject private var controller: CoolerController
    @Environment(\.openURL) private var openURL
    @ObservedObject private var appearance = AppearanceSettings.shared
    @StateObject private var tour = TourDriver.shared
    @State private var showUpdateAlert = false
    @State private var updateMessage = ""
    @State private var updateURL: URL?
    /// 巡游（CI 截图）第 8 步自动打开法律页用。
    @State private var showLegal = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    appCard
                    aboutCard
                    settingsCard
                    deviceCard
                    dataCard
                    demoCard
                    // 巡游（CI 截图）专用隐藏入口：第 8 步自动打开法律页。
                    NavigationLink(destination: LegalDocumentView(readOnly: true), isActive: $showLegal) {
                        EmptyView()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                // 底部留白 80pt：浮动 Tab 栏约 62pt + 底部安全区 34pt，真机实测 24pt 不够、最后一行会被栏压住；留 80pt 让最后一行能完全滑出栏上方。
                .safeAreaPadding(.bottom, 80)
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            // 巡游（CI 截图）：第 8 步进法律页，第 9 步退回。
            // onAppear 也补一次：固定步数启动时 MoreView 是在 tab 切过来后
            // 才挂载的，挂载时 step 已是 8，onChange 收不到变化。
            .onChange(of: tour.step) { _, step in
                guard tour.isTouring else { return }
                if step == 8 { showLegal = true }
                if step == 9 { showLegal = false }
            }
            .onAppear {
                if tour.isTouring && tour.step == 8 { showLegal = true }
            }
        }
        .alert("检查更新", isPresented: $showUpdateAlert) {
            if let url = updateURL {
                Button("前往查看") {
                    openURL(url)
                    showUpdateAlert = false
                }
            }
            Button("好", role: .cancel) { showUpdateAlert = false }
        } message: {
            Text(updateMessage)
        }
    }

    // ------------------------------------------------------------ 应用卡

    private var appCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                Image("BearLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                Text("引擎核心 Plus")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Text("版本 \(AppInfo.versionString)")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                Divider()
                Button {
                    Task {
                        if let info = await controller.checkForUpdate() {
                            updateMessage = "发现新版 \(info.version)\n\(info.notes)"
                            updateURL = info.url
                        } else {
                            updateMessage = "已是最新版本。"
                            updateURL = nil
                        }
                        showUpdateAlert = true
                    }
                } label: {
                    HStack {
                        Text("检查更新")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(AppInfo.shortVersion)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(Color.b9xTextDim)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                }
                .buttonStyle(.plain)
                Toggle("启动时检查更新", isOn: $appearance.checkUpdateOnLaunch)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
    }

    // ------------------------------------------------------------ 关于区

    private var aboutCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                menuRow("关于作者", "引擎核心 Plus 团队") {
                    AuthorView()
                }
                Divider()
                menuRow("开源与许可", "代码与框架来源") {
                    LicensesView()
                }
                Divider()
                menuRow("用户协议与免责声明", "33 条 · 可重新阅读") {
                    LegalDocumentView(readOnly: true)
                }
            }
        }
    }

    // ------------------------------------------------------------ 设置区

    private var settingsCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                menuRow("系统信息", "软件版本 · 系统版本 · 最低支持 iOS 17.0") {
                    SystemInfoView()
                }
                Divider()
                menuRow("外观", "液态玻璃 · 透明度 · 动画 · 默认页面") {
                    AppearanceView()
                }
                Divider()
                menuRow("语言", appearance.language.title) {
                    LanguageView()
                }
                Divider()
                menuRow("媒体背景", appearance.hasCustomBackground ? "已设置背景图" : "选图 · 遮罩") {
                    MediaBackgroundView()
                }
                Divider()
                menuRow("通知与实时活动", "断连通知 · 锁屏实时活动") {
                    NotificationSettingsView()
                }
                Divider()
                menuRow("备份恢复", "设置 JSON 导出 / 导入") {
                    BackupRestoreView()
                }
            }
        }
    }

    // ------------------------------------------------------------ 设备与数据

    private var deviceCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                menuRow("设备与连接", connectionSubtitle) {
                    ConnectView()
                }
            }
        }
    }

    private var dataCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                menuRow("数据与高级", "刷新 · 运行日志 · 诊断") {
                    DataAdvancedView()
                }
            }
        }
    }

    private var connectionSubtitle: String {
        if controller.demoMode { return "演示中" }
        switch controller.connection {
        case .connected: return "已连接 \(controller.state.deviceName)"
        case .connecting: return "正在连接…"
        case .scanning: return "扫描中…"
        default: return "未连接"
        }
    }

    private func menuRow<Destination: View>(
        _ title: String,
        _ subtitle: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.b9xTextDim)
            }
            .padding(.vertical, 12)
        }
    }

    private var demoCard: some View {
        GlassCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("宣传演示模式")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("用于截图/录屏宣传；模拟真实设备状态，不扫描、不连接、也不会向散热器发送蓝牙指令。")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { controller.demoMode },
                    set: { $0 ? controller.enterDemo() : controller.exitDemo() }
                ))
                .labelsHidden()
            }
        }
    }
}

// ------------------------------------------------------------ 数据与高级
// 运行日志 + 诊断 + 重新读取设备状态。备份导出/导入已搬到 BackupRestoreView。

struct DataAdvancedView: View {
    @EnvironmentObject private var controller: CoolerController

    private var state: CoolerState { controller.state }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("运行日志")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            if controller.logs.isEmpty {
                                Text("暂无记录。")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.b9xTextDim)
                            } else {
                                ForEach(controller.logs.suffix(50)) { entry in
                                    Text("\(entry.timeString)  \(entry.message)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("诊断")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            infoRow("蓝牙状态", controller.ble.bluetoothState)
                            infoRow("蓝牙后台模式", "bluetooth-central 已配置")
                            infoRow("断线自动重连", controller.ble.autoReconnectEnabled ? "开启" : "关闭")
                            infoRow("连接状态", controller.connection.rawValue)
                            infoRow("上次设备", controller.ble.hasLastDevice() ? "已记录" : "无")
                            infoRow("固件版本", state.firmwareVersion.isEmpty ? "—" : state.firmwareVersion)
                            infoRow("MAC 地址", state.mac.isEmpty ? "—" : state.mac)
                            infoRow("手机热状态", controller.phoneThermal.rawValue)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .navigationTitle("数据与高级")
            .navigationBarTitleDisplayMode(.inline)
            // “重新读取设备状态”放进 toolbar，不再被导航栏遮住。
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重新读取设备状态") {
                        controller.refreshState()
                    }
                    .font(.subheadline)
                }
            }
            .onAppear {
                controller.refreshState()
                scrollLogToBottom(proxy)
            }
            .onChange(of: controller.logs.count) { _, _ in
                scrollLogToBottom(proxy)
            }
        }
    }

    /// 新日志自动滚动到底部。
    private func scrollLogToBottom(_ proxy: ScrollViewProxy) {
        guard let last = controller.logs.suffix(50).last else { return }
        withAnimation {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.b9xTextDim)
            Spacer()
            Text(value)
                .font(.subheadline.monospaced())
                .foregroundStyle(.primary)
        }
    }
}
