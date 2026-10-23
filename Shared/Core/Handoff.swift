import Foundation

/// What the widgets show. The app writes it whenever anything changes; widgets only read it.
struct WidgetSnapshot: Codable, Sendable {
    struct Row: Codable, Identifiable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable { case task, event, routine }
        var id: String
        var kind: Kind
        var title: String
        var colour: Int
        var symbol: String
        var time: Date?
        var hasTime: Bool
        var overdue: Bool
    }

    var updated = Date()
    /// Overdue first, then today's, then the next few days'.
    var rows: [Row] = []
    var overdueCount = 0
    var todayCount = 0
    var doneToday = 0

    static let service = "agenda.widget"

    static func load() -> WidgetSnapshot {
        guard let data = SharedVault.read(service: service, account: "today"),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return WidgetSnapshot() }
        return snapshot
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        SharedVault.write(data, service: Self.service, account: "today")
    }
}

/// Things shared to Agenda from other apps (a booking email, a web page, a screenshot), waiting
/// for the app to sort them. The Share button can't reach the app's own files, so they wait in the
/// shared keychain space.
struct SharedDrop: Codable, Identifiable, Sendable {
    var id = UUID()
    var created = Date()
    /// The words shared, plus any text read from screenshots or PDFs.
    var text: String
    var link: String = ""
    /// Anything Ian typed on the Share screen ("dinner with Sam").
    var comment: String = ""
}

enum ShareInbox {
    static let service = "agenda.inbox"

    static func add(_ drop: SharedDrop) {
        guard let data = try? JSONEncoder().encode(drop) else { return }
        SharedVault.write(data, service: service, account: drop.id.uuidString)
    }

    static func all() -> [SharedDrop] {
        SharedVault.readAll(service: service)
            .compactMap { try? JSONDecoder().decode(SharedDrop.self, from: $0.1) }
            .sorted { $0.created < $1.created }
    }

    static func remove(_ id: UUID) {
        SharedVault.delete(service: service, account: id.uuidString)
    }
}
