import AppIntents
import Foundation

struct AddHotelIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Hotel"
    static let description = IntentDescription("Opens Stays ready to search for a hotel and add it to your list.")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.shared.tab = 0
        Router.shared.showAdd = true
        return .result()
    }
}

struct BestHotelsIntent: AppIntent {
    static let title: LocalizedStringResource = "Our Best Hotels"
    static let description = IntentDescription("Tells you your three best-rated hotels.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let store = StaysStore.shared
        store.load()
        let top = store.sorted(store.hotels, by: .best, dimension: nil)
            .filter { store.merged.overall($0.id) != nil }
            .prefix(3)
        guard !top.isEmpty else {
            return .result(value: "", dialog: "You haven't rated any hotels yet.")
        }
        let text = top.enumerated().map { i, h in
            "\(i + 1). \(h.name)\(h.city.isEmpty ? "" : ", \(h.city)") (\(Score.text(store.merged.overall(h.id))))"
        }.joined(separator: "\n")
        return .result(value: text, dialog: "\(text)")
    }
}

struct StaysShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddHotelIntent(),
                    phrases: ["Add a hotel to \(.applicationName)", "Add a stay in \(.applicationName)"],
                    shortTitle: "Add a Hotel",
                    systemImageName: "plus")
        AppShortcut(intent: BestHotelsIntent(),
                    phrases: ["Our best hotels in \(.applicationName)", "Best hotels in \(.applicationName)"],
                    shortTitle: "Best Hotels",
                    systemImageName: "star")
    }
}
