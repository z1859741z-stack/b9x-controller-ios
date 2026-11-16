import SwiftUI

/// 设备主页面（对照原版“设备”页）：
/// 顶部 B9X + 连接开关；冷面温度 + 散热器图；6 格数据；
/// 散热模式（6 个按钮）；超频体验行；快捷控制三卡片。
struct DeviceView: View {
    @EnvironmentObject private var controller: CoolerController
    @Binding var tab: ContentView.Tab
    @State private var showConnectSheet = false

    private var state: CoolerState { controller.state }
    private var connected: Bool { controller.isConnected }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    topRow
                    mainCard

                    HStack {
                        Text("散热模式")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                        Spacer()
                        NavigationLink("更多 ›") {
                            DeviceFeaturesView()
                        }
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xAccentLight)
                    }

                    ModeGridView()

                    // 超频体验 | 自动化待机 → 跳到联动页。
                    Button {
                        tab = .automation
                    } label: {
                        HStack {
                            Text("超频体验")
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.b9xAccentLight)
                            Spacer()
                            Text("自动化待机")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Color.b9xTextDim)
                        }
                        .padding(.horizontal, 4)
                    }

                    quickControls
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showConnectSheet) {
                NavigationStack {
                    ConnectView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("完成") { showConnectSheet = false }
                            }
                        }
                }
            }
        }
    }

    private var statusText: String {
        if controller.demoMode { return "演示中" }
        switch controller.connection {
        case .connected: return "已连接"
        case .connecting: return "正在连接…"
        case .scanning: return "扫描中…"
        case .disconnecting: return "断开中…"
        case .idle: return "未连接"
        }
    }

    private var statusColor: Color {
        if controller.demoMode { return .b9xAccentLight }
        switch controller.connection {
        case .connected: return .green
        case .connecting, .scanning: return .yellow
        default: return .gray
        }
    }

    private var topRow: some View {
        HStack {
            Text("B9X")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.b9xTextDim)
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(Color.b9xTextDim)
            Spacer()
            Text("连接中")
                .font(.subheadline)
                .foregroundStyle(.white)
            Toggle("", isOn: Binding(
                get: { connected },
                set: { on in
                    if on {
                        if controller.demoMode { return }
                        if controller.ble.hasLastDevice() {
                            controller.ble.autoConnectLastDevice()
                        } else {
                            showConnectSheet = true
                        }
                    } else {
                        if controller.demoMode {
                            controller.exitDemo()
                        } else {
                            controller.disconnect()
                        }
                    }
                }
            ))
            .labelsHidden()
        }
    }

    private var mainCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("冷面温度")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                        Text(connected ? String(format: "%.1f°", state.temperatureValue) : "--")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    CoolerImageView()
                        .frame(width: 140, height: 140)
                }
                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.vertical, 14)
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 16
                ) {
                    dataCell("CPU", connected ? controller.phoneThermal.rawValue : "--")
                    dataCell("电池", connected ? (controller.batteryLevel >= 0 ? "\(controller.batteryLevel)%" : "--") : "--")
                    dataCell("热面", connected ? "\(state.hotSurfaceTemperature)°" : "--")
                    dataCell("转速", connected ? "\(state.speed)" : "--")
                    dataCell("制冷强度", connected ? "\(state.effectiveColdLevel)" : "--")
                    dataCell("风扇强度", connected ? "\(state.effectiveWindLevel)" : "--")
                }
            }
        }
    }

    private func dataCell(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.b9xTextDim)
            Text(value)
                .font(.headline.monospaced())
                .foregroundStyle(.white)
        }
    }

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷控制")
                .font(.title3.bold())
                .foregroundStyle(.white)
            HStack(spacing: 12) {
                NavigationLink {
                    LEDView()
                } label: {
                    quickCard(
                        icon: "lightbulb",
                        title: "灯光",
                        subtitle: connected
                            ? (state.lightOn ? (B9XProtocol.ledTypes[state.ledType] ?? "开启") : "关闭")
                            : "--"
                    )
                }
                NavigationLink {
                    ProtectionView()
                } label: {
                    quickCard(
                        icon: "shield",
                        title: "保护机制",
                        subtitle: connected
                            ? ((state.coldProtectionEnabled || state.hotProtectionEnabled) ? "已开启" : "未开启")
                            : "--"
                    )
                }
                NavigationLink {
                    TimerView()
                } label: {
                    quickCard(
                        icon: "timer",
                        title: "定时关机",
                        subtitle: connected
                            ? (state.timedShutdownRunning ? "剩余 \(state.timeCountdown) 秒" : "未开启")
                            : "--"
                    )
                }
            }
        }
    }

    private func quickCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.b9xAccentLight)
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Color.b9xTextDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.b9xCard)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

// ------------------------------------------------------------ 散热模式

/// 六种模式（对照原版按钮）：智能变频 / 固定功率 / 自由变频 / 电池温控 / 目标温控 / 超频模式。
enum DeviceMode: String, CaseIterable {
    case smart, manual, free, battery, target, overclock

    var name: String {
        switch self {
        case .smart: return "智能变频"
        case .manual: return "固定功率"
        case .free: return "自由变频"
        case .battery: return "电池温控"
        case .target: return "目标温控"
        case .overclock: return "超频模式"
        }
    }

    var desc: String {
        switch self {
        case .smart: return "智能变频 · 按目标温度自动调节"
        case .manual: return "固定功率 · 制冷与风量固定档位"
        case .free: return "自由变频 · 实验性智能变频"
        case .battery: return "电池温控 · 跟踪电池温度自动变频"
        case .target: return "目标温控 · 维持设定的目标温度"
        case .overclock: return "高性能输出 · 切换其他模式会自动退出超频"
        }
    }
}

/// 散热模式卡片：当前模式 + 6 个按钮 + 状态；设备页与设备功能页共用。
struct ModeGridView: View {
    @EnvironmentObject private var controller: CoolerController
    @AppStorage("overclockWarningAcknowledged") private var overclockAck = false
    @AppStorage("uiMode") private var uiMode = "smart"
    @State private var showOverclockWarning = false

    private var state: CoolerState { controller.state }
    private var currentMode: DeviceMode { DeviceMode(rawValue: uiMode) ?? .smart }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.b9xAccentLight)
                        .frame(width: 8, height: 8)
                    Text(currentMode.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                Text(currentMode.desc)
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 10
                ) {
                    ForEach(DeviceMode.allCases, id: \.self) { mode in
                        Button {
                            selectMode(mode)
                        } label: {
                            HStack(spacing: 4) {
                                if uiMode == mode.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                }
                                Text(mode.name)
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(uiMode == mode.rawValue ? Color.b9xAccent : Color.b9xCard2)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }

                if uiMode == "manual" {
                    LevelSlider(title: "制冷强度", level: state.effectiveColdLevel) { level in
                        controller.setColdLevel(level)
                    }
                    LevelSlider(title: "风量", level: state.effectiveWindLevel) { level in
                        controller.setWindLevel(level)
                    }
                }
                if uiMode == "target" || uiMode == "smart" {
                    Stepper(
                        "目标温度 \(state.targetTemperature)°C",
                        value: Binding(
                            get: { state.targetTemperature },
                            set: { newValue in
                                controller.setRunMode(mode: B9XProtocol.modeSmart, targetTemperature: newValue)
                            }
                        ),
                        in: 0...30
                    )
                    .foregroundStyle(.white)
                }
                if uiMode == "battery" {
                    Text("由电池智能稳温驱动（用手机热状态代替电池温度），目标区间在联动页设置。")
                        .font(.caption)
                        .foregroundStyle(Color.b9xTextDim)
                }

                Divider().background(Color.white.opacity(0.1))
                Text(controller.isConnected ? "已开启" : "未开启")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .alert("超频警告", isPresented: $showOverclockWarning) {
            Button("取消", role: .cancel) {}
            Button("我知道了，开启超频") {
                overclockAck = true
                uiMode = "overclock"
                controller.setOverclock()
            }
        } message: {
            Text("超频会让制冷片以 10W / 30W 大功率运行，散热器会明显发热、耗电增加，长时间使用可能缩短寿命。请确保使用 30W 以上 PD 充电头供电。")
        }
    }

    private func selectMode(_ mode: DeviceMode) {
        uiMode = mode.rawValue
        switch mode {
        case .smart:
            controller.setRunMode(mode: B9XProtocol.modeSmart)
        case .manual:
            controller.setRunMode(mode: B9XProtocol.modeManual)
        case .free:
            controller.setRunMode(mode: B9XProtocol.modeExperimentalSmart)
            controller.setExperimentalMode(enabled: true)
        case .battery:
            controller.setBatteryTempMode()
        case .target:
            controller.setRunMode(mode: B9XProtocol.modeSmart)
        case .overclock:
            if overclockAck {
                controller.setOverclock()
            } else {
                showOverclockWarning = true
            }
        }
    }
}

// ------------------------------------------------------------ 保护机制页

struct ProtectionView: View {
    @EnvironmentObject private var controller: CoolerController

    private var state: CoolerState { controller.state }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(spacing: 12) {
                        Toggle("冻结模式（结霜保护）", isOn: Binding(
                            get: { state.freezeModeEnabled },
                            set: { controller.setFreezeMode($0) }
                        ))
                        Toggle("低温保护（环境过冷时限制功率）", isOn: Binding(
                            get: { state.coldProtectionEnabled },
                            set: { controller.offProtection(low: $0) }
                        ))
                        Toggle("高温保护（热面过热时自动降档）", isOn: Binding(
                            get: { state.hotProtectionEnabled },
                            set: { controller.offProtection(high: $0) }
                        ))
                    }
                    .foregroundStyle(.white)
                }
                Text("保护开关由设备端执行：触发条件满足时设备自动降档或限制功率。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .navigationTitle("保护机制")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ------------------------------------------------------------ 定时关机页

struct TimerView: View {
    @EnvironmentObject private var controller: CoolerController
    @State private var minutes: Double = 30
    @State private var once = true

    private var state: CoolerState { controller.state }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        if state.timedShutdownRunning {
                            Text("运行中，剩余 \(state.timeCountdown) 秒")
                                .font(.subheadline)
                                .foregroundStyle(Color.b9xAccentLight)
                        }
                        Stepper("时长 \(Int(minutes)) 分钟", value: $minutes, in: 5...480, step: 5)
                            .foregroundStyle(.white)
                        Toggle("仅执行一次", isOn: $once)
                            .foregroundStyle(.white)
                        HStack(spacing: 10) {
                            Button {
                                controller.setTimedShutdown(once: once, mode: 0, seconds: Int(minutes) * 60)
                            } label: {
                                Text("开始定时")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.b9xAccent)
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            Button {
                                controller.setTimedShutdown(once: true, mode: 0, seconds: 0)
                            } label: {
                                Text("取消")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.1))
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .navigationTitle("定时关机")
        .navigationBarTitleDisplayMode(.inline)
    }
}
