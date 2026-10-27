import AppIntents
import Foundation

struct AddToDoIntent: AppIntent {
    static let title: LocalizedStringResource = "Add To-Do"
    static let description = IntentDescription("Adds a to-do to Agenda. Say a day or time and it's set, e.g. \"call Sam tomorrow at 3pm\".")

    @Parameter(title: "To-do", requestValueDialog: "What do you need to do?")
    var text: String

    init() {}

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) to Agenda") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaStore.shared
        store.reload()
        guard let item = Sorter.quickAdd(text, source: .siri) else {
            return .result(dialog: "I didn't catch that.")
        }
        let category = store.category(item.categoryID).name
        if let due = item.due {
            return .result(dialog: "Added \(item.title) to \(category), \(DateWords.short(due, hasTime: item.hasTime).lowercasedFirst).")
        }
        return .result(dialog: "Added \(item.title) to \(category).")
    }
}

struct TodayListIntent: AppIntent {
    static let title: LocalizedStringResource = "What's On Today"
    static let description = IntentDescription("Reads out today's to-dos, bookings and reminders, and anything that slipped.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let store = AgendaStore.shared
        store.reload()
        let now = Date()
        let late = store.overdue(now: now).map(\.title)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let today = store.routinesDue(by: end, now: now).map(\.title) + store.today(now: now).map(\.title)
        var parts: [String] = []
        if today.isEmpty { parts.append("Nothing on today.") } else { parts.append("Today: \(today.joined(separator: ", ")).") }
        if !late.isEmpty { parts.append("Slipped: \(late.joined(separator: ", ")).") }
        let text = parts.joined(separator: " ")
        return .result(value: text, dialog: "\(text)")
    }
}

struct AgendaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BrainDumpIntent(),
            phrases: [
                "Brain dump in \(.applicationName)",
                "\(.applicationName) brain dump",
                "Start a brain dump with \(.applicationName)"
            ],
            shortTitle: "Brain Dump",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: AddToDoIntent(),
            phrases: [
                "Add a to-do to \(.applicationName)",
                "Add to \(.applicationName)",
                "New \(.applicationName) to-do"
            ],
            shortTitle: "Add To-Do",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: TodayListIntent(),
            phrases: [
                "What's on today in \(.applicationName)",
                "What's on my \(.applicationName)",
                "Read my \(.applicationName)"
            ],
            shortTitle: "Today",
            systemImageName: "sun.max"
        )
    }
}
