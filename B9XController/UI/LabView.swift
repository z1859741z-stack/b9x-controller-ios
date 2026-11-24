import SwiftUI

/// 实验室 › 风量上限测试（隐藏入口：我的页连点 5 次版本号，进前弹风险提示）。
///
/// 背景：Freeze 只发 [0x26,1,0,0]、固件 100% 占空比，实测约 6000 转封顶；
/// 0x20 帧带 coldOC/windOC，官方最高只发 5700/175。这里逐档发更高 windOC，
/// 看固件会不会真提速。转速只显示固件上报的真实值（state.speed），绝不伪造。
/// 全程只在真机上跑；模拟器/演示模式拒绝开始。
@MainActor
final class LabRunner: ObservableObject {

    // ------------------------------------------------------------ 常量（任务书原样）

    /// 基准 Freeze 采样时长。
    private static let baselineSeconds = 20
    /// 每档阶梯采样时长。
    private static let rungSeconds = 15
    /// 阶梯 A 的 windOC 档位。
    private static let ladderWindOCs = [5800, 6000, 6200, 6500]
    /// 阶梯帧固定参数：mode 3（专家）、cold 175、wind 5700、coldOC 175。
    private static let ladderCold = 175
    private static let ladderWind = 5700
    private static let ladderColdOC = 175
    /// 连续两档提升不到这个数即判被固件夹住。
    private static let clampGainThreshold = 100
    /// 热面相对阶段起点上升超过这个数立即中止。
    private static let hotRiseLimit = 8
    /// 无回包超过这个秒数立即中止。
    private static let stalePacketSeconds: TimeInterval = 5
    /// Freeze 进入/退出确认超时。
    private static let freezeConfirmTimeout: TimeInterval = 6

    // ------------------------------------------------------------ 类型

    struct Sample {
        let speed: Int
        let cold: Double
        let hot: Int
    }

    enum Kind {
        case baseline
        case ladderA
        case ladderB
    }

    struct PhaseResult: Identifiable {
        let id = UUID()
        let kind: Kind
        let name: String
        let windOC: Int?
        let samples: [Sample]

        var avgSpeed: Int {
            guard !samples.isEmpty else { return 0 }
            return samples.map(\.speed).reduce(0, +) / samples.count
        }
        var maxSpeed: Int { samples.map(\.speed).max() ?? 0 }
        var avgCold: Double {
            guard !samples.isEmpty else { return 0 }
            return samples.map(\.cold).reduce(0, +) / Double(samples.count)
        }
        var avgHot: Double {
            guard !samples.isEmpty else { return 0 }
            return Double(samples.map(\.hot).reduce(0, +)) / Double(samples.count)
        }
    }

    enum Phase: Equatable {
        case idle
        case exitingFreeze
        case baselineFreeze
        case ladderA(rung: Int)
        case ladderB
        case restoring
        case done
        case aborted

        var displayName: String {
            switch self {
            case .idle: return "未开始"
            case .exitingFreeze: return "正在退出超频…"
            case .baselineFreeze: return "基准：Freeze 采样中"
            case .ladderA(let rung): return "阶梯 A：第 \(rung + 1)/\(LabRunner.ladderWindOCs.count) 档"
            case .ladderB: return "阶梯 B：最佳档 + Freeze"
            case .restoring: return "正在恢复原模式…"
            case .done: return "测试完成"
            case .aborted: return "已中止"
            }
        }
    }

    // ------------------------------------------------------------ 发布状态

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var elapsedInPhase = 0
    @Published private(set) var currentSpeed = 0
    @Published private(set) var currentCold = 0.0
    @Published private(set) var currentHot = 0
    @Published private(set) var currentWindOC: Int?
    @Published private(set) var results: [PhaseResult] = []
    @Published private(set) var conclusion: String?
    @Published private(set) var abortReason: String?
    @Published private(set) var statusMessage: String?

    // ------------------------------------------------------------ 内部状态

    private let controller: CoolerController
    private var runTask: Task<Void, Never>?
    private var sampleTimer: Timer?
    private var sampling = false
    private var currentSamples: [Sample] = []
    private var currentKind: Kind = .baseline
    private var currentName = ""
    private var currentWindOCValue: Int?
    private var phaseHotStart: Int?
    private var original: OriginalMode?

    private struct OriginalMode {
        let runMode: Int
        let smartPreset: Int
        let manualPreset: Int
        let targetTemperature: Int
        let softwareThermalMode: Int
        let customLevels: [Int]
        let coldLevel: Int
        let windLevel: Int
        let coldOC: Int
        let windOC: Int
        let freezeWasOn: Bool
    }

    init(controller: CoolerController) {
        self.controller = controller
    }

    deinit {
        sampleTimer?.invalidate()
        runTask?.cancel()
    }

    // ------------------------------------------------------------ 入口

    func start() {
        guard !isRunning else { return }
        guard controller.isConnected, controller.state.ready else {
            statusMessage = "设备未连接或未就绪，先连上 B9X 再测。"
            return
        }
        // 演示模式下不能测试（红线测试 -UILabTest 除外：它就是跑在演示态上的假数据验证）。
        guard !controller.demoMode || LabTestDriver.isEnabled else {
            statusMessage = "演示模式下不能测试，请连真机。"
            return
        }
        statusMessage = nil
        abortReason = nil
        results = []
        conclusion = nil
        currentWindOC = nil
        recordOriginal()
        isRunning = true
        phase = .idle
        runTask = Task { [weak self] in
            await self?.runSequence()
        }
    }

    func stop() {
        guard isRunning else { return }
        abort("用户手动停止")
    }

    private func abort(_ reason: String) {
        if abortReason == nil { abortReason = reason }
        runTask?.cancel()
    }

    // ------------------------------------------------------------ 主流程

    private func runSequence() async {
        defer { finish() }
        // 1. 前置：已在 Freeze 就先退出，等确认。
        if controller.state.freezeMode {
            phase = .exitingFreeze
            controller.setFreezeEnabled(false)
            let ok = await waitFor({ !self.controller.state.freezeMode },
                                   timeout: Self.freezeConfirmTimeout)
            // 采样器红线已中止时任务会被取消：真正的中止原因已由采样器记下，别覆盖。
            if !ok { if Task.isCancelled { return }; abortReason = "退出超频未确认"; return }
        }
        // 2. 开 1 秒采样器（每秒发一次 0x13 轮询 + 记一笔 + 查红线）。
        startSampler()
        // 3. 基准：Freeze 20 秒。
        phase = .baselineFreeze
        beginPhase(kind: .baseline, name: "基准 Freeze", windOC: nil)
        controller.setFreezeEnabled(true)
        guard await waitFor({ self.controller.state.freezeMode },
                            timeout: Self.freezeConfirmTimeout) else {
            if Task.isCancelled { return }
            abortReason = "进入超频未确认"; return
        }
        await sampleFor(seconds: Self.baselineSeconds)
        controller.setFreezeEnabled(false)
        guard await waitFor({ !self.controller.state.freezeMode },
                            timeout: Self.freezeConfirmTimeout) else {
            if Task.isCancelled { return }
            abortReason = "退出超频未确认"; return
        }
        endPhase()
        if Task.isCancelled { return }
        // 4. 阶梯 A：mode 3 帧，windOC 逐档 5800/6000/6200/6500，各稳 15 秒。
        var prevAvg: Int?
        var smallGainStreak = 0
        var clamped = false
        for (index, windOC) in Self.ladderWindOCs.enumerated() {
            phase = .ladderA(rung: index)
            currentWindOC = windOC
            beginPhase(kind: .ladderA, name: "阶梯 A · windOC \(windOC)", windOC: windOC)
            sendLadderFrame(windOC: windOC)
            await sampleFor(seconds: Self.rungSeconds)
            let result = endPhase()
            if Task.isCancelled { return }
            guard let avg = result?.avgSpeed else { continue }
            if let prev = prevAvg {
                if avg < prev { abortReason = "转速不升反降"; return }
                if avg - prev < Self.clampGainThreshold {
                    smallGainStreak += 1
                    if smallGainStreak >= 2 { clamped = true; break }
                } else {
                    smallGainStreak = 0
                }
            }
            prevAvg = avg
        }
        currentWindOC = nil
        if Task.isCancelled { return }
        // 5. 阶梯 B：A 里最好的 windOC 发帧后再开 Freeze，看叠加是否更高。
        // 被夹住就不用再试 B。
        if !clamped,
           let best = results.filter({ $0.kind == .ladderA }).max(by: { $0.avgSpeed < $1.avgSpeed }),
           let bestOC = best.windOC {
            phase = .ladderB
            beginPhase(kind: .ladderB, name: "阶梯 B · windOC \(bestOC) + Freeze", windOC: bestOC)
            sendLadderFrame(windOC: bestOC)
            controller.setFreezeEnabled(true)
            guard await waitFor({ self.controller.state.freezeMode },
                                timeout: Self.freezeConfirmTimeout) else {
                if Task.isCancelled { return }
                abortReason = "进入超频未确认"; return
            }
            await sampleFor(seconds: Self.rungSeconds)
            controller.setFreezeEnabled(false)
            guard await waitFor({ !self.controller.state.freezeMode },
                                timeout: Self.freezeConfirmTimeout) else {
                if Task.isCancelled { return }
                abortReason = "退出超频未确认"; return
            }
            endPhase()
            if Task.isCancelled { return }
        }
        // 6. 结论。
        buildConclusion(clamped: clamped)
    }

    private func sendLadderFrame(windOC: Int) {
        controller.setRunMode(
            mode: B9XProtocol.modeExperimentalSmart,
            targetTemperature: 0,
            windLevel: Self.ladderWind,
            coldLevel: Self.ladderCold,
            windLevelOverclock: windOC,
            coldLevelOverclock: Self.ladderColdOC
        )
    }

    // ------------------------------------------------------------ 采样器（1 秒一跳）

    private func startSampler() {
        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleTick() }
        }
    }

    private func stopSampler() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        sampling = false
    }

    private func sampleTick() {
        guard isRunning else { return }
        controller.requestRealtimeState()
        let s = controller.state
        currentSpeed = s.speed
        currentCold = s.temperatureValue
        currentHot = s.hotSurfaceTemperature
        elapsedInPhase += 1
        // 红线（任一立即中止并恢复原模式）。
        if !controller.isConnected { abort("设备已断开"); return }
        if s.hotProtectionEnabled { abort("高温保护已置位"); return }
        if let hotStart = phaseHotStart, s.hotSurfaceTemperature > hotStart + Self.hotRiseLimit {
            abort("热面上升超过 8°C"); return
        }
        if let last = s.lastStateAt, Date().timeIntervalSince(last) > Self.stalePacketSeconds {
            abort("设备无回包超过 5 秒"); return
        }
        if sampling {
            currentSamples.append(Sample(speed: s.speed, cold: s.temperatureValue, hot: s.hotSurfaceTemperature))
        }
    }

    // ------------------------------------------------------------ 阶段记账

    private func beginPhase(kind: Kind, name: String, windOC: Int?) {
        currentKind = kind
        currentName = name
        currentWindOCValue = windOC
        currentSamples = []
        phaseHotStart = controller.state.hotSurfaceTemperature
        elapsedInPhase = 0
        sampling = true
    }

    @discardableResult
    private func endPhase() -> PhaseResult? {
        sampling = false
        guard !currentSamples.isEmpty else { return nil }
        let result = PhaseResult(kind: currentKind, name: currentName,
                                 windOC: currentWindOCValue, samples: currentSamples)
        results.append(result)
        return result
    }

    private func sampleFor(seconds: Int) async {
        for _ in 0..<seconds {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return condition()
    }

    // ------------------------------------------------------------ 恢复与收尾

    private func recordOriginal() {
        let s = controller.state
        original = OriginalMode(
            runMode: s.runMode,
            smartPreset: s.smartPreset,
            manualPreset: s.manualPreset,
            targetTemperature: s.targetTemperature,
            softwareThermalMode: s.softwareThermalMode,
            customLevels: s.customLevels,
            coldLevel: s.coldLevel,
            windLevel: s.windLevel,
            coldOC: s.coldLevelOverclock,
            windOC: s.windLevelOverclock,
            freezeWasOn: s.freezeMode
        )
    }

    private func restoreOriginalMode() async {
        guard let o = original else { return }
        // 先确保 Freeze 已退出（测完不自动恢复测试前的 Freeze，见结论备注）。
        if controller.state.freezeMode {
            controller.setFreezeEnabled(false)
            _ = await waitFor({ !self.controller.state.freezeMode }, timeout: 4)
        }
        switch o.softwareThermalMode {
        case B9XProtocol.thermalModeBattery, B9XProtocol.thermalModeCoolerTarget:
            controller.setSoftwareThermalMode(o.softwareThermalMode)
        default:
            switch o.runMode {
            case B9XProtocol.modeCustom:
                controller.setCustomCurve(o.customLevels)
            case B9XProtocol.modeManual:
                controller.setManualPreset(o.manualPreset)
            case B9XProtocol.modeExperimentalSmart:
                controller.setRunMode(
                    mode: B9XProtocol.modeExperimentalSmart,
                    targetTemperature: o.targetTemperature,
                    windLevel: o.windLevel,
                    coldLevel: o.coldLevel,
                    windLevelOverclock: o.windOC,
                    coldLevelOverclock: o.coldOC
                )
            default:
                controller.setSmartPreset(o.smartPreset)
            }
        }
    }

    private func finish() {
        stopSampler()
        phase = .restoring
        // 恢复是异步的：另起任务做，界面先标完成/中止。
        Task { [weak self] in
            guard let self else { return }
            await self.restoreOriginalMode()
            self.phase = self.abortReason == nil ? .done : .aborted
            self.isRunning = false
        }
    }

    // ------------------------------------------------------------ 结论与导出

    /// CI 巡游预览：给结果表填固定示例数据，只验渲染（仅 -UITour 时调用，
    /// 真机永远进不来）。示例转速是写死的演示数字，不是固件上报；
    /// 正式测试的结果一律来自 state.speed（固件上报的真实值）。
    func previewResults() {
        guard results.isEmpty else { return }
        results = [
            PhaseResult(kind: .baseline, name: "基准 Freeze", windOC: nil, samples: [
                Sample(speed: 5980, cold: -8.2, hot: 41),
                Sample(speed: 6010, cold: -8.6, hot: 42),
            ]),
            PhaseResult(kind: .ladderA, name: "阶梯 A · windOC 6000", windOC: 6000, samples: [
                Sample(speed: 5990, cold: -8.4, hot: 42),
                Sample(speed: 6020, cold: -8.8, hot: 43),
            ]),
        ]
        conclusion = "巡游预览：示例数据，仅验结果表渲染。"
        phase = .done
    }

    private func buildConclusion(clamped: Bool) {
        guard let baseline = results.first(where: { $0.kind == .baseline }) else {
            conclusion = "没有可用数据。"
            return
        }
        let rungs = results.filter { $0.kind == .ladderA }
        let bestA = rungs.max(by: { $0.avgSpeed < $1.avgSpeed })
        let b = results.first(where: { $0.kind == .ladderB })
        var lines: [String] = []
        if let b, let bestOC = b.windOC, b.avgSpeed > baseline.avgSpeed + Self.clampGainThreshold {
            lines.append("真提速：windOC \(bestOC) + Freeze 平均 \(b.avgSpeed) 转，比 Freeze 基准（\(baseline.avgSpeed) 转）高 \(b.avgSpeed - baseline.avgSpeed) 转。建议把超频入口做成可选「增强超频」。")
        } else if let bestA, let bestOC = bestA.windOC,
                  bestA.avgSpeed > baseline.avgSpeed + Self.clampGainThreshold {
            lines.append("真提速：windOC \(bestOC) 平均 \(bestA.avgSpeed) 转，比 Freeze 基准（\(baseline.avgSpeed) 转）高 \(bestA.avgSpeed - baseline.avgSpeed) 转。建议把超频入口做成可选「增强超频」。")
        } else if clamped {
            lines.append("连续两档提升不到 100 转，固件把风量夹住了——6000 是硬件上限，不用再试更高 windOC。")
        } else {
            lines.append("没测出提速：最高档平均 \(bestA?.avgSpeed ?? 0) 转，和 Freeze 基准（\(baseline.avgSpeed) 转）基本持平，6000 是硬件上限。")
        }
        if original?.freezeWasOn == true {
            lines.append("测试前超频是开着的，测完没有自动恢复，可在首页手动再开。")
        }
        conclusion = lines.joined(separator: "\n")
    }

    var exportText: String {
        var lines: [String] = []
        lines.append("B9X 风量上限测试（实验室）")
        lines.append("时间：\(DateFormatter.labDate.string(from: Date()))")
        lines.append("设备：\(controller.state.deviceName)")
        lines.append("")
        for r in results {
            let oc = r.windOC.map { " · windOC \($0)" } ?? ""
            lines.append("\(r.name)\(oc)：平均 \(r.avgSpeed) 转 / 最高 \(r.maxSpeed) 转 / 冷面 \(String(format: "%.1f", r.avgCold))° / 热面 \(String(format: "%.1f", r.avgHot))°（\(r.samples.count) 个采样）")
        }
        if let abortReason {
            lines.append("")
            lines.append("中止原因：\(abortReason)")
        }
        if let conclusion {
            lines.append("")
            lines.append("结论：\(conclusion)")
        }
        lines.append("")
        lines.append("转速为固件上报的真实值；转速环满刻度 6000，超过显示真实数字。")
        return lines.joined(separator: "\n")
    }
}

private extension DateFormatter {
    static let labDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

// ------------------------------------------------------------ 界面

/// 实验室页：隐藏入口进来的风量上限测试。
struct LabView: View {
    @EnvironmentObject private var controller: CoolerController
    @StateObject private var runner: LabRunner

    init() {
        // CoolerController.shared 就是 App 注入 environment 的同一个实例。
        _runner = StateObject(wrappedValue: LabRunner(controller: CoolerController.shared))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                introCard
                if runner.isRunning {
                    runningCard
                } else if !runner.results.isEmpty || runner.phase == .done || runner.phase == .aborted {
                    resultsCard
                } else {
                    startCard
                }
                if let status = runner.statusMessage {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .contentMargins(.bottom, 16, for: .scrollContent)
        .topScrollEdgeEffect()
        .navigationTitle("实验室")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 红线测试（-UILabTest）优先：不种预览数据，直接跑真流程（假数据注入）。
            if LabTestDriver.isEnabled {
                LabTestDriver.shared.start(runner: runner, controller: controller)
            } else if TourDriver.shared.isTouring && TourDriver.shared.step == 12 {
                // CI 巡游第 12 步：只验结果表渲染，用固定示例数据（-UITour 时才进）。
                runner.previewResults()
            }
        }
    }

    // ------------------------------------------------------------ 说明卡

    private var introCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("风量上限测试")
                    .font(.headline)
                Text("Freeze 实测约 6000 转封顶；这里逐档发更高的 windOC（5800 / 6000 / 6200 / 6500），看固件会不会真提速。转速只显示固件上报的真实值。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("测前请用足功率 PD 电源供电，并清理风扇灰尘。热面上升过快、高温保护触发或断连时会自动中止，测完恢复你原来的模式。")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
    }

    // ------------------------------------------------------------ 开始卡

    private var startCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                Text("前置条件：已连接且 READY，不在超频中（在的话先退出，等确认后再开始）。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("开始测试") {
                    runner.start()
                }
                .buttonStyle(.glass)
                .disabled(!controller.isConnected || !controller.state.ready || controller.demoMode)
                if !controller.isConnected || !controller.state.ready {
                    Text("设备未连接或未就绪。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if controller.demoMode {
                    Text("演示模式下不能测试。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // ------------------------------------------------------------ 进行中卡

    private var runningCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                Text(runner.phase.displayName)
                    .font(.headline)
                HStack(spacing: 24) {
                    VStack {
                        Text("\(runner.currentSpeed)")
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("转速 RPM（满刻度 6000）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("冷面 \(String(format: "%.1f", runner.currentCold))°")
                        Text("热面 \(runner.currentHot)°")
                        Text("已采样 \(runner.elapsedInPhase) 秒")
                    }
                    .font(.subheadline)
                }
                if let windOC = runner.currentWindOC {
                    Text("当前 windOC \(windOC)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("停止", role: .destructive) {
                    runner.stop()
                }
                .buttonStyle(.glass)
            }
        }
    }

    // ------------------------------------------------------------ 结果卡

    private var resultsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(runner.phase == .aborted ? "测试已中止" : "测试结果")
                    .font(.headline)
                if let reason = runner.abortReason {
                    Text("中止原因：\(reason)")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                ForEach(runner.results) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name)
                            .font(.subheadline.bold())
                        Text("平均 \(r.avgSpeed) 转 · 最高 \(r.maxSpeed) 转 · 冷面 \(String(format: "%.1f", r.avgCold))° · 热面 \(String(format: "%.1f", r.avgHot))°")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                }
                if let conclusion = runner.conclusion {
                    Text(conclusion)
                        .font(.subheadline)
                }
                HStack {
                    ShareLink(item: runner.exportText) {
                        Label("导出结果文本", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button("再测一次") {
                        runner.start()
                    }
                    .buttonStyle(.glass)
                    .disabled(runner.isRunning)
                }
            }
        }
    }
}
