import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// 更多页（对照原版“设置”页）：7 项菜单 + 宣传演示模式开关。
struct MoreView: View {
    @EnvironmentObject private var controller: CoolerController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("设置")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    menuCard
                    demoCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            .toolbar(.hidden, for: .navigationBar)
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

    private var menuCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                menuRow("外观与主页", "主题 · 玻璃 · 主页 · 背景 · 动画与方向") {
                    AppearanceView()
                }
                Divider().background(Color.white.opacity(0.1))
                menuRow("设备与连接", connectionSubtitle) {
                    ConnectView()
                }
                Divider().background(Color.white.opacity(0.1))
                menuRow("后台运行", "无障碍保活 · 前台服务 · 后台权限 · 退出诊断") {
                    BackgroundRunView()
                }
                Divider().background(Color.white.opacity(0.1))
                menuRow("系统集成", "通知栏 · 原生实时动态 · HyperOS 超级岛") {
                    IntegrationView()
                }
                Divider().background(Color.white.opacity(0.1))
                menuRow("设备功能", "散热模式 · 自由变频 · 超频 · 灯光 · 保护 · 定时") {
                    DeviceFeaturesView()
                }
                Divider().background(Color.white.opacity(0.1))
                menuRow("数据与高级", "备份 · 刷新 · 运行日志 · 诊断") {
                    DataAdvancedView()
                }
                Divider().background(Color.white.opacity(0.1))
                menuRow("关于我们", "支持作者 · 用户须知 · 版本信息") {
                    AboutView()
                }
            }
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
                        .foregroundStyle(.white)
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
                        .foregroundStyle(.white)
                    Text("用于截图/录屏宣传；模拟真实设备状态，不扫描、不连接、也不会向散热器发送蓝牙指令。")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
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

// ------------------------------------------------------------ 外观与主页

struct AppearanceView: View {
    @AppStorage("glassEnabled") private var glassEnabled = true
    @AppStorage("animationsEnabled") private var animationsEnabled = true
    @AppStorage("defaultTab") private var defaultTab = "device"

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(spacing: 12) {
                        Toggle("液态玻璃底栏", isOn: $glassEnabled)
                        Toggle("界面动画", isOn: $animationsEnabled)
                        HStack {
                            Text("打开时默认页面")
                            Spacer()
                            Picker("", selection: $defaultTab) {
                                Text("设备").tag("device")
                                Text("联动").tag("automation")
                                Text("更多").tag("more")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                        }
                    }
                    .foregroundStyle(.white)
                }
                Text("主题固定为深色（跟随原版）；背景为纯色深色。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .navigationTitle("外观与主页")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ------------------------------------------------------------ 后台运行

struct BackgroundRunView: View {
    @EnvironmentObject private var controller: CoolerController

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        infoRow("蓝牙后台模式", "bluetooth-central 已配置")
                        infoRow("蓝牙状态", controller.ble.bluetoothState)
                        infoRow("断线自动重连", controller.ble.autoReconnectEnabled ? "开启" : "关闭")
                        Divider().background(Color.white.opacity(0.1))
                        Text("无障碍保活：iOS 没有无障碍保活，已去掉；断线后自动重连。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                        Text("前台服务：iOS 没有前台服务概念，已用系统蓝牙后台模式替代。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("退出诊断")
                            .font(.headline)
                            .foregroundStyle(.white)
                        let disconnects = controller.logs.filter { $0.message.contains("断开") }
                        if disconnects.isEmpty {
                            Text("暂无异常退出记录。")
                                .font(.subheadline)
                                .foregroundStyle(Color.b9xTextDim)
                        } else {
                            ForEach(disconnects.suffix(5)) { entry in
                                Text("\(entry.timeString)  \(entry.message)")
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .navigationTitle("后台运行")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.b9xTextDim)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.white)
        }
    }
}

// ------------------------------------------------------------ 系统集成

struct IntegrationView: View {
    @AppStorage("notifyOnDisconnect") private var notifyOnDisconnect = false
    @State private var notifyStatus = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("散热器断连时发通知", isOn: Binding(
                            get: { notifyOnDisconnect },
                            set: { newValue in
                                if newValue {
                                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                                        DispatchQueue.main.async {
                                            notifyOnDisconnect = granted
                                            notifyStatus = granted ? "已授权" : "未授权，请去系统设置里允许通知"
                                        }
                                    }
                                } else {
                                    notifyOnDisconnect = false
                                    notifyStatus = ""
                                }
                            }
                        ))
                        .foregroundStyle(.white)
                        if !notifyStatus.isEmpty {
                            Text(notifyStatus)
                                .font(.caption)
                                .foregroundStyle(Color.b9xTextDim)
                        }
                        Divider().background(Color.white.opacity(0.1))
                        Text("原生实时动态（Live Activity）：后续版本实现，需小组件扩展。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                        Text("HyperOS 超级岛：iOS 无对等功能。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .navigationTitle("系统集成")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ------------------------------------------------------------ 设备功能

struct DeviceFeaturesView: View {
    @EnvironmentObject private var controller: CoolerController
    @State private var curve: [Int] = [40, 60, 80, 100, 120, 140, 155, 170, 175]

    private var state: CoolerState { controller.state }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ModeGridView()

                NavigationLink {
                    LEDView()
                } label: {
                    GlassCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("灯光")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("19 种灯效 · 颜色与速度可调")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.b9xTextDim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Color.b9xTextDim)
                        }
                    }
                }

                curveCard

                NavigationLink {
                    ProtectionView()
                } label: {
                    GlassCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("保护机制")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("冻结模式 · 低温保护 · 高温保护")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.b9xTextDim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Color.b9xTextDim)
                        }
                    }
                }

                NavigationLink {
                    TimerView()
                } label: {
                    GlassCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("定时关机")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text(state.timedShutdownRunning ? "运行中，剩余 \(state.timeCountdown) 秒" : "未开启")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.b9xTextDim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Color.b9xTextDim)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .navigationTitle("设备功能")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            curve = state.customLevels.count == 9 ? state.customLevels : curve
        }
    }

    private var curveCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("自定义温度曲线（9 段）")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("每段对应一个温度点的制冷档位，值越大越冷。仅 B9X 支持。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                ForEach(0..<9, id: \.self) { i in
                    HStack {
                        Text("段 \(i + 1)")
                            .font(.caption)
                            .foregroundStyle(Color.b9xTextDim)
                            .frame(width: 36, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(curve[i]) },
                            set: { curve[i] = Int($0) }
                        ), in: 0...175, step: 1)
                        .tint(.b9xAccent)
                        Text("\(curve[i])")
                            .font(.caption.monospaced())
                            .foregroundStyle(.white)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
                Button {
                    controller.setCustomCurve(curve)
                } label: {
                    Text("应用曲线")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.b9xAccent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

// ------------------------------------------------------------ 数据与高级

struct DataAdvancedView: View {
    @EnvironmentObject private var controller: CoolerController
    @State private var showExport = false
    @State private var showImport = false
    @State private var exportData: Data?
    @State private var importError: String?

    private var state: CoolerState { controller.state }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("备份")
                            .font(.headline)
                            .foregroundStyle(.white)
                        HStack(spacing: 10) {
                            Button {
                                let settings = controller.currentSettingsExport()
                                exportData = try? JSONEncoder().encode(settings)
                                showExport = true
                            } label: {
                                Text("导出设置")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.b9xAccent.opacity(0.25))
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            Button {
                                showImport = true
                            } label: {
                                Text("导入设置")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.b9xAccent.opacity(0.25))
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("刷新")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Button {
                            controller.refreshState()
                        } label: {
                            Text("重新读取设备状态")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.b9xAccent)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("运行日志")
                            .font(.headline)
                            .foregroundStyle(.white)
                        if controller.logs.isEmpty {
                            Text("暂无记录。")
                                .font(.subheadline)
                                .foregroundStyle(Color.b9xTextDim)
                        } else {
                            ForEach(controller.logs.suffix(50)) { entry in
                                Text("\(entry.timeString)  \(entry.message)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("诊断")
                            .font(.headline)
                            .foregroundStyle(.white)
                        infoRow("蓝牙状态", controller.ble.bluetoothState)
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
        }
        .navigationTitle("数据与高级")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $showExport,
            document: SettingsFile(data: exportData ?? Data()),
            contentType: .json,
            defaultFilename: "b9x-settings.json"
        ) { _ in }
        .fileImporter(
            isPresented: $showImport,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first,
                      let data = try? Data(contentsOf: url),
                      let settings = try? JSONDecoder().decode(B9XSettingsExport.self, from: data) else {
                    importError = "导入失败：文件格式不对"
                    return
                }
                controller.applySettingsImport(settings)
            case .failure(let error):
                importError = "导入失败：\(error.localizedDescription)"
            }
        }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
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
                .foregroundStyle(.white)
        }
    }
}

/// JSON 设置文件（供 fileExporter / fileImporter 使用）。
struct SettingsFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// ------------------------------------------------------------ 关于我们

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("冰环FLY for iOS")
                            .font(.headline)
                            .foregroundStyle(.white)
                        infoRow("版本", "0.8.143（227）")
                        Text("飞智 B6X / B7X / B8X / B9X 散热器第三方控制器。基于 BLE FFE0/FFE1/FFE4 协议的原生重写，与设备品牌官方无隶属关系。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("支持作者")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Link("作者酷安主页", destination: URL(string: "https://www.coolapk.com/u/11913682")!)
                            .font(.subheadline)
                        Link("QQ 内测群", destination: URL(string: "https://qm.qq.com/q/YS35yMbq4S")!)
                            .font(.subheadline)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("用户须知与免责声明")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("超频模式会让制冷片大功率运行，请使用 30W 以上 PD 充电头供电，长时间超频可能缩短散热器寿命。本 App 为第三方工具，与飞智官方无关；使用风险由用户自行承担。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                        Text("iOS 适配说明：游戏检测自动联动无法实现（iOS 不允许读取其他 App 状态），改用“连接后恢复上次模式”+ 快捷指令；手机温度用系统热状态替代；Shizuku、悬浮窗、无障碍保活在 iOS 上没有，已去掉；后台连接用系统蓝牙后台模式保持。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("开源与第三方组件")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("SwiftUI · CoreBluetooth · AppIntents")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                        Text("原版安卓用 Jetpack Compose / Miuix 0.9.3 / AndroidLiquidGlass；协议参考开源项目 feizhi-b9x-cooler-client。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .navigationTitle("关于我们")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.b9xTextDim)
            Spacer()
            Text(value)
                .font(.subheadline.monospaced())
                .foregroundStyle(.white)
        }
    }
}
