import SwiftUI

/// 首页（对照原版 HomeView / ConnectedView）：
/// 顶部设备图 + 连接阶段 + 主参数大字 + 模式卡 + 快捷控制三卡片 + 可自选参数格。
/// 连接阶段直接读 `controller.phase.displayName`（Core 已接好）。
struct HomeView: View {
    @EnvironmentObject private var controller: CoolerController
    @ObservedObject private var appearance = AppearanceSettings.shared
    @Binding var tab: ContentView.Tab
    @State private var showConnectSheet = false
    @State private var showMetricPicker = false

    private var state: CoolerState { controller.state }
    private var connected: Bool { controller.isConnected }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    topRow
                    noticeBanners
                    // 未连接时温度卡和参数卡全是 "--"，没信息量：收成一张连接卡片，
                    // 连上后再展开两张卡。模式和快捷控制保持原样（仍可进页面）。
                    if connected {
                        heroCard
                        metricsCard
                    } else {
                        connectPromptCard
                    }

                    HStack {
                        Text("散热模式")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Spacer()
                        NavigationLink("更多 ›") {
                            DeviceFeaturesView()
                        }
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xAccentLight)
                    }

                    ModeGridView()

                    OverclockExperienceRow {
                        tab = .automation
                    }

                    quickControls
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .contentMargins(.bottom, 16, for: .scrollContent)
            .navigationBarTitleDisplayMode(.inline)
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
            .sheet(isPresented: $showMetricPicker) {
                MetricPickerView()
            }
        }
    }

    // ------------------------------------------------------------ 连接阶段
    // 直接读控制器发布的 ConnectionPhase（READY 只由首帧 0x13 置位）。

    private var phaseText: String {
        if controller.demoMode { return "演示中" }
        return controller.phase.displayName
    }

    private var phaseColor: Color {
        if controller.demoMode { return .b9xAccentLight }
        switch controller.phase {
        case .ready: return .green
        case .connecting, .scanning, .discovering, .subscribing, .recovering: return .yellow
        case .failed: return .red
        case .flashing: return .b9xAccentLight
        case .idle, .disconnected: return .gray
        }
    }

    private var topRow: some View {
        HStack {
            NavigationLink {
                ConnectView()
            } label: {
                HStack(spacing: 4) {
                    Text("B9X")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Color.b9xTextDim)
                }
            }
            Circle()
                .fill(phaseColor)
                .frame(width: 8, height: 8)
            Text(phaseText)
                .font(.subheadline)
                .foregroundStyle(Color.b9xTextDim)
            Spacer()
            Text("连接")
                .font(.subheadline)
                .foregroundStyle(.primary)
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

    /// 首页横幅：假连 / 遗留超频提示（核心层 connectionNote）与最近一次错误。
    @ViewBuilder
    private var noticeBanners: some View {
        if let note = state.connectionNote, !note.isEmpty {
            GlassCard {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let error = state.lastError, !error.isEmpty {
            GlassCard {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // ------------------------------------------------------------ 未连接提示卡
    //
    // 未连接时替代温度卡 + 参数卡：整张卡可点，点按逻辑和顶部“连接”开关一致
    // （有上次设备就自动连，没有就打开连接页）。

    private var connectPromptCard: some View {
        GlassCard {
            Button(action: connectTapped) {
                HStack(spacing: 12) {
                    // 蓝牙图标用自带符号：SF Symbols 里没有 "bluetooth"，用它会显示空白；
                    // "antenna.radiowaves.left.and.right" 是现成的无线信号符号。
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundStyle(Color.b9xAccentLight)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("点此连接 B9X")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("连接后显示冷板温度、转速和运行参数")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Color.b9xTextDim)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func connectTapped() {
        if controller.demoMode { return }
        if controller.ble.hasLastDevice() {
            controller.ble.autoConnectLastDevice()
        } else {
            showConnectSheet = true
        }
    }

    // ------------------------------------------------------------ 主参数

    private var heroCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appearance.primaryMetric.title)
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                        Text(connected ? Self.valueString(for: appearance.primaryMetric, state: state, controller: controller) : "--")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text("\(appearance.secondaryMetric.title) \(connected ? Self.valueString(for: appearance.secondaryMetric, state: state, controller: controller) : "--")")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer()
                    CoolerImageView()
                        .frame(width: 120, height: 120)
                }
                Divider()
                    .padding(.vertical, 10)
                HStack {
                    Text(state.deviceName)
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                    Spacer()
                    Text(phaseText)
                        .font(.subheadline)
                        .foregroundStyle(phaseColor)
                }
            }
        }
    }

    // ------------------------------------------------------------ 参数格

    /// 显示列表里的参数（主参数与辅助参数已在上方大字区出现，这里不再重复）。
    private var gridMetrics: [HomeMetric] {
        appearance.visibleMetrics.filter { $0 != appearance.primaryMetric && $0 != appearance.secondaryMetric }
    }

    private var metricsCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                HStack {
                    Text("参数")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("自选参数") { showMetricPicker = true }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xAccentLight)
                }
                if gridMetrics.isEmpty {
                    Text("主参数与辅助参数已在上方显示，去“自选参数”里再挑几项。")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 12
                    ) {
                        ForEach(gridMetrics) { metric in
                            dataCell(
                                metric.displayTitle,
                                connected ? Self.valueString(for: metric, state: state, controller: controller) : "--"
                            )
                        }
                    }
                }
                if appearance.visibleMetrics.contains(where: { $0.isUnavailable }) {
                    Text("功率、供电读数：设备未上报，暂显示 —。")
                        .font(.caption)
                        .foregroundStyle(Color.b9xTextDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // ------------------------------------------------------------ 快捷控制

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷控制")
                .font(.title3.bold())
                .foregroundStyle(.primary)
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
                        subtitle: connected ? protectionSubtitle : "--"
                    )
                }
                NavigationLink {
                    TimerView()
                } label: {
                    quickCard(
                        icon: "timer",
                        title: "定时关机",
                        subtitle: connected
                            ? (state.timedShutdownRunning ? "剩余 \(remainingMinutes) 分钟" : "未开启")
                            : "--"
                    )
                }
            }
        }
    }

    /// 双保护：低温保护已开 + 高温保护位；单保护：只开一个；都不开：已关闭。
    private var protectionSubtitle: String {
        let cold = state.coldProtectionEnabled
        let hot = state.hotProtectionEnabled
        if cold && hot { return "双保护正常" }
        if cold || hot { return "单保护" }
        return "已关闭"
    }

    /// 剩余分钟：设备倒计时以秒存，分钟制倒计时直接取分钟数。
    private var remainingMinutes: Int {
        if state.timedCountdownInMinute {
            return state.timeCountdown
        }
        return (state.timeCountdown + 59) / 60
    }

    private func quickCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.b9xAccentLight)
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Color.b9xTextDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .glassBackground(in: RoundedRectangle(cornerRadius: 20))
    }

    // ------------------------------------------------------------ 参数取值

    /// 13 项参数的显示值。功率与供电读数设备未上报，返回 "—"（不编造）。
    static func valueString(for metric: HomeMetric, state: CoolerState, controller: CoolerController) -> String {
        switch metric {
        case .coldPlate:
            let v = state.temperatureValue
            if v.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0f°C", v)
            }
            return String(format: "%.1f°C", v)
        case .hotSurface:
            return "\(state.hotSurfaceTemperature)°C"
        case .rpm:
            return "\(state.speed) RPM"
        case .power:
            return "—"
        case .coolingOutput:
            return "\(state.coldPercent)%"
        case .fanOutput:
            return "\(state.windPercent)%"
        case .level:
            return "冷\(state.coldRunLevel) · 风\(state.windRunLevel)"
        case .mode:
            return state.displayModeName
        case .targetTemp:
            return "\(state.targetTemperature)°C"
        case .battery:
            return controller.batteryLevel >= 0 ? "\(controller.batteryLevel)%" : "—"
        case .remaining:
            guard state.timedShutdownRunning else { return "—" }
            let minutes = state.timedCountdownInMinute
                ? state.timeCountdown
                : (state.timeCountdown + 59) / 60
            return "\(minutes) 分钟"
        case .supply:
            return "—"
        case .targetControl:
            switch state.softwareThermalMode {
            case B9XProtocol.thermalModeBattery:
                return "电池 \(state.batteryTargetC)°C"
            case B9XProtocol.thermalModeCoolerTarget:
                return "冷面 \(state.coolerTargetC)°C"
            default:
                return "—"
            }
        }
    }
}

private extension HomeMetric {
    /// “手机电量”格明确标注是电量不是温度；其余项直接用标题。
    var displayTitle: String {
        switch self {
        case .battery: return "手机电量"
        default: return title
        }
    }
}

// ------------------------------------------------------------ 参数自选页

/// 主参数 + 辅助参数 + 显示列表（13 项任选），存在 AppearanceSettings 里。
struct MetricPickerView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("主参数（首页大字）") {
                    ForEach(HomeMetric.allCases) { metric in
                        metricRow(metric, selected: appearance.primaryMetric == metric) {
                            appearance.primaryMetric = metric
                        }
                    }
                }
                Section("辅助参数（主参数下方小字）") {
                    ForEach(HomeMetric.allCases) { metric in
                        metricRow(metric, selected: appearance.secondaryMetric == metric) {
                            appearance.secondaryMetric = metric
                        }
                    }
                }
                Section("显示列表（下方参数格，至少留一项）") {
                    ForEach(HomeMetric.allCases) { metric in
                        Toggle(isOn: Binding(
                            get: { appearance.isMetricVisible(metric) },
                            set: { appearance.setMetricVisible(metric, $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(metric.title)
                                if let note = metric.unavailableNote {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(Color.b9xTextDim)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("自选参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func metricRow(_ metric: HomeMetric, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title)
                        .foregroundStyle(.primary)
                    if let note = metric.unavailableNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.b9xAccentLight)
                }
            }
        }
    }
}
