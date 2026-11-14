import AppIntents
import SwiftUI

@main
struct StaysApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = StaysStore.shared
    @State private var ready = false

    var body: some Scene {
        WindowGroup {
            Group {
                if ready {
                    RootView()
                } else {
                    Color(.systemGroupedBackground).ignoresSafeArea()
                }
            }
            .environment(store)
            .task {
                if await SelfTest.runIfRequested() { return }
                if await Demo.runIfRequested() { ready = true; return }
                store.load()
                ready = true
                store.writeSnapshot()
            }
            .onOpenURL { Router.shared.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard ready, !Demo.isOn, phase == .active else { return }
            store.refresh()
            store.writeSnapshot()
        }
    }
}
