import SwiftUI

/// CI 截图巡游驱动（仅当启动参数含 -UITour 时激活）：
/// App 按节拍切模式/tab，工作流用 simctl 每步截屏，助手自己看图核对界面。
/// 只改 UI 本地展示状态（localMode / tab / 法律页开关），不发任何 BLE 帧，
/// 不改持久状态；真机用户永远进不来（无启动参数时 isTouring 为 false）。
///
/// 驱动方式：GCD asyncAfter 链，1.6 秒一步。
/// 前两版都翻车：Timer.scheduledTimer 在模拟器里不推进（run 43995047613
/// 全是初始状态）；SwiftUI .task + Task.sleep 一取消就瞬间跑完 9 步
/// （run 43996666258 首张截图角标已是 9/9）。asyncAfter 不受任务取消
/// 影响，start() 用 started 只启动一次，防重复链。
final class TourDriver: ObservableObject {
    static let shared = TourDriver()

    /// 总步数：0 智能 / 1 固定 / 2 自由 / 3 电池 / 4 目标 / 5 超频 /
    /// 6 自动化 tab / 7 我的 tab / 8 关于页法律 / 9 回首页。
    static let lastStep = 9
    static let stepInterval: TimeInterval = 1.6

    @Published private(set) var step = 0

    var isTouring: Bool { CommandLine.arguments.contains("-UITour") }

    private var started = false

    func start() {
        guard isTouring, !started else { return }
        started = true
        scheduleNext()
    }

    private func scheduleNext() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stepInterval) { [weak self] in
            guard let self, step < Self.lastStep else { return }
            step += 1
            scheduleNext()
        }
    }
}
