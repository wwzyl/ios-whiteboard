import SwiftUI

@main
struct CBrainApp: App {
    @StateObject private var model = CBrainViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

