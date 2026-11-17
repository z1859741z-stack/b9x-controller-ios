import Foundation
import Combine

/// 模拟器截图巡游驱动：只在启动参数含 -UITour 时激活（CI 截图用）。
/// 按节拍推进步骤，各页面跟随步骤切换本地选中态 / tab；不发任何 BLE 帧，
/// 不改任何持久状态，真机用户永远不会触发。
final class TourDriver: ObservableObject {
    static let shared = TourDriver()

    /// 步骤：0 智能 / 1 固定 / 2 自由 / 3 电池 / 4 目标 / 5 超频 /
    /// 6 自动化 tab / 7 我的 tab / 8 关于页（法律）/ 9 回首页。
    static let lastStep = 9

    @Published private(set) var step = 0
    var isTouring: Bool { CommandLine.arguments.contains("-UITour") }

    private var timer: Timer?

    func start() {
        guard isTouring, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            if step < Self.lastStep {
                step += 1
            } else {
                timer?.invalidate()
                timer = nil
            }
        }
    }
}
