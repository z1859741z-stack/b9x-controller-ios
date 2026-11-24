import SwiftUI

/// CI 截图巡游驱动（仅当启动参数含 -UITour 时激活）：
/// App 按节拍切模式/tab，工作流用 simctl 每步截屏，助手自己看图核对界面。
/// 只改 UI 本地展示状态（localMode / tab / 法律页开关），不发任何 BLE 帧，
/// 不改持久状态；真机用户永远进不来（无启动参数时 isTouring 为 false）。
///
/// 两种驱动：
/// 1. 固定步数（CI 用）：启动参数 -UITourStep N，直接跳到第 N 步，不跑
///    计时链。用来绕开 simctl launch 在冷模拟器上十几秒才返回、计时巡游
///    在截图前就跑完的问题——Timer / .task / GCD 三版全栽在这上面
///    （三个 run 的首张截图角标都是 9/9）。
/// 2. 计时链（手动跑 -UITour 时）：GCD asyncAfter，1.6 秒一步。
final class TourDriver: ObservableObject {
    static let shared = TourDriver()

    /// 总步数：0 智能 / 1 固定 / 2 自由 / 3 电池 / 4 目标 / 5 超频 /
    /// 6 自动化 tab / 7 我的 tab / 8 关于页法律 / 9 回首页 / 10 我的 tab 滚到底 /
    /// 11 实验室风险提示 / 12 实验室结果表预览。
    static let lastStep = 12
    static let stepInterval: TimeInterval = 1.6

    @Published private(set) var step = 0

    var isTouring: Bool { CommandLine.arguments.contains("-UITour") }

    /// 固定步数：-UITourStep N（CI 每步单独启动一次）。
    var fixedStep: Int? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-UITourStep"),
              i + 1 < args.count,
              let n = Int(args[i + 1]),
              (0...Self.lastStep).contains(n) else { return nil }
        return n
    }

    private var started = false

    func start() {
        guard isTouring, !started else { return }
        started = true
        if let n = fixedStep {
            // 等页面挂载完再设步数，各页的 onChange 才能收到变化。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.step = n
            }
        } else {
            scheduleNext()
        }
    }

    private func scheduleNext() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stepInterval) { [weak self] in
            guard let self, step < Self.lastStep else { return }
            step += 1
            scheduleNext()
        }
    }
}
