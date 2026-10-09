import SwiftUI

struct DupDelApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("重复文件清理器") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 1_020, minHeight: 700)
        }
        .windowResizability(.contentSize)
    }
}
