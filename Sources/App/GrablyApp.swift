import SwiftUI

@main
struct GrablyApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(environment)
                .frame(minWidth: 560, minHeight: 440)
        }
        .defaultSize(width: 720, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}
