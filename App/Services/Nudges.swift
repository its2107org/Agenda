import ActivityKit
import AlarmKit
import AppIntents
import Foundation
import SwiftUI
import UserNotifications
import WidgetKit

/// Small piece of data attached to each alarm so the alarm screen knows which reminder it is.
struct AgendaAlarmMetadata: AlarmMetadata {
    var routineID: UUID
    var title: String
    var symbol: String
}

/// Everything that taps Ian on the shoulder:
///  - standing reminders (rent, Mounjaro): an optional proper alarm, then repeat nudges every few
///    minutes until he marks it done;
///  - to-dos with a time: a nudge at the time and one more an hour later if it's still not done;
///  - bookings: a heads-up an hour before;
///  - a morning round-up of today's list and anything that slipped, and an evening check of what's
///    still open.
@MainActor
enum Nudges {
    enum Action {
        static let itemCategory = "AGENDA_ITEM"
        static let routineCategory = "AGENDA_ROUTINE"
        static let roundupCategory = "AGENDA_ROUNDUP"
        static let done = "DONE"
        static let laterHour = "LATER_HOUR"
        static let tomorrow = "TOMORROW"
        static let allTomorrow = "ALL_TOMORROW"
    }

    static let itemKey = "item"
    static let routineKey = "routine"
    /// iOS keeps at most 64 waiting notifications per app.
    static let budget = 60

    // MARK: - Settings

    static var morningOn: Bool {
        get { UserDefaults.standard.object(forKey: "morningOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "morningOn") }
    }
    static var morningMinutes: Int {
        get { UserDefaults.standard.object(forKey: "morningMinutes") as? Int ?? 8 * 60 + 30 }
        set { UserDefaults.standard.set(newValue, forKey: "morningMinutes") }
    }
    static var eveningOn: Bool {
        get { UserDefaults.standard.object(forKey: "eveningOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "eveningOn") }
    }
    static var eveningMinutes: Int {
        get { UserDefaults.standard.object(forKey: "eveningMinutes") as? Int ?? 20 * 60 }
        set { UserDefaults.standard.set(newValue, forKey: "eveningMinutes") }
    }
    /// Minutes before a booking to give a heads-up (0 = off).
    static var bookingLead: Int {
        get { UserDefaults.standard.object(forKey: "bookingLead") as? Int ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "bookingLead") }
    }

    // MARK: - Set-up

    static func requestPermissions() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func requestAlarmPermission() async -> Bool {
        if AlarmManager.shared.authorizationState == .notDetermined {
            _ = try? await AlarmManager.shared.requestAuthorization()
        }
        return AlarmManager.shared.authorizationState == .authorized
    }

    nonisolated static func registerCategories() {
        let done = UNNotificationAction(identifier: Action.done, title: "Done ✓", options: [])
        let hour = UNNotificationAction(identifier: Action.laterHour, title: "In an hour", options: [])
        let tomorrow = UNNotificationAction(identifier: Action.tomorrow, title: "Tomorrow", options: [])
        let allTomorrow = UNNotificationAction(identifier: Action.allTomorrow, title: "Move all to tomorrow", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Action.itemCategory, actions: [done, hour, tomorrow], intentIdentifiers: []),
            UNNotificationCategory(identifier: Action.routineCategory, actions: [done], intentIdentifiers: []),
            UNNotificationCategory(identifier: Action.roundupCategory, actions: [allTomorrow], intentIdentifiers: [])
        ])
    }

    // MARK: - Scheduling

    private static var pending: Task<Void, Never>?

    /// Reschedules shortly after a change (several quick changes only reschedule once).
    static func scheduleSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await rescheduleAll()
        }
    }

    /// One planned notification.
    struct Plan {
        var id: String
        var date: Date
        var title: String
        var body: String
        var category: String
        var userInfo: [String: String] = [:]
        var thread: String
        var urgent = false
        var priority: Int
    }

    /// What was last scheduled, so a change that doesn't affect any alert costs nothing.
    private static var lastSignature: String?

    static func signature(of plans: [Plan], now: Date) -> String {
        plans.map { plan in
            // Alerts due in the next couple of minutes are pinned to "now", so they'd never match exactly.
            let when = plan.date < now.addingTimeInterval(120) ? "soon" : String(Int(plan.date.timeIntervalSince1970 / 60))
            return "\(plan.id)|\(when)|\(plan.title)|\(plan.body)|\(plan.category)|\(plan.urgent)"
        }.joined(separator: "\n")
    }

    /// Makes the waiting alerts match the list. Rebuilds them only when something actually changed.
    static func rescheduleAll(now: Date = Date()) async {
        let store = AgendaStore.shared
        let center = UNUserNotificationCenter.current()

        let alarmsAllowed = AlarmManager.shared.authorizationState == .authorized
        await syncAlarms(store: store, allowed: alarmsAllowed, now: now)

        let plans = plan(store: store, alarmsAllowed: alarmsAllowed, now: now)
        let lateCount = store.overdue(now: now).count + store.routines.filter { $0.isDue(now: now) }.count
        let signature = signature(of: plans, now: now)
        if signature == lastSignature {
            // Same plan; only redo it if some alerts have gone off since (or iOS dropped them).
            let waiting = Set(await center.pendingNotificationRequests().map(\.identifier))
            if waiting == Set(plans.map(\.id)) {
                try? await center.setBadgeCount(lateCount)
                return
            }
        }
        center.removeAllPendingNotificationRequests()
        lastSignature = signature
        for plan in plans {
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            content.interruptionLevel = plan.urgent ? .timeSensitive : .active
            content.categoryIdentifier = plan.category
            content.userInfo = plan.userInfo
            content.threadIdentifier = plan.thread
            let interval = max(plan.date.timeIntervalSince(now), 1)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: plan.id, content: content, trigger: trigger))
        }
        try? await center.setBadgeCount(lateCount)
    }

    /// Works out which notifications to send, most important first, within iOS's limit.
    static func plan(store: AgendaStore, alarmsAllowed: Bool, now: Date = Date()) -> [Plan] {
        let calendar = Calendar.current
        var plans: [Plan] = []

        // Standing reminders: repeat until done.
        let active = store.routines.filter { !$0.isPaused }
        let perRoutine = active.isEmpty ? 0 : min(12, max(4, 30 / active.count))
        for routine in active {
            let nag = TimeInterval(max(routine.nagMinutes, 1) * 60)
            let firstAlert = routine.nextDue > now ? routine.nextDue : now.addingTimeInterval(30)
            let ringing = routine.useAlarm && alarmsAllowed
            let start = ringing ? firstAlert.addingTimeInterval(nag) : firstAlert
            for index in 0..<perRoutine {
                var body = index == 0 && !ringing ? "Time to \(routine.title.lowercased())." : "Still to do: \(routine.title). Tap Done once it's done."
                if index == 0 && !ringing && routine.symbol == "syringe.fill" { body = "Time for your \(routine.title)." }
                if let site = routine.suggestedSite { body += " Suggested spot: \(site)." }
                if let warning = routine.supplyWarning, index == 0 { body += " \(warning)." }
                plans.append(Plan(id: "routine-\(routine.id.uuidString)-\(index)", date: start.addingTimeInterval(nag * Double(index)),
                                  title: routine.title, body: body, category: Action.routineCategory,
                                  userInfo: [routineKey: routine.id.uuidString], thread: routine.id.uuidString,
                                  urgent: true, priority: index == 0 ? 0 : 3 + index))
            }
        }

        // To-dos with a time.
        let timed = store.openTasks.filter { $0.hasTime && $0.remind && $0.due != nil }
            .sorted { $0.due! < $1.due! }
        for item in timed {
            let due = item.due!
            let category = store.category(item.categoryID).name
            if due > now {
                plans.append(Plan(id: "item-\(item.id.uuidString)-0", date: due, title: item.title,
                                  body: item.notes.isEmpty ? category : item.notes, category: Action.itemCategory,
                                  userInfo: [itemKey: item.id.uuidString], thread: "items", urgent: item.flagged, priority: 1))
            }
            let followUp = due.addingTimeInterval(3600)
            if followUp > now {
                plans.append(Plan(id: "item-\(item.id.uuidString)-1", date: followUp, title: "Still to do: \(item.title)",
                                  body: "Tap Done, or push it to later.", category: Action.itemCategory,
                                  userInfo: [itemKey: item.id.uuidString], thread: "items", priority: 5))
            }
        }

        // Bookings: a heads-up beforehand.
        if bookingLead > 0 {
            for item in store.data.items where item.isEvent && item.remind {
                guard let start = item.due, item.hasTime else { continue }
                let alert = start.addingTimeInterval(-Double(bookingLead) * 60)
                guard alert > now else { continue }
                var body = "At \(start.formatted(date: .omitted, time: .shortened))"
                if !item.location.isEmpty { body += " · \(item.location)" }
                if !item.reference.isEmpty { body += " · Ref \(item.reference)" }
                plans.append(Plan(id: "event-\(item.id.uuidString)", date: alert, title: item.title, body: body,
                                  category: "", userInfo: [itemKey: item.id.uuidString], thread: "events", priority: 2))
            }
        }

        // Morning round-up and evening check for the next three days.
        for offset in 0..<3 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            if morningOn, let at = calendar.date(byAdding: .minute, value: morningMinutes, to: day), at > now,
               let text = morningText(store: store, at: at) {
                plans.append(Plan(id: "morning-\(offset)", date: at, title: text.title, body: text.body,
                                  category: Action.roundupCategory, thread: "roundup", priority: 2))
            }
            if eveningOn, let at = calendar.date(byAdding: .minute, value: eveningMinutes, to: day), at > now,
               let text = eveningText(store: store, at: at) {
                plans.append(Plan(id: "evening-\(offset)", date: at, title: text.title, body: text.body,
                                  category: Action.roundupCategory, thread: "roundup", priority: 4))
            }
        }

        // Keep the most important ones; among equals, the soonest.
        plans.sort { ($0.priority, $0.date) < ($1.priority, $1.date) }
        return Array(plans.prefix(budget))
    }

    /// "Today: 5 things · 2 slipped" with the first few listed.
    static func morningText(store: AgendaStore, at: Date) -> (title: String, body: String)? {
        let calendar = Calendar.current
        let late = store.openTasks.filter { $0.isOverdue(now: calendar.startOfDay(for: at).addingTimeInterval(1)) }
        let today = store.data.items.filter { $0.isOn(at) && !($0.kind == .task && $0.isDone) }
        let routines = store.routines.filter { !$0.isPaused && calendar.isDate($0.nextDue, inSameDayAs: at) }
        let total = today.count + routines.count
        guard total + late.count > 0 else { return nil }
        var title = total == 0 ? "Nothing new today" : "Today: \(total) thing\(total == 1 ? "" : "s")"
        if !late.isEmpty { title += " · \(late.count) slipped" }
        let names = (today.sorted(by: AgendaStore.byDue).map(\.title) + routines.map(\.title) + late.map(\.title))
        return (title, list(names))
    }

    /// What's still open at the end of the day.
    static func eveningText(store: AgendaStore, at: Date) -> (title: String, body: String)? {
        let open = store.openTasks.filter { item in
            guard let due = item.due else { return false }
            return due < at
        }
        guard !open.isEmpty else { return nil }
        let title = open.count == 1 ? "1 thing still open" : "\(open.count) things still open"
        return (title, list(open.sorted(by: AgendaStore.byDue).map(\.title)) + "\nHold here to move them to tomorrow.")
    }

    private static func list(_ names: [String]) -> String {
        let shown = names.prefix(4).joined(separator: ", ")
        return names.count > 4 ? "\(shown) and \(names.count - 4) more" : shown
    }

    // MARK: - Alarms for standing reminders

    private static var alarmSignatures: [UUID: String] = [:]

    static func syncAlarms(store: AgendaStore, allowed: Bool, now: Date) async {
        let wanted = store.routines.filter { $0.useAlarm && !$0.isPaused && allowed }
        // Cancel alarms that no longer belong to a reminder, or whose reminder moved.
        let known = Set(store.data.routines.flatMap(\.alarmIDs))
        let existing = (try? AlarmManager.shared.alarms) ?? []
        for alarm in existing where !known.contains(alarm.id) {
            try? AlarmManager.shared.cancel(id: alarm.id)
        }
        let set = Set(existing.map(\.id))
        for routine in store.data.routines {
            let wants = wanted.contains(where: { $0.id == routine.id })
            let signature = "\(wants)|\(routine.nextDue.timeIntervalSince1970)|\(routine.title)|\(routine.symbol)"
            // Leave a waiting alarm alone if its reminder hasn't changed.
            if wants, alarmSignatures[routine.id] == signature, !routine.alarmIDs.isEmpty,
               routine.alarmIDs.allSatisfy(set.contains) { continue }
            alarmSignatures[routine.id] = signature
            for id in routine.alarmIDs { try? AlarmManager.shared.cancel(id: id) }
            guard wants else {
                if !routine.alarmIDs.isEmpty { store.setAlarmIDs([], for: routine.id) }
                continue
            }
            let at = routine.nextDue > now ? routine.nextDue : now.addingTimeInterval(30)
            let ids = await scheduleAlarm(for: routine, at: at).map { [$0] } ?? []
            store.setAlarmIDs(ids, for: routine.id)
        }
    }

    /// Schedules one alarm. Called again by the alarm's Stop button if the reminder still isn't done.
    static func scheduleAlarm(for routine: Routine, at date: Date) async -> UUID? {
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: routine.title),
            secondaryButton: AlarmButton(text: "Done", textColor: .white, systemImageName: "checkmark.circle.fill"),
            secondaryButtonBehavior: .custom
        )
        let attributes = AlarmAttributes<AgendaAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: AgendaAlarmMetadata(routineID: routine.id, title: routine.title, symbol: routine.symbol),
            tintColor: .orange
        )
        let id = UUID()
        let configuration = AlarmManager.AlarmConfiguration<AgendaAlarmMetadata>.alarm(
            schedule: .fixed(date),
            attributes: attributes,
            stopIntent: AlarmStoppedIntent(routineID: routine.id.uuidString),
            secondaryIntent: RoutineDoneIntent(routineID: routine.id.uuidString),
            sound: .default
        )
        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
            return id
        } catch {
            return nil
        }
    }

    // MARK: - Buttons on notifications

    static func handle(action: String, userInfo: [AnyHashable: Any]) async {
        let store = AgendaStore.shared
        store.reload()
        let itemID = (userInfo[itemKey] as? String).flatMap(UUID.init(uuidString:))
        let routineID = (userInfo[routineKey] as? String).flatMap(UUID.init(uuidString:))
        let calendar = Calendar.current

        switch action {
        case Action.done:
            if let itemID { store.setDone(itemID, true) }
            if let routineID { store.markRoutineDone(routineID) }
        case Action.laterHour:
            if let itemID { store.reschedule(itemID, to: Date().addingTimeInterval(3600), hasTime: true) }
        case Action.tomorrow:
            if let itemID { store.moveToTomorrow([itemID]) }
        case Action.allTomorrow:
            let now = Date()
            let open = store.openTasks.filter { item in
                guard let due = item.due else { return false }
                return due < calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            }
            store.moveToTomorrow(open.map(\.id))
        case UNNotificationDefaultActionIdentifier:
            if let itemID { Router.shared.sheet = .item(itemID) }
            else if routineID != nil { Router.shared.tab = .routines }
            else { Router.shared.tab = .today }
            return
        default:
            return
        }
        await rescheduleAll()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Alarm buttons

/// "Done" on the alarm screen.
struct RoutineDoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark Reminder Done"
    static let isDiscoverable = false

    @Parameter(title: "Reminder ID")
    var routineID: String

    init() {}

    init(routineID: String) {
        self.routineID = routineID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = AgendaStore.shared
        store.reload()
        if let id = UUID(uuidString: routineID) {
            store.markRoutineDone(id)
            await Nudges.rescheduleAll()
        }
        return .result()
    }
}

/// The alarm's Stop button. If the reminder still isn't done, the alarm rings again after the nag gap.
struct AlarmStoppedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Alarm Stopped"
    static let isDiscoverable = false

    @Parameter(title: "Reminder ID")
    var routineID: String

    init() {}

    init(routineID: String) {
        self.routineID = routineID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = AgendaStore.shared
        store.reload()
        if let id = UUID(uuidString: routineID), let routine = store.routine(id), routine.isDue() {
            let next = Date().addingTimeInterval(TimeInterval(max(routine.nagMinutes, 1) * 60))
            if let alarmID = await Nudges.scheduleAlarm(for: routine, at: next) {
                store.setAlarmIDs(routine.alarmIDs + [alarmID], for: id)
            }
        }
        return .result()
    }
}
