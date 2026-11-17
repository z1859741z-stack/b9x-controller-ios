import SwiftUI

/// 场景联动页（对照原版“联动”页）：
/// 超频体验总开关 + 电池/充电/前台状态；充电随动、游戏联动、电池智能稳温；
/// 手动接管窗口滑块 + 优先级规则。
struct AutomationView: View {
    @EnvironmentObject private var controller: CoolerController

    @State private var scenes: [SceneProfile] = SceneProfileStore.load()
    @State private var editingScene: SceneProfile?
    @State private var sceneResult: SceneResult?
    @State private var showSceneResult = false
    @State private var chargingConfig = ChargingRuleConfig.load()
    @State private var chargingNote: String?
    @State private var shutdownMinutes = 30
    @State private var shutdownRepeat = false
    /// 充电随动接管前的模式（拔电“恢复接管前状态”用）。
    @State private var preChargeMode: Int?
    @State private var autoStartedByCharging = false
    @State private var chargeTask: Task<Void, Never>?

    private var state: CoolerState { controller.state }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("场景联动")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                standbyCard
                chargeCard
                chargingRuleCard
                scenesCard
                timedShutdownCard
                gameCard
                batteryCard
                overrideCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .sheet(item: $editingScene) { scene in
            NavigationStack {
                SceneEditorView(scene: scene, isNew: !scenes.contains(where: { $0.id == scene.id })) { saved in
                    saveScene(saved)
                }
            }
        }
        .alert("执行结果", isPresented: $showSceneResult) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(sceneResult?.message ?? "")
        }
        .onChange(of: controller.batteryCharging) { _, charging in
            handleChargingChange(charging)
        }
        .onChange(of: controller.batteryLevel) { _, level in
            if chargingConfig.fullChargeShutdown, controller.batteryCharging, level >= 100 {
                handleFullCharge()
            }
        }
    }

    private var standbyCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "snowflake")
                        .foregroundStyle(Color.b9xAccentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("超频体验")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("自动化待机")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                    Spacer()
                    Toggle("", isOn: $controller.automationStandby)
                        .labelsHidden()
                }
                Divider()
                HStack {
                    statusColumn("电池", controller.batteryLevel >= 0 ? "\(controller.batteryLevel)%" : "--")
                    statusColumn("充电", controller.batteryCharging ? "是" : "否")
                    statusColumn("前台", "--")
                }
                Text("iOS 读不到电池温度与前台应用：电池显示电量，前台显示 --。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusColumn(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.b9xTextDim)
            Text(value)
                .font(.headline.monospaced())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chargeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(Color.b9xAccentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("充电随动")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("手机充电时连接散热器并切换指定模式，不尝试软件关机。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $controller.chargeFollowEnabled)
                        .labelsHidden()
                }
                if controller.chargeFollowEnabled {
                    HStack {
                        Text("充电时切换到")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Picker("", selection: $controller.chargeFollowMode) {
                            Text("智能变频").tag(B9XProtocol.modeSmart)
                            Text("固定功率").tag(B9XProtocol.modeManual)
                            Text("超频模式").tag(B9XProtocol.modeOverclock)
                            Text("自定义曲线").tag(B9XProtocol.modeCustom)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                    }
                }
            }
        }
    }

    private var gameCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(Color.b9xAccentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("游戏联动")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("指定游戏进入前台后拥有最高自动化优先级。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $controller.gameLinkageEnabled)
                        .labelsHidden()
                }
                if controller.gameLinkageEnabled {
                    Text("iOS 上 App 无法直接检测前台游戏。开启后请去快捷指令建自动化：打开游戏时运行“设置散热器模式”。")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("去快捷指令设置自动化", destination: URL(string: "shortcuts://")!)
                        .font(.subheadline)
                }
            }
        }
    }

    /// 电池智能稳温 = 软件温控环路（softwareThermalMode 100），目标为单个电池目标温度。
    private var batteryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "thermometer")
                        .foregroundStyle(Color.b9xAccentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("电池智能稳温")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("持续追踪电池温度，智能变频进入并维持你设定的温度区间。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { state.softwareThermalMode == 100 },
                        set: {
                            markManualOverride()
                            controller.setSoftwareThermalMode($0 ? 100 : 0)
                        }
                    ))
                    .labelsHidden()
                }
                if state.softwareThermalMode == 100 {
                    Text("电池温度 iOS 不提供，以系统热状态估算。")
                        .font(.caption)
                        .foregroundStyle(Color.b9xTextDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Stepper("电池目标 \(state.batteryTargetC)°C", value: Binding(
                        get: { state.batteryTargetC },
                        set: {
                            markManualOverride()
                            controller.setSoftwareTargets(batteryTargetC: $0, coolerTargetC: state.coolerTargetC)
                        }
                    ), in: 10...40)
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    private var overrideCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("手动接管窗口")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("手动切换模式后，联动暂时不抢回控制；场景变化后重新仲裁。")
                    .font(.subheadline)
                    .foregroundStyle(Color.b9xTextDim)
                Text("\(Int(controller.manualOverrideSeconds)) 秒")
                    .font(.title3.bold())
                    .foregroundStyle(Color.b9xAccentLight)
                Slider(value: $controller.manualOverrideSeconds, in: 10...300, step: 10)
                    .tint(.b9xAccent)
                Text("优先级：游戏 > 电池温度 > 充电。超频体验与用户手动操作始终优先。")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
    }

    // ------------------------------------------------------------ 场景

    private var scenesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(Color.b9xAccentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("场景")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("一键切到预设好的模式/档位/温度。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                    }
                    Spacer()
                    Button {
                        editingScene = SceneProfile(name: "", deviceName: state.deviceName)
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .padding(8)
                            .background(Color.b9xAccent.opacity(0.2))
                            .foregroundStyle(Color.b9xAccentLight)
                            .clipShape(Circle())
                    }
                }
                if scenes.isEmpty {
                    Text("还没有场景，点右上角 + 新建一个（比如“睡觉静音”“游戏极寒”）。")
                        .font(.subheadline)
                        .foregroundStyle(Color.b9xTextDim)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(scenes) { scene in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(scene.name)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                Text(scene.summary)
                                    .font(.caption)
                                    .foregroundStyle(Color.b9xTextDim)
                            }
                            Spacer()
                            Button("执行") {
                                runScene(scene)
                            }
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.b9xAccent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            Button {
                                editingScene = scene
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(Color.b9xTextDim)
                            }
                            Button(role: .destructive) {
                                scenes.removeAll { $0.id == scene.id }
                                SceneProfileStore.save(scenes)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func saveScene(_ scene: SceneProfile) {
        if let index = scenes.firstIndex(where: { $0.id == scene.id }) {
            scenes[index] = scene
        } else {
            scenes.append(scene)
        }
        SceneProfileStore.save(scenes)
        editingScene = nil
    }

    /// 执行场景：先判一圈失败原因，全部通过才下发；结果用人话报出来。
    private func runScene(_ scene: SceneProfile) {
        let trimmed = scene.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else {
            sceneResult = .invalidName
            showSceneResult = true
            return
        }
        guard scenes.contains(where: { $0.id == scene.id }) else {
            sceneResult = .notFound
            showSceneResult = true
            return
        }
        guard controller.isConnected else {
            sceneResult = .notConnected
            showSceneResult = true
            return
        }
        if !scene.deviceName.isEmpty, scene.deviceName != state.deviceName {
            sceneResult = .wrongDevice
            showSceneResult = true
            return
        }
        guard state.ready else {
            sceneResult = .staleState
            showSceneResult = true
            return
        }
        if state.freezeMode, !scene.freezeEnabled {
            // 设备正在超频，模式帧会被拒绝：先退超频再执行。
            sceneResult = .busy
            showSceneResult = true
            return
        }
        if scene.freezeEnabled {
            controller.setFreezeEnabled(true)
        }
        switch scene.mode {
        case B9XProtocol.modeSmart:
            controller.setTargetTemperature(scene.targetTemperature)
        case B9XProtocol.modeManual:
            controller.setRunMode(
                mode: B9XProtocol.modeManual,
                targetTemperature: scene.targetTemperature,
                windLevel: scene.windLevel,
                coldLevel: scene.coldLevel
            )
        case B9XProtocol.modeCustom:
            controller.setCustomCurve(scene.curveLevels)
        default:
            controller.setRunMode(mode: scene.mode, targetTemperature: scene.targetTemperature)
        }
        if scene.freezeEnabled {
            controller.setFreezeEnabled(true)
        }
        sceneResult = .applied
        showSceneResult = true
    }

    // ------------------------------------------------------------ 充电随动（细化）

    private var chargingRuleCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "bolt.circle.fill")
                        .foregroundStyle(Color.b9xAccentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("充电随动规则")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("插电后等一等再切模式；满电可关；拔电后按你的选择处理。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Text("插电后延迟")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(chargingConfig.delaySeconds) 秒")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(Color.b9xAccentLight)
                }
                Slider(value: Binding(
                    get: { Double(chargingConfig.delaySeconds) },
                    set: {
                        chargingConfig.delaySeconds = Int($0)
                        chargingConfig.save()
                    }
                ), in: 0...300, step: 10)
                .tint(.b9xAccent)
                Toggle("满电后退出超频", isOn: Binding(
                    get: { chargingConfig.fullChargeShutdown },
                    set: {
                        chargingConfig.fullChargeShutdown = $0
                        chargingConfig.save()
                    }
                ))
                .foregroundStyle(.primary)
                Text("注：当前构建没有独立的散热器关机指令，满电时只能先退出超频；完整“满电关机”待 Core 接入关机指令。")
                    .font(.caption)
                    .foregroundStyle(Color.b9xTextDim)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("拔电后")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    ForEach(UnplugPolicy.allCases) { policy in
                        Button {
                            chargingConfig.unplugPolicy = policy
                            chargingConfig.save()
                        } label: {
                            HStack {
                                Image(systemName: chargingConfig.unplugPolicy == policy
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chargingConfig.unplugPolicy == policy
                                                   ? Color.b9xAccentLight : Color.b9xTextDim)
                                Text(policy.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
                if let note = chargingNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 插电/拔电变化时的处理（App 在前台时生效；后台靠系统唤醒，不保证）。
    private func handleChargingChange(_ charging: Bool) {
        chargeTask?.cancel()
        chargeTask = nil
        guard controller.chargeFollowEnabled else { return }
        if charging {
            preChargeMode = state.runMode
            autoStartedByCharging = false
            let delay = chargingConfig.delaySeconds
            let mode = controller.chargeFollowMode
            chargeTask = Task { @MainActor in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                }
                guard !Task.isCancelled, controller.batteryCharging else { return }
                autoStartedByCharging = true
                applyChargeMode(mode)
                chargingNote = "已按充电随动切到\(CoolerController.modeName(mode))"
            }
        } else {
            // 拔电：按三选一处理。
            switch chargingConfig.unplugPolicy {
            case .restorePrevious:
                if let previous = preChargeMode {
                    applyChargeMode(previous)
                    chargingNote = "已拔电，恢复到接管前的模式"
                }
            case .keepCurrent:
                chargingNote = "已拔电，保持当前模式不变"
            case .closeAutoStartedOnly:
                if autoStartedByCharging {
                    if state.freezeMode { controller.setFreezeEnabled(false) }
                    if let previous = preChargeMode {
                        applyChargeMode(previous)
                    }
                    chargingNote = "已拔电，关闭了本次自动开启的散热"
                } else {
                    chargingNote = "已拔电，本次散热不是自动开启的，保持不变"
                }
            }
            autoStartedByCharging = false
            preChargeMode = nil
        }
    }

    private func handleFullCharge() {
        guard chargingConfig.fullChargeShutdown, state.freezeMode else { return }
        controller.setFreezeEnabled(false)
        chargingNote = "已满电，退出了超频（完整关机待 Core 接入关机指令）"
    }

    /// 充电随动切模式：超频档走 Freeze 开关（mode 2 的 0x20 帧已作废），其余走 setRunMode。
    private func applyChargeMode(_ mode: Int) {
        if mode == B9XProtocol.modeOverclock {
            controller.setFreezeEnabled(true)
        } else {
            controller.setRunMode(mode: mode, manual: false)
        }
    }

    // ------------------------------------------------------------ 定时关机

    private var timedShutdownCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "timer")
                        .foregroundStyle(Color.b9xAccentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("定时关机")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(state.timedShutdownRunning
                             ? "运行中，剩余约 \(state.timeCountdown / 60) 分钟"
                             : "硬件定时优先：时间到了设备自己关，App 不用一直开着。")
                            .font(.subheadline)
                            .foregroundStyle(Color.b9xTextDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Stepper("定时 \(shutdownMinutes) 分钟", value: $shutdownMinutes, in: 1...600, step: 5)
                    .foregroundStyle(.primary)
                Toggle("每天重复", isOn: $shutdownRepeat)
                    .foregroundStyle(.primary)
                HStack(spacing: 10) {
                    Button("开始定时") {
                        controller.setTimedShutdown(repeat: shutdownRepeat, enabled: true, minutes: shutdownMinutes)
                    }
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.b9xAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    Button("取消定时") {
                        controller.setTimedShutdown(repeat: false, enabled: false, minutes: 0)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.b9xCard2)
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

// ------------------------------------------------------------ 场景模型与执行结果

/// 场景：名称 ≤64 字、绑设备、设模式/档位/风扇/制冷/目标温度。
struct SceneProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var deviceName: String
    var mode: Int = B9XProtocol.modeSmart
    var targetTemperature: Int = 16
    var coldLevel: Int = 115
    var windLevel: Int = 4500
    var freezeEnabled: Bool = false
    var curveLevels: [Int] = B9XProtocol.defaultCurveLevels

    var summary: String {
        var parts: [String] = [CoolerController.modeName(mode)]
        if mode == B9XProtocol.modeSmart || mode == B9XProtocol.modeManual {
            parts.append("目标 \(targetTemperature)°C")
        }
        if mode == B9XProtocol.modeManual {
            parts.append("冷 \(coldLevel) · 风 \(windLevel)")
        }
        if freezeEnabled { parts.append("超频") }
        if !deviceName.isEmpty { parts.append(deviceName) }
        return parts.joined(separator: " · ")
    }
}

/// 场景本地保存（UserDefaults JSON）。
enum SceneProfileStore {
    static let defaultsKey = "enginecore.sceneProfiles.v1"

    static func load() -> [SceneProfile] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let scenes = try? JSONDecoder().decode([SceneProfile].self, from: data) else {
            return []
        }
        return scenes
    }

    static func save(_ scenes: [SceneProfile]) {
        if let data = try? JSONEncoder().encode(scenes) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// 场景执行结果（与原包 SceneResult 的 11 种对应，人话说明）。
enum SceneResult: Equatable {
    case applied
    case busy
    case coolerOff
    case disabled
    case interrupted
    case invalidName
    case notConnected
    case notFound
    case staleState
    case unconfirmed
    case unsupported
    case wrongDevice

    var message: String {
        switch self {
        case .applied: return "场景已执行，设备正在切换（以设备回显为准）。"
        case .busy: return "设备正忙：正在超频，模式切换被拦下了。先退出超频再执行场景。"
        case .coolerOff: return "散热器已关机，先开机再执行场景。"
        case .disabled: return "这个场景被停用了，先启用再执行。"
        case .interrupted: return "执行被打断了（连接断开或被其他操作抢占），请重试。"
        case .invalidName: return "场景名不对：不能为空，也不能超过 64 个字。"
        case .notConnected: return "设备未连接，先连上散热器再执行场景。"
        case .notFound: return "找不到这个场景，可能已被删除。"
        case .staleState: return "设备状态过期了：刚连上、还没收到第一帧状态，等一两秒再试。"
        case .unconfirmed: return "指令发出去了，但设备还没回确认，请看一眼设备状态再决定要不要重试。"
        case .unsupported: return "当前设备不支持这个场景里的设置。"
        case .wrongDevice: return "场景绑的是另一台设备，和当前连接的对不上。"
        }
    }
}

// ------------------------------------------------------------ 充电随动规则

/// 拔电后三选一（与原包 UnplugPolicy 对应）。
enum UnplugPolicy: String, Codable, CaseIterable, Identifiable {
    case restorePrevious
    case keepCurrent
    case closeAutoStartedOnly

    var id: String { rawValue }

    var description: String {
        switch self {
        case .restorePrevious: return "恢复接管前的状态"
        case .keepCurrent: return "保持当前状态"
        case .closeAutoStartedOnly: return "仅关闭本次自动开启的散热器"
        }
    }
}

struct ChargingRuleConfig: Codable, Equatable {
    var delaySeconds: Int = 0
    var fullChargeShutdown: Bool = false
    var unplugPolicy: UnplugPolicy = .restorePrevious

    static let defaultsKey = "enginecore.chargingRule.v1"

    static func load() -> ChargingRuleConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(ChargingRuleConfig.self, from: data) else {
            return ChargingRuleConfig()
        }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// ------------------------------------------------------------ 场景编辑器

struct SceneEditorView: View {
    @State var scene: SceneProfile
    var isNew: Bool = false
    var onSave: (SceneProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("场景名（≤64 字）", text: $scene.name)
                    .onChange(of: scene.name) { _, newValue in
                        if newValue.count > 64 { scene.name = String(newValue.prefix(64)) }
                    }
                TextField("绑定设备（留空表示任意设备）", text: $scene.deviceName)
                if scene.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("场景名不能为空。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("模式") {
                Picker("模式", selection: $scene.mode) {
                    Text("智能温控").tag(B9XProtocol.modeSmart)
                    Text("手动").tag(B9XProtocol.modeManual)
                    Text("自定义曲线").tag(B9XProtocol.modeCustom)
                }
                .pickerStyle(.segmented)
                if scene.mode == B9XProtocol.modeSmart || scene.mode == B9XProtocol.modeManual {
                    Stepper("目标温度 \(scene.targetTemperature)°C", value: $scene.targetTemperature, in: -20...16)
                }
                if scene.mode == B9XProtocol.modeManual {
                    Stepper("制冷档位 \(scene.coldLevel)", value: $scene.coldLevel, in: 0...B9XProtocol.maxColdLevel, step: 5)
                    Stepper("风扇档位 \(scene.windLevel)", value: $scene.windLevel, in: B9XProtocol.minWindLevel...B9XProtocol.maxWindLevel, step: 100)
                }
                if scene.mode == B9XProtocol.modeCustom {
                    Text("自定义曲线用设备页里保存的九点曲线。")
                        .font(.caption)
                        .foregroundStyle(Color.b9xTextDim)
                }
                Toggle("同时开启超频", isOn: $scene.freezeEnabled)
            }
        }
        .navigationTitle(isNew ? "新建场景" : "编辑场景")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    onSave(scene)
                    dismiss()
                }
                .disabled(scene.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
