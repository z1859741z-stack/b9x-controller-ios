import XCTest

/// 模拟器截图巡游：点遍散热模式各按钮、切遍三个 tab、打开关于页，
/// 每步截屏（供 CI 产物人工核对界面/尺寸/玻璃效果）。
/// 模拟器无真机，只能看界面，不能验证真机控制。
final class UITourTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTour() {
        // 开屏法律页：点同意（文案可能微调，按“同意”模糊找）。
        let agree = app.buttons.matching(NSPredicate(format: "label CONTAINS '同意'")).firstMatch
        if agree.waitForExistence(timeout: 8) {
            agree.tap()
            sleep(1)
        }
        shot("01-home")

        // 散热模式逐个点（超频会弹二次确认，点取消）。
        for mode in ["smart", "manual", "free", "battery", "target"] {
            let button = app.buttons["mode.\(mode)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "缺少模式按钮 mode.\(mode)")
            button.tap()
            sleep(1)
            shot("02-mode-\(mode)")
        }
        let overclock = app.buttons["mode.overclock"]
        XCTAssertTrue(overclock.waitForExistence(timeout: 5), "缺少模式按钮 mode.overclock")
        overclock.tap()
        sleep(1)
        let cancel = app.alerts.buttons["取消"]
        if cancel.waitForExistence(timeout: 3) { cancel.tap() }
        shot("02-mode-overclock-alert-dismissed")

        // 三个 tab。
        XCTAssertTrue(app.buttons["tab.automation"].waitForExistence(timeout: 5), "缺少 tab.automation")
        app.buttons["tab.automation"].tap()
        sleep(1)
        shot("03-tab-automation")
        app.buttons["tab.my"].tap()
        sleep(1)
        shot("04-tab-my")

        // 关于页：点“用户协议与免责声明”行（找不到也不失败，只截我的页）。
        let legal = app.buttons.matching(NSPredicate(format: "label CONTAINS '用户协议'")).firstMatch
        if legal.waitForExistence(timeout: 3) {
            legal.tap()
            sleep(1)
            shot("05-legal")
            let back = app.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 3) { back.tap() }
            sleep(1)
        }

        // 回首页收尾。
        app.buttons["tab.home"].tap()
        sleep(1)
        shot("06-back-home")
    }
}
