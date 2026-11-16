import AppIntents

/// 快捷指令替代方案：原版安卓的“游戏检测自动联动”在 iOS 上做不到
/// （系统不允许读取其他 App 状态），改用 App Intents——用户可以在
/// “快捷指令”里建自动化，例如“打开王者荣耀时 → 设置散热器模式为超频”。
enum CoolerModeOption: String, AppEnum {
    case smart
    case manual
    case overclock
    case custom

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "散热器模式")
    }

    static var caseDisplayRepresentations: [CoolerModeOption: DisplayRepresentation] {
        [
            .smart: DisplayRepresentation(title: "智能温控"),
            .manual: DisplayRepresentation(title: "手动"),
            .overclock: DisplayRepresentation(title: "超频"),
            .custom: DisplayRepresentation(title: "自定义曲线"),
        ]
    }
}

struct SetCoolerModeIntent: AppIntent {
    static var title: LocalizedStringResource = "设置散热器模式"
    static var description = IntentDescription("把飞智散热器切换到指定运行模式。需要先连接过设备（会自动重连上次的设备）。")

    // 打开 App 执行：后台进程里的蓝牙连接不可靠，打开 App 最稳。
    static var openAppWhenRun = true

    @Parameter(title: "模式", default: .smart)
    var mode: CoolerModeOption

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            let controller = CoolerController.shared
            switch mode {
            case .smart:
                controller.setRunMode(mode: B9XProtocol.modeSmart)
            case .manual:
                controller.setManual()
            case .overclock:
                controller.setOverclock()
            case .custom:
                controller.setCustomCurve(controller.state.customLevels)
            }
        }
        return .result()
    }
}

struct B9XShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetCoolerModeIntent(),
            phrases: ["用${applicationName}给散热器超频", "用${applicationName}把散热器调到超频", "用${applicationName}打开散热器"]
        )
    }
}
