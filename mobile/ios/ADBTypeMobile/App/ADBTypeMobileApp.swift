import SwiftUI

@main
struct ADBTypeMobileApp: App {
    @StateObject private var model = LANModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    model.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        model.handleAppBecameActive()
                    }
                }
        }
    }
}
