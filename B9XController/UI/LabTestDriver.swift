import SwiftUI

/// 实验室红线测试驱动（仅启动参数含 -UILabTest <场景> 时激活）：
/// 在模拟器里用假数据跑 LabRunner 的四种中止逻辑：
/// hotprotect（高温保护位置位）、hotrise（热面连续上升超 8°C）、
/// rpmfall（转速不升反降）、disconnect（断连）。
/// 只改 demo 状态，不发任何 BLE 帧；真机用户永远进不来（无启动参数时 isEnabled 为 false）。
@MainActor
final class LabTestDriver: ObservableObject {
    static let shared = LabTestDriver()

    static var isEnabled: Bool { scenario != nil }

    static var scenario: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-UILabTest"), i + 1 < args.count else { return nil }
        let s = args[i + 1]
        return ["hotprotect", "hotrise", "rpmfall", "disconnect"].contains(s) ? s : nil
    }

    private var timer: Timer?
    private var ticks = 0
    private var baselineTicks = 0
    private var baseHot: Int?
    private weak var runner: LabRunner?
    private weak var controller: CoolerController?

    func start(runner: LabRunner, controller: CoolerController) {
        guard Self.isEnabled, timer == nil else { return }
        self.runner = runner
        self.controller = controller
        // 先进演示模式（模拟器里默认未连接），再清掉演示态自带的高温保护位，
        // 喂一组干净的基准假数据，然后开跑。
        if !controller.demoMode { controller.enterDemo() }
        controller.labTestInject(speed: 5900, hot: 38, hotProtection: false)
        runner.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        guard let runner, let controller, let scenario = Self.scenario else { stop(); return }
        if runner.phase == .done || runner.phase == .aborted { stop(); return }
        ticks += 1
        if ticks > 120 { stop(); return }  // 兜底：2 分钟还没中止就停，不无限喂。
        switch scenario {
        case "hotprotect":
            // 采样开始后再置位，证明中止是注入触发的，不是演示态默认值。
            if runner.phase == .baselineFreeze, ticks >= 3 {
                controller.labTestInject(hotProtection: true)
            } else {
                controller.labTestInject(speed: 5900, hot: 38)
            }
        case "hotrise":
            // 从基准开始每秒 +2°C，5 秒后超 8°C 触发中止。
            if runner.phase == .baselineFreeze {
                if baseHot == nil { baseHot = controller.state.hotSurfaceTemperature }
                baselineTicks += 1
                controller.labTestInject(speed: 5900, hot: (baseHot ?? 38) + 2 * baselineTicks)
            } else {
                controller.labTestInject(speed: 5900, hot: 38)
            }
        case "rpmfall":
            // 第 0 档 6000、第 1 档 5500：第二档平均转速低于第一档，触发“转速不升反降”。
            if case let .ladderA(rung) = runner.phase {
                controller.labTestInject(speed: rung == 0 ? 6000 : 5500, hot: 39)
            } else {
                controller.labTestInject(speed: 5900, hot: 38)
            }
        case "disconnect":
            // 采样开始后退出演示模式（模拟器里无 BLE，isConnected 立即变 false）。
            if runner.phase == .baselineFreeze, ticks >= 3 {
                controller.demoMode = false
            } else {
                controller.labTestInject(speed: 5900, hot: 38)
            }
        default:
            break
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
