import AppIntents
import Foundation
import WidgetKit

// Buttons on the widgets. They're live-activity actions so they always run inside the Agenda app
// itself (in the background), which owns the to-dos, the alarms and the notifications.

struct TickOffIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Tick Off"
    static let description = IntentDescription("Marks a to-do or reminder as done.")
    static let isDiscoverable = false

    @Parameter(title: "ID")
    var id: String

    @Parameter(title: "Kind")
    var kind: String

    init() {}

    init(id: String, kind: String) {
        self.id = id
        self.kind = kind
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if AGENDA_APP
        let store = AgendaStore.shared
        store.reload()
        if let uuid = UUID(uuidString: id) {
            if kind == WidgetSnapshot.Row.Kind.routine.rawValue {
                store.markRoutineDone(uuid)
            } else {
                store.setDone(uuid, true)
            }
        }
        #endif
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// Opens Agenda straight into listening, ready for a brain dump.
struct BrainDumpIntent: AppIntent {
    static let title: LocalizedStringResource = "Brain Dump"
    static let description = IntentDescription("Opens Agenda and starts listening, so you can talk through everything on your mind.")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if AGENDA_APP
        Router.shared.startBrainDump(listening: true)
        #endif
        return .result()
    }
}

/// Opens Agenda with the typing box ready.
struct QuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "New To-Do"
    static let description = IntentDescription("Opens Agenda ready to type a new to-do.")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if AGENDA_APP
        Router.shared.startBrainDump(listening: false)
        #endif
        return .result()
    }
}
