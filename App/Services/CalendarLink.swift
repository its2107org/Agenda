import EventKit
import Foundation
import Observation

/// An event from the phone's own calendar (iCloud, Google, work...), shown alongside Agenda's items.
struct PhoneEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String
    var calendarName: String
    var colour: CGColor?

    func isOn(_ day: Date, calendar: Calendar = .current) -> Bool {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: max(start, end.addingTimeInterval(-1)))
        let d = calendar.startOfDay(for: day)
        return d >= first && d <= last
    }
}

/// Reads the phone's calendar and adds bookings to it.
@MainActor
@Observable
final class CalendarLink {
    static let shared = CalendarLink()

    private let eventStore = EKEventStore()
    /// Events from a week ago to two months ahead.
    private(set) var events: [PhoneEvent] = []

    var showPhoneCalendar: Bool {
        get { access(keyPath: \.showPhoneCalendar); return UserDefaults.standard.object(forKey: "showPhoneCalendar") as? Bool ?? true }
        set { withMutation(keyPath: \.showPhoneCalendar) { UserDefaults.standard.set(newValue, forKey: "showPhoneCalendar") } }
    }

    /// Copy bookings into the phone's calendar too.
    var copyBookings: Bool {
        get { access(keyPath: \.copyBookings); return UserDefaults.standard.object(forKey: "copyBookings") as? Bool ?? true }
        set { withMutation(keyPath: \.copyBookings) { UserDefaults.standard.set(newValue, forKey: "copyBookings") } }
    }

    private init() {}

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    var canRead: Bool { status == .fullAccess }
    var canWrite: Bool { status == .fullAccess || status == .writeOnly }

    func requestAccess() async -> Bool {
        let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
        if granted { await refresh() }
        return granted
    }

    func refresh() async {
        guard !Demo.isOn else {
            events = Demo.phoneEvents()
            return
        }
        guard canRead, showPhoneCalendar else {
            events = []
            return
        }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: Date()))!
        let end = calendar.date(byAdding: .month, value: 3, to: start)!
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let agendaIDs = Set(AgendaStore.shared.data.items.compactMap(\.calendarEventID))
        events = eventStore.events(matching: predicate)
            .filter { !agendaIDs.contains($0.eventIdentifier ?? "") }
            .map { event in
                PhoneEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Event",
                           start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                           location: event.location ?? "", calendarName: event.calendar?.title ?? "",
                           colour: event.calendar?.cgColor)
            }
            .sorted { $0.start < $1.start }
    }

    func events(on day: Date) -> [PhoneEvent] {
        events.filter { $0.isOn(day) }
    }

    /// Adds (or updates) a booking in the phone's calendar. Returns the calendar's id for it.
    func save(_ item: Item) async -> String? {
        guard item.isEvent, let start = item.due else { return nil }
        if !canWrite {
            guard (try? await eventStore.requestWriteOnlyAccessToEvents()) == true || canWrite else { return nil }
        }
        let event = item.calendarEventID.flatMap { eventStore.event(withIdentifier: $0) } ?? EKEvent(eventStore: eventStore)
        if event.calendar == nil { event.calendar = eventStore.defaultCalendarForNewEvents }
        event.title = item.title
        event.startDate = start
        event.isAllDay = !item.hasTime
        event.endDate = item.end ?? start.addingTimeInterval(item.hasTime ? 2 * 3600 : 86400)
        event.location = item.location.isEmpty ? nil : item.location
        var notes = item.notes
        if !item.reference.isEmpty { notes = "Ref: \(item.reference)" + (notes.isEmpty ? "" : "\n\(notes)") }
        event.notes = notes.isEmpty ? nil : notes
        if let url = URL(string: item.link), !item.link.isEmpty { event.url = url }
        do {
            try eventStore.save(event, span: .thisEvent)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }

    func remove(_ item: Item) {
        guard let id = item.calendarEventID, canWrite, let event = eventStore.event(withIdentifier: id) else { return }
        try? eventStore.remove(event, span: .thisEvent)
    }
}
