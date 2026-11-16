import SwiftUI

@main
struct B9XControllerApp: App {
    @StateObject private var controller = CoolerController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
        }
    }
}
