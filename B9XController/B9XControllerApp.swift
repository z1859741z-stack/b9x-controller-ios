import SwiftUI

@main
struct B9XControllerApp: App {
    @StateObject private var controller = CoolerController.shared
    @StateObject private var appearance = AppearanceSettings.shared

    /// 首启法律门状态：检查中 / 待确认 / 暂不同意 / 已确认。
    /// 只有已确认才挂 ContentView（才调 controller.bootstrap() 启动蓝牙连接）；
    /// 暂不同意时不启动设备连接。
    @State private var legalState: LegalGateState = .checking

    private enum LegalGateState {
        case checking
        case needsConsent
        case declined
        case accepted
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch legalState {
                case .checking:
                    Color.b9xBackground.ignoresSafeArea()
                case .needsConsent:
                    LegalConsentView(
                        onAccept: {
                            LegalConsentStore.recordAcceptance()
                            legalState = .accepted
                        },
                        onDecline: {
                            legalState = .declined
                        }
                    )
                case .declined:
                    LegalDeclinedView {
                        legalState = .needsConsent
                    }
                case .accepted:
                    ContentView()
                        .environmentObject(controller)
                }
            }
            .environmentObject(appearance)
            .onAppear {
                // 条款版本变化时重新提示：存的版本 ≠ 当前版本就回到待确认。
                legalState = LegalConsentStore.isAccepted ? .accepted : .needsConsent
            }
        }
    }
}
