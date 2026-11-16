import SwiftUI

/// 手动操作后自动化暂停 60 秒：UI 层本地记录（核心层 manualOverrideUntil 未对外暴露，
/// 待核心层暴露 isManualOverrideActive 后可改读核心状态）。
/// 直接读写 UserDefaults，供 DeviceView / MoreView / AutomationView 共用。
var manualOverrideUntil: Double {
    get { UserDefaults.standard.double(forKey: "manualOverrideUntil") }
    set { UserDefaults.standard.set(newValue, forKey: "manualOverrideUntil") }
}

func markManualOverride() {
    manualOverrideUntil = Date().addingTimeInterval(60).timeIntervalSince1970
}

private func manualOverrideActive(now: Date) -> Bool {
    now.timeIntervalSince1970 < manualOverrideUntil
}

/// 设备主页面（对照原版“设备”页）：
/// 顶部 B9X + 连接开关；冷面温度一行 + 圆形网纹 Y 形设备图；6 格数据；
/// 散热模式卡（6 个按钮 + 按当前模式的专属行）；超频体验行；快捷控制三卡片。
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
                    noticeBanners
                    mainCard

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
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
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

    /// 冷面温度：-12.4° 一行显示，字体自适应缩小，绝不换行。
    private var coldTemperatureText: String {
        let v = state.temperatureValue
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f°C", v)
        }
        return String(format: "%.1f°C", v)
    }

    private var mainCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("冷面温度")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                        Text(connected ? coldTemperatureText : "--")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    Spacer()
                    CoolerImageView()
                        .frame(width: 140, height: 140)
                }
                Divider()
                    .padding(.vertical, 14)
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 16
                ) {
                    // CPU：iOS 读不到 CPU 温度，显示系统热状态文字。
                    dataCell("CPU", connected ? controller.phoneThermal.rawValue : "--")
                    // 电量：明确标注“电量”+ %，不要让人误会是温度。
                    dataCell("电量", connected ? (controller.batteryLevel >= 0 ? "\(controller.batteryLevel)%" : "--") : "--")
                    dataCell("热面", connected ? "\(state.hotSurfaceTemperature)°C" : "--")
                    dataCell("转速", connected ? "\(state.speed) RPM" : "--")
                    // 制冷 / 风扇强度用运行档位百分比。
                    dataCell("制冷强度", connected ? "\(state.coldPercent)%" : "--")
                    dataCell("风扇强度", connected ? "\(state.windPercent)%" : "--")
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
        .background(Color.b9xCard)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

// ------------------------------------------------------------ 超频体验行
// 只在有自动化/超频活动时显示（对照原版截图：智能/固定/自由模式下不显示）：
// 电池温控 → 左“电池温控”右“电池温控”；目标温控 → 左/右“目标温控”；
// 超频 → 左“超频体验”，右为手动暂停文案或“已开启”。

struct OverclockExperienceRow: View {
    @EnvironmentObject private var controller: CoolerController
    var onTap: (() -> Void)? = nil

    private var state: CoolerState { controller.state }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            if shouldShow(now: now) {
                Button {
                    onTap?()
                } label: {
                    HStack {
                        Text(leftTitle)
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.b9xAccentLight)
                        Spacer()
                        Text(rightText(now: now))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        if onTap != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Color.b9xTextDim)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                .disabled(onTap == nil)
            }
        }
    }

    private func shouldShow(now: Date) -> Bool {
        state.freezeMode || state.softwareThermalMode != 0 || manualOverrideActive(now: now)
    }

    private var leftTitle: String {
        if state.freezeMode { return "超频体验" }
        switch state.softwareThermalMode {
        case 100: return "电池温控"
        case 101: return "目标温控"
        default: return "超频体验"
        }
    }

    private func rightText(now: Date) -> String {
        if manualOverrideActive(now: now) {
            return "用户手动操作，自动化暂停 60 秒"
        }
        if state.freezeMode { return "已开启" }
        switch state.softwareThermalMode {
        case 100: return "电池温控"
        case 101: return "目标温控"
        default: return "自动化待机"
        }
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

    init(runMode: Int) {
        switch runMode {
        case B9XProtocol.modeManual: self = .manual
        case B9XProtocol.modeCustom: self = .free
        case B9XProtocol.modeOverclock: self = .overclock
        default: self = .smart // 0 智能；3 专家模式不在首页六按钮里，按智能处理
        }
    }
}

/// 九点自由变频曲线：温度点固定，档位 1...8，默认档位见 spec §2。
enum FreeCurve {
    static let temperatures = [-12, -9, -6, -3, 0, 3, 6, 9, 12]
    static let defaults = [5, 5, 5, 6, 7, 8, 8, 8, 8]

    static func effectiveLevels(from state: CoolerState) -> [Int] {
        let levels = state.customLevels
        guard levels.count == 9, levels.allSatisfy({ (1...8).contains($0) }) else {
            return defaults
        }
        return levels
    }
}

/// 散热模式卡片：当前模式 + 6 个按钮 + 按当前模式的专属行；设备页与设备功能页共用。
/// 当前模式一律从设备状态推导（Freeze > 软件温控环路 > runMode/pending），不存本地。
struct ModeGridView: View {
    @EnvironmentObject private var controller: CoolerController
    @AppStorage("overclockWarningAcknowledged") private var overclockAck = false
    @State private var showOverclockWarning = false
    @State private var showBatteryTargetSheet = false
    @State private var showCoolerTargetSheet = false

    /// 在设备功能页里时为 true：曲线编辑器就在下方，“编辑”按钮隐藏。
    var isInFeaturesPage = false

    private var state: CoolerState { controller.state }

    private var currentMode: DeviceMode {
        if state.freezeMode { return .overclock }
        switch state.softwareThermalMode {
        case 100: return .battery
        case 101: return .target
        default: break
        }
        if let pending = state.pendingRunMode {
            return DeviceMode(runMode: pending)
        }
        return DeviceMode(runMode: state.runMode)
    }

    private var subtitle: String {
        switch currentMode {
        case .smart:
            return state.smartPreset == 0 ? "静音 · 智能调节" : "极寒 · 智能调节"
        case .manual:
            switch state.manualPreset {
            case 0: return "节能 · 固定功率"
            case 1: return "强劲 · 固定功率"
            default: return "极强 · 固定功率"
            }
        case .free:
            return "九点自由变频曲线"
        case .battery:
            return "目标 \(state.batteryTargetC)°C · 自动调节制冷"
        case .target:
            return "目标 \(state.coolerTargetC)°C · 自动维持冷面温度"
        case .overclock:
            return "高性能输出 · 切换其他模式会自动退出超频"
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.b9xAccentLight)
                        .frame(width: 8, height: 8)
                    Text(currentMode.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Text(subtitle)
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
                                if currentMode == mode {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                }
                                Text(mode.name)
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(currentMode == mode ? Color.b9xAccent : Color.b9xCard2)
                            .foregroundStyle(currentMode == mode ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }

                modeExclusiveRow

                if currentMode == .overclock {
                    Divider()
                    Text("已开启")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .alert("超频体验", isPresented: $showOverclockWarning) {
            Button("取消", role: .cancel) {}
            Button("开启超频") {
                overclockAck = true
                controller.setSoftwareThermalMode(0)
                controller.setFreezeEnabled(true)
                markManualOverride()
            }
        } message: {
            Text("超频会让散热器以最大功率运行（风量最高 5700 RPM），会明显发热、耗电增加，请确保使用 30W 以上 PD 充电头供电。")
        }
        .sheet(isPresented: $showBatteryTargetSheet) {
            TargetAdjustSheet(kind: .battery)
        }
        .sheet(isPresented: $showCoolerTargetSheet) {
            TargetAdjustSheet(kind: .cooler)
        }
    }

    /// 按当前模式只显示对应的一行专属行。
    @ViewBuilder
    private var modeExclusiveRow: some View {
        switch currentMode {
        case .smart:
            HStack(spacing: 10) {
                presetButton("静音", selected: state.smartPreset == 0) {
                    markManualOverride()
                    controller.setSoftwareThermalMode(0)
                    controller.setSmartPreset(0)
                }
                presetButton("极寒", selected: state.smartPreset == 2) {
                    markManualOverride()
                    controller.setSoftwareThermalMode(0)
                    controller.setSmartPreset(2)
                }
            }
        case .manual:
            HStack(spacing: 10) {
                presetButton("节能", selected: state.manualPreset == 0) {
                    markManualOverride()
                    controller.setSoftwareThermalMode(0)
                    controller.setManualPreset(0)
                }
                presetButton("强劲", selected: state.manualPreset == 1) {
                    markManualOverride()
                    controller.setSoftwareThermalMode(0)
                    controller.setManualPreset(1)
                }
                presetButton("极强", selected: state.manualPreset == 2) {
                    markManualOverride()
                    controller.setSoftwareThermalMode(0)
                    controller.setManualPreset(2)
                }
            }
        case .free:
            HStack {
                Text("自由变频曲线")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                if isInFeaturesPage {
                    Text("在下方编辑")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                } else {
                    NavigationLink("编辑") {
                        DeviceFeaturesView()
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.b9xAccentLight)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.b9xAccent.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        case .battery:
            HStack {
                Text("电池目标 \(state.batteryTargetC)°C")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Button("调整") { showBatteryTargetSheet = true }
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.b9xAccentLight)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.b9xAccent.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        case .target:
            HStack {
                Text("冷面目标 \(state.coolerTargetC)°C")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Button("调整") { showCoolerTargetSheet = true }
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.b9xAccentLight)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.b9xAccent.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        case .overclock:
            EmptyView()
        }
    }

    private func presetButton(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                }
                Text(title)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(selected ? Color.b9xAccent : Color.b9xCard2)
            .foregroundStyle(selected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func selectMode(_ mode: DeviceMode) {
        markManualOverride()
        switch mode {
        case .smart:
            controller.setSoftwareThermalMode(0)
            controller.setSmartPreset(state.smartPreset)
        case .manual:
            controller.setSoftwareThermalMode(0)
            controller.setManualPreset(state.manualPreset)
        case .free:
            controller.setSoftwareThermalMode(0)
            controller.setCustomCurve(FreeCurve.effectiveLevels(from: state))
        case .battery:
            controller.setSoftwareThermalMode(100)
        case .target:
            controller.setSoftwareThermalMode(101)
        case .overclock:
            if state.freezeMode {
                // 已在超频时再点一次 = 退出超频。
                controller.setFreezeEnabled(false)
            } else if overclockAck {
                controller.setSoftwareThermalMode(0)
                controller.setFreezeEnabled(true)
            } else {
                showOverclockWarning = true
            }
        }
    }
}

// ------------------------------------------------------------ 目标温度调整页（sheet）
// 改完立即生效，不自动弹回，由用户点“完成”关闭。

struct TargetAdjustSheet: View {
    @EnvironmentObject private var controller: CoolerController
    @Environment(\.dismiss) private var dismiss

    enum Kind {
        case battery, cooler
    }

    let kind: Kind

    private var state: CoolerState { controller.state }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            if kind == .battery {
                                Stepper(
                                    "电池目标 \(state.batteryTargetC)°C",
                                    value: Binding(
                                        get: { state.batteryTargetC },
                                        set: {
                                            markManualOverride()
                                            controller.setSoftwareTargets(batteryTargetC: $0, coolerTargetC: state.coolerTargetC)
                                        }
                                    ),
                                    in: 10...40
                                )
                                .foregroundStyle(.primary)
                                Text("电池温度 iOS 不提供，以系统热状态估算。")
                                    .font(.caption)
                                    .foregroundStyle(Color.b9xTextDim)
                            } else {
                                Stepper(
                                    "冷面目标 \(state.coolerTargetC)°C",
                                    value: Binding(
                                        get: { state.coolerTargetC },
                                        set: {
                                            markManualOverride()
                                            controller.setTargetTemperature($0)
                                        }
                                    ),
                                    in: -20...16
                                )
                                .foregroundStyle(.primary)
                                Text("目标温控环路会自动调节制冷档位，维持冷面温度。")
                                    .font(.caption)
                                    .foregroundStyle(Color.b9xTextDim)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            .navigationTitle(kind == .battery ? "电池目标温度" : "冷面目标温度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// ------------------------------------------------------------ 保护机制页
// 只有低温保护一个开关（原版无高温保护命令，高温只是状态位）。
// Freeze（超频体验）不在这里，入口在首页模式卡与联动页。

struct ProtectionView: View {
    @EnvironmentObject private var controller: CoolerController

    private var state: CoolerState { controller.state }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(spacing: 12) {
                        Toggle("低温保护（环境过冷时限制功率）", isOn: Binding(
                            get: { state.coldProtectionEnabled },
                            set: { controller.offProtection(low: $0) }
                        ))
                        HStack {
                            Text("高温保护")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(state.hotProtectionEnabled ? "触发中" : "正常")
                                .font(.subheadline)
                                .foregroundStyle(Color.b9xTextDim)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Text("低温保护开关由设备端执行：触发条件满足时设备自动限制功率。高温保护没有开关，是设备端的状态位，热面过热时设备自动降档。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
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
                            Text("运行中，剩余 \(remainingMinutes) 分钟")
                                .font(.subheadline)
                                .foregroundStyle(Color.b9xAccentLight)
                        }
                        Stepper("时长 \(Int(minutes)) 分钟", value: $minutes, in: 5...480, step: 5)
                            .foregroundStyle(.primary)
                        Toggle("仅执行一次", isOn: $once)
                            .foregroundStyle(.primary)
                        HStack(spacing: 10) {
                            Button {
                                controller.setTimedShutdown(repeat: !once, enabled: true, minutes: Int(minutes))
                            } label: {
                                Text("开始定时")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.b9xAccent)
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            Button {
                                controller.setTimedShutdown(repeat: false, enabled: false, minutes: 0)
                            } label: {
                                Text("取消")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.primary.opacity(0.1))
                                    .foregroundStyle(.primary)
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

    private var remainingMinutes: Int {
        if state.timedCountdownInMinute {
            return state.timeCountdown
        }
        return (state.timeCountdown + 59) / 60
    }
}
