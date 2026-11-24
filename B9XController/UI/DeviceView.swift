import SwiftUI

/// 手动操作后自动化暂停 60 秒：UI 层本地记录（核心层 manualOverrideUntil 未对外暴露，
/// 待核心层暴露 isManualOverrideActive 后可改读核心状态）。
/// 直接读写 UserDefaults，供 HomeView / MoreView / AutomationView 共用。
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

/// 散热模式卡片：当前模式 + 6 个按钮 + 按当前模式的专属行；首页与设备功能页共用。
/// 当前模式一律从设备状态推导（Freeze > 软件温控环路 > runMode/pending），不存本地。
struct ModeGridView: View {
    @EnvironmentObject private var controller: CoolerController
    @AppStorage("overclockWarningAcknowledged") private var overclockAck = false
    @StateObject private var tour = TourDriver.shared
    @State private var showOverclockWarning = false
    @State private var showBatteryTargetSheet = false
    @State private var showCoolerTargetSheet = false
    /// 本地乐观选中态：点按立即更新 UI，不等设备回包；设备确认态（currentMode）
    /// 追上后自动清掉，超时 5 秒未确认也回落到设备真实状态。
    @State private var localMode: DeviceMode?
    @State private var dispatchTask: Task<Void, Never>?
    @State private var reconcileTask: Task<Void, Never>?

    /// 在设备功能页里时为 true：曲线编辑器就在下方，“编辑”按钮隐藏。
    var isInFeaturesPage = false

    private var state: CoolerState { controller.state }

    /// 界面显示用的模式：本地乐观态优先，设备确认态兜底。
    private var displayMode: DeviceMode { localMode ?? currentMode }

    private var currentMode: DeviceMode {
        if state.freezeMode {
            // 正在退出超频去切别的模式：显示目标模式，避免选中态来回跳。
            if let pending = state.pendingRunMode { return DeviceMode(runMode: pending) }
            return .overclock
        }
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
        switch displayMode {
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
                    Text(displayMode.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)

                // 同组液态玻璃控件放进一个容器：统一取样、相邻玻璃过渡一致（间距 < 控件间隙，不会融成一块）。
                GlassEffectContainer(spacing: 4) {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 10
                    ) {
                        ForEach(DeviceMode.allCases, id: \.self) { mode in
                            Button {
                                selectMode(mode)
                            } label: {
                                HStack(spacing: 4) {
                                    if displayMode == mode {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                    }
                                    Text(mode.name)
                                        .font(.subheadline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .glassBackground((displayMode == mode ? Color.b9xAccent : Color.clear), in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(displayMode == mode ? .white : .primary)
                            }
                            .accessibilityIdentifier("mode.\(mode.rawValue)")
                        }
                    }
                }
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.8), value: displayMode)

                modeExclusiveRow

                if displayMode == .overclock {
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
                setLocalMode(.overclock)
                dispatchMode(.overclock)
                markManualOverride()
            }
        } message: {
            Text("超频会让散热器以最大功率运行（风量最高 5700 RPM），会明显发热、耗电增加，请确保使用 30W 以上 PD 充电头供电。")
        }
        .onChange(of: currentMode) { _, newValue in
            // 设备确认态追上本地乐观态：交还给设备状态驱动。
            if localMode == newValue {
                localMode = nil
                reconcileTask?.cancel()
            }
        }
        .onChange(of: state.lastError) { _, err in
            // 设备明确没确认（模式/超频事务失败）：立刻回落到真实状态，不再等超时。
            if let err, err.contains("未确认") {
                localMode = nil
                reconcileTask?.cancel()
            }
        }
        .sheet(isPresented: $showBatteryTargetSheet) {
            TargetAdjustSheet(kind: .battery)
        }
        .sheet(isPresented: $showCoolerTargetSheet) {
            TargetAdjustSheet(kind: .cooler)
        }
        // 巡游（CI 截图）：按步骤只改本地选中态展示，不发任何模式帧。
        .onChange(of: tour.step) { _, step in
            guard tour.isTouring, step < DeviceMode.allCases.count else { return }
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.8)) {
                localMode = DeviceMode.allCases[step]
            }
        }
    }

    /// 按当前模式只显示对应的一行专属行（用乐观态，点按立即切换）。
    @ViewBuilder
    private var modeExclusiveRow: some View {
        switch displayMode {
        case .smart:
            GlassEffectContainer(spacing: 4) {
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
            }
        case .manual:
            GlassEffectContainer(spacing: 4) {
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
                    .glassBackground(Color.b9xAccent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
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
                    .glassBackground(Color.b9xAccent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
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
                    .glassBackground(Color.b9xAccent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
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
            .glassBackground((selected ? Color.b9xAccent : Color.clear), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(selected ? .white : .primary)
        }
        // 对照探针（点按测试用）：记下这个预设按钮的全局 frame。
        // 它是用户确认能点按的 SwiftUI Button（切预设），拿它当对照，
        // 看 harness 的 UIKit hitTest 能不能找到 SwiftUI 按钮。
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            TapTestDriver.shared.recordFrame(tab: "preset-\(title)", frame: frame)
        }
    }

    /// 点按立即本地乐观更新选中态（弹簧动画）+ 120ms 防抖后异步发帧；
    /// 连续快点只发最后一次；设备回包只校对、不抢 UI。
    private func selectMode(_ mode: DeviceMode) {
        markManualOverride()
        if mode == .overclock {
            if state.freezeMode {
                // 已在超频时再点一次 = 退出超频：乐观显示为设备当前运行模式。
                let fallback = DeviceMode(runMode: state.pendingRunMode ?? state.runMode)
                setLocalMode(fallback == .overclock ? .smart : fallback)
                dispatchDebounced(mode)
            } else if overclockAck {
                setLocalMode(mode)
                dispatchDebounced(mode)
            } else {
                showOverclockWarning = true
            }
            return
        }
        setLocalMode(mode)
        dispatchDebounced(mode)
    }

    private func setLocalMode(_ mode: DeviceMode) {
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.8)) {
            localMode = mode
        }
        // 设备没确认就回落到设备真实状态，避免乐观态卡死。
        // 涉及进/出超频时 Freeze 事务最长约 5s、再加模式事务约 2.3s，给 9s；其余 5s。
        let involvesFreeze = state.freezeMode || mode == .overclock
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(involvesFreeze ? 9 : 5))
            if !Task.isCancelled { localMode = nil }
        }
    }

    private func dispatchDebounced(_ mode: DeviceMode) {
        dispatchTask?.cancel()
        dispatchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            dispatchMode(mode)
        }
    }

    /// 真正下发模式帧（BLE 层不动，只调控制器原有入口）。
    private func dispatchMode(_ mode: DeviceMode) {
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
                controller.setFreezeEnabled(false)
            } else {
                controller.setSoftwareThermalMode(0)
                controller.setFreezeEnabled(true)
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
                                            // 目标温控环路内只改环路目标，不退出环路。
                                            // 注意：setTargetTemperature 发 SMART 帧（manual:true）
                                            // 会立刻退出 101 环路，之前点“调整”就是在这里被踢出目标温控。
                                            controller.setCoolerTargetC($0)
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
                            set: { controller.setColdProtectionEnabled($0) }
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
                        // 同组液态玻璃控件放进一个容器：统一取样、相邻玻璃过渡一致（间距 < 控件间隙，不会融成一块）。
                        GlassEffectContainer(spacing: 4) {
                            HStack(spacing: 10) {
                                Button {
                                    controller.setTimedShutdown(repeat: !once, enabled: true, minutes: Int(minutes))
                                } label: {
                                    Text("开始定时")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .glassBackground(Color.b9xAccent, in: RoundedRectangle(cornerRadius: 12))
                                        .foregroundStyle(.white)
                                }
                                Button {
                                    controller.setTimedShutdown(repeat: false, enabled: false, minutes: 0)
                                } label: {
                                    Text("取消")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .glassBackground(in: RoundedRectangle(cornerRadius: 12))
                                        .foregroundStyle(.primary)
                                }
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

// ------------------------------------------------------------ 设备功能（散热模式页）
// 原在 MoreView.swift，首页“更多 ›”与模式卡“编辑”都链到这里，随模式卡一起搬过来。

struct DeviceFeaturesView: View {
    @EnvironmentObject private var controller: CoolerController
    @State private var curve: [Int] = FreeCurve.defaults
    @State private var coldSlider: Double = 100
    @State private var windSlider: Double = 4500

    private var state: CoolerState { controller.state }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ModeGridView(isInFeaturesPage: true)

                targetStepperCard
                slidersCard

                NavigationLink {
                    LEDView()
                } label: {
                    GlassCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("灯光")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("10 种灯效 · 颜色与速度可调")
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
                expertCard

                NavigationLink {
                    ProtectionView()
                } label: {
                    GlassCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("保护机制")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("低温保护 · 高温保护状态")
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
                                    .foregroundStyle(.primary)
                                Text(state.timedShutdownRunning ? "运行中，剩余 \(remainingMinutes) 分钟" : "未开启")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.b9xTextDim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Color.b9xTextDim)
                        }
                    }
                }

                OverclockExperienceRow()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("设备功能")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            curve = FreeCurve.effectiveLevels(from: state)
            coldSlider = Double(state.coldLevel)
            windSlider = Double(state.windLevel)
        }
        .onChange(of: state.coldLevel) { _, newValue in
            coldSlider = Double(newValue)
        }
        .onChange(of: state.windLevel) { _, newValue in
            windSlider = Double(newValue)
        }
    }

    private var remainingMinutes: Int {
        if state.timedCountdownInMinute {
            return state.timeCountdown
        }
        return (state.timeCountdown + 59) / 60
    }

    /// 目标温度步进器（-20...16，点 +/- 立即发帧，本地优先不弹回）。
    private var targetStepperCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Stepper(
                    "目标温度 \(state.coolerTargetC)°C",
                    value: Binding(
                        get: { state.coolerTargetC },
                        set: {
                            markManualOverride()
                            if state.softwareThermalMode == B9XProtocol.thermalModeCoolerTarget {
                                // 目标温控环路内：只改环路目标，不退出环路。
                                controller.setCoolerTargetC($0)
                            } else {
                                controller.setTargetTemperature($0)
                            }
                        }
                    ),
                    in: -20...16
                )
                .foregroundStyle(.primary)
                Text("目标温控环路的目标温度；智能变频下也会按此目标调节。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 制冷 / 风量滑块：拖动中实时生效、松手确认、数值与 thumb 实时同步，不显示电压。
    private var slidersCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                ValueSlider(
                    title: "制冷强度",
                    value: $coldSlider,
                    range: 0...175,
                    step: 1,
                    display: "制冷强度 \(Int(coldSlider)) · \(Int(coldSlider) * 100 / 175)%",
                    onChange: { controller.setColdLevel(Int($0)) },
                    onEditingEnded: {
                        markManualOverride()
                        controller.setColdLevel(Int($0))
                    }
                )
                ValueSlider(
                    title: "风量",
                    value: $windSlider,
                    range: 4000...5700,
                    step: 100,
                    display: "风量 \(Int(windSlider)) · \(Int(windSlider) * 100 / 5700)%",
                    onChange: { controller.setWindLevelViaMode(Int($0)) },
                    onEditingEnded: {
                        markManualOverride()
                        controller.setWindLevelViaMode(Int($0))
                    }
                )
            }
        }
    }

    /// 自定义温度曲线：9 点温度 -12...12，档位 1...8，改完立即发曲线帧。
    private var curveCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("自定义温度曲线（9 段）")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("每段对应一个温度点的制冷档位，档位 1...8，值越大越冷。仅 B9X 支持。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(0..<9, id: \.self) { i in
                    HStack {
                        Text("\(FreeCurve.temperatures[i])°C")
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.b9xTextDim)
                            .frame(width: 44, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { Double(curve[i]) },
                                set: { curve[i] = Int($0) }
                            ),
                            in: 1...8,
                            step: 1,
                            onEditingChanged: { editing in
                                if !editing {
                                    markManualOverride()
                                    controller.setCustomCurve(curve)
                                }
                            }
                        )
                        .tint(.b9xAccent)
                        Text("\(curve[i])")
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .frame(width: 20, alignment: .trailing)
                    }
                }
                Button {
                    markManualOverride()
                    controller.setCustomCurve(curve)
                } label: {
                    Text("应用曲线")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .glassBackground(Color.b9xAccent, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    /// 专家模式入口：B9X 不提供，仅保留入口。
    private var expertCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("专家模式", isOn: Binding(
                    get: { state.experimentalModeOn },
                    set: { controller.setExperimentalMode(enabled: $0) }
                ))
                .foregroundStyle(.primary)
                Text("B9X 不提供专家模式，仅保留入口；原版 App 也不使用此模式。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
