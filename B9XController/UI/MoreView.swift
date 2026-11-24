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
    /// 实验室隐藏入口：连点 5 次版本号（2 秒内）→ 风险提示 → 实验室。
    @State private var labTapCount = 0
    @State private var lastLabTapAt = Date.distantPast
    @State private var showLabRisk = false
    @State private var showLab = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        appCard
                        aboutCard
                        settingsCard
                        deviceCard
                        dataCard
                        demoCard
                            .id("tour-bottom")
                        // 巡游（CI 截图）专用隐藏入口：第 8 步自动打开法律页。
                        NavigationLink(destination: LegalDocumentView(readOnly: true), isActive: $showLegal) {
                            EmptyView()
                        }
                        // 实验室隐藏入口：连点 5 次版本号确认风险后进。
                        NavigationLink(destination: LabView(), isActive: $showLab) {
                            EmptyView()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
                .contentMargins(.bottom, 16, for: .scrollContent)
                .navigationTitle("我的")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                // 巡游（CI 截图）：第 8 步进法律页，第 9 步退回，第 10 步滚到底
                //（验底部留白：最后一张卡距 Tab 栏约 16pt），第 11 步弹实验室
                // 风险提示，第 12 步进实验室结果表预览。
                // onAppear 也补一次：固定步数启动时 MoreView 是在 tab 切过来后
                // 才挂载的，挂载时 step 已是 8/10/11/12，onChange 收不到变化。
                .onChange(of: tour.step) { _, step in
                    guard tour.isTouring else { return }
                    if step == 8 { showLegal = true }
                    if step == 9 { showLegal = false }
                    if step == 10 { scrollToBottom(proxy) }
                    if step == 11 { showLabRisk = true }
                    if step == 12 { showLab = true }
                }
                .onAppear {
                    if tour.isTouring && tour.step == 8 { showLegal = true }
                    if tour.isTouring && tour.step == 10 { scrollToBottom(proxy) }
                    if tour.isTouring && tour.step == 11 { showLabRisk = true }
                    if tour.isTouring && tour.step == 12 { showLab = true }
                }
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
        // 实验室风险提示：进实验室前先确认，确认后才导航进去。
        .alert("实验室 · 风量上限测试", isPresented: $showLabRisk) {
            Button("取消", role: .cancel) { }
            Button("我知道了，开始测试") { showLab = true }
        } message: {
            Text("这是一项真机风量上限测试：风扇会长时间满速运转，发热明显。请用足功率 PD 电源供电，测前清理风扇灰尘。测试中热面上升过快、高温保护触发或断连时会自动中止，测完恢复你原来的模式。")
        }
    }

    /// 巡游第 10 步：滚到最后一张卡底部（验底部留白）。
    /// onAppear 时布局可能还没稳，晚 0.4 秒再滚；截图在启动 4 秒后才拍，来得及。
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation {
                proxy.scrollTo("tour-bottom", anchor: .bottom)
            }
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
                    // 实验室隐藏入口：2 秒内连点 5 次版本号。
                    .onTapGesture {
                        let now = Date()
                        labTapCount = now.timeIntervalSince(lastLabTapAt) < 2 ? labTapCount + 1 : 1
                        lastLabTapAt = now
                        if labTapCount >= 5 {
                            labTapCount = 0
                            showLabRisk = true
                        }
                    }
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
