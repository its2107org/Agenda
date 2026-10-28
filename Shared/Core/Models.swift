import Foundation
import SwiftUI

// MARK: - Categories

/// A section such as Work or Social. Ian can rename, recolour, add and remove them.
struct Category: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var symbol: String
    var colour: Int
    /// Extra words Ian chose that file a to-do here when he says or types them, e.g. "gym, physio".
    /// (Saying the list's own name always works.)
    var hint: String = ""

    var tint: Color { Palette.colour(colour) }

    var keywords: [String] {
        hint.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var isInbox: Bool { id == Category.inboxID }

    /// Where anything goes that Ian didn't file himself.
    static let inboxID = "inbox"
    static let inbox = Category(id: inboxID, name: "Unsorted", symbol: "tray.fill", colour: 9)

    static let defaults: [Category] = [
        inbox,
        Category(id: "work", name: "Work", symbol: "briefcase.fill", colour: 0),
        Category(id: "social", name: "Social", symbol: "person.2.fill", colour: 1),
        Category(id: "home", name: "Home", symbol: "house.fill", colour: 2),
        Category(id: "errands", name: "Errands", symbol: "bag.fill", colour: 3),
        Category(id: "health", name: "Health", symbol: "heart.fill", colour: 4),
        Category(id: "money", name: "Money & admin", symbol: "doc.text.fill", colour: 5),
        Category(id: "personal", name: "Personal", symbol: "sparkles", colour: 6)
    ]

    /// The topic hints earlier versions filled in; they guessed lists from the topic, which Ian didn't want.
    static let oldHints: Set<String> = [
        "job, office, colleagues, clients, deals, meetings, emails to send for work",
        "friends, family, plans, dinners, parties, birthdays, messages to people, gifts",
        "chores, cleaning, laundry, repairs, the flat, groceries for the house",
        "shopping, returns, picking things up, post office, dry cleaning",
        "doctor, dentist, prescriptions, medication, exercise, gym",
        "bills, rent, bank, tax, insurance, forms, subscriptions, paperwork",
        "reading, hobbies, learning, ideas, travel planning, anything just for me"
    ]
}

enum Palette {
    static let colours: [Color] = [
        Color(red: 0.25, green: 0.52, blue: 0.96),   // blue
        Color(red: 0.96, green: 0.36, blue: 0.56),   // pink
        Color(red: 0.20, green: 0.74, blue: 0.47),   // green
        Color(red: 1.00, green: 0.58, blue: 0.16),   // orange
        Color(red: 0.94, green: 0.30, blue: 0.27),   // red
        Color(red: 0.12, green: 0.70, blue: 0.72),   // teal
        Color(red: 0.58, green: 0.40, blue: 0.95),   // purple
        Color(red: 0.95, green: 0.76, blue: 0.10),   // yellow
        Color(red: 0.55, green: 0.42, blue: 0.32),   // brown
        Color(red: 0.45, green: 0.50, blue: 0.58)    // slate
    ]

    static func colour(_ index: Int) -> Color { colours[((index % colours.count) + colours.count) % colours.count] }
}

// MARK: - To-dos and bookings

struct Item: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case task, event }
    enum Source: String, Codable, Sendable { case typed, voice, shared, siri }

    var id = UUID()
    var title: String
    var notes: String = ""
    var categoryID: String
    var kind: Kind = .task
    /// For a to-do: when it's due (a day, or a day and time). For a booking: when it starts.
    var due: Date?
    var hasTime: Bool = false
    /// For a booking: when it ends.
    var end: Date?
    var location: String = ""
    /// A booking's confirmation number or reference.
    var reference: String = ""
    var link: String = ""
    var flagged: Bool = false
    /// Nudge at the due time (only for to-dos with a time, and bookings).
    var remind: Bool = true
    var created = Date()
    var doneAt: Date?
    var source: Source = .typed
    /// The matching event in the phone's calendar, if this booking was copied there.
    var calendarEventID: String?
    /// Grouping tags such as "John" or "Wedding". Optional so lists saved before tags existed still load.
    var tags: [String]?

    var tagList: [String] {
        get { tags ?? [] }
        set { tags = newValue.isEmpty ? nil : newValue }
    }

    var isDone: Bool { doneAt != nil }
    var isEvent: Bool { kind == .event }

    /// A to-do that should have been done already.
    func isOverdue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard kind == .task, !isDone, let due else { return false }
        if hasTime { return due < now }
        return due < calendar.startOfDay(for: now)
    }

    func isOn(_ day: Date, calendar: Calendar = .current) -> Bool {
        guard let due else { return false }
        if kind == .event, let end, end > due {
            let start = calendar.startOfDay(for: due)
            let last = calendar.startOfDay(for: end.addingTimeInterval(-1))
            let d = calendar.startOfDay(for: day)
            return d >= start && d <= last
        }
        return calendar.isDate(due, inSameDayAs: day)
    }
}

// MARK: - Standing reminders (rent, Mounjaro...)

enum RoutineSchedule: Codable, Hashable, Sendable {
    /// A fixed gap, e.g. every 84 hours (3½ days) for a twice-weekly injection.
    case every(hours: Double)
    /// Chosen days of the week at a set time. Weekdays use Calendar numbering (1 = Sunday).
    case weekdays(days: [Int], hour: Int, minute: Int)
    /// A day of the month (1–31; short months use their last day) at a set time.
    case monthly(day: Int, hour: Int, minute: Int)

    var summary: String {
        switch self {
        case .every(let hours):
            return "Every \(RoutineSchedule.describe(hours: hours))"
        case .weekdays(let days, let hour, let minute):
            let symbols = Calendar.current.shortWeekdaySymbols
            let names = days.sorted().compactMap { (1...7).contains($0) ? symbols[$0 - 1] : nil }
            let time = RoutineSchedule.time(hour, minute)
            if names.count == 7 { return "Every day at \(time)" }
            return "\(names.joined(separator: ", ")) at \(time)"
        case .monthly(let day, let hour, let minute):
            return "Monthly on the \(RoutineSchedule.ordinal(day)) at \(RoutineSchedule.time(hour, minute))"
        }
    }

    static func time(_ hour: Int, _ minute: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps).map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch n % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }

    static func describe(hours: Double) -> String {
        let totalHours = Int(hours.rounded())
        let days = totalHours / 24
        let rest = totalHours % 24
        if days == 0 { return "\(rest) hour\(rest == 1 ? "" : "s")" }
        if rest == 0 { return days == 1 ? "day" : "\(days) days" }
        if rest == 12 { return "\(days)½ days" }
        return "\(days) day\(days == 1 ? "" : "s") \(rest) hour\(rest == 1 ? "" : "s")"
    }
}

struct Routine: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var symbol: String = "repeat"
    var categoryID: String = Category.inboxID
    var schedule: RoutineSchedule
    /// When this is next due. Stays in the past (overdue) until it's marked done.
    var nextDue: Date
    /// Minutes between repeat nudges until it's marked done.
    var nagMinutes: Int = 15
    /// Ring like a proper alarm (sounds even on silent).
    var useAlarm: Bool = false
    var isPaused: Bool = false
    var notes: String = ""

    // Injection site rotation
    var trackSites: Bool = false
    var sites: [String] = Routine.defaultSites
    var lastSite: String?

    // Pen / supply tracking
    var trackSupply: Bool = false
    var dosesPerPen: Int = 4
    var dosesLeft: Int = 4
    var doseNote: String = ""

    var lastDone: Date?
    /// Alarms currently set for this reminder.
    var alarmIDs: [UUID] = []

    static let defaultSites = ["Tummy (left)", "Tummy (right)", "Left thigh", "Right thigh", "Left arm", "Right arm"]

    func isDue(now: Date = Date()) -> Bool { !isPaused && nextDue <= now }

    var suggestedSite: String? {
        guard trackSites, !sites.isEmpty else { return nil }
        guard let last = lastSite, let index = sites.firstIndex(of: last) else { return sites.first }
        return sites[(index + 1) % sites.count]
    }

    var supplyWarning: String? {
        guard trackSupply else { return nil }
        if dosesLeft <= 0 { return "Pen empty: start a new pen" }
        if dosesLeft == 1 { return "Last dose in this pen: reorder soon" }
        return nil
    }

    /// The first due date after `date` that keeps the regular rhythm.
    func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date {
        Routine.occurrence(of: schedule, after: date, anchor: nextDue, calendar: calendar)
    }

    /// Upcoming due dates between two dates (for the calendar), starting from the current due date.
    func occurrences(from start: Date, to end: Date, calendar: Calendar = .current) -> [Date] {
        guard !isPaused else { return [] }
        var result: [Date] = []
        var date = nextDue
        var guardCount = 0
        while date < end && guardCount < 400 {
            if date >= start { result.append(date) }
            let next = Routine.occurrence(of: schedule, after: date, anchor: date, calendar: calendar)
            if next <= date { break }
            date = next
            guardCount += 1
        }
        return result
    }

    static func occurrence(of schedule: RoutineSchedule, after date: Date, anchor: Date, calendar: Calendar) -> Date {
        switch schedule {
        case .every(let hours):
            // Steps are counted on the clock face, so 8am stays 8am when the clocks change.
            let stepMinutes = Int((max(hours, 0.25) * 60).rounded())
            func step(_ d: Date) -> Date {
                let parts = calendar.dateComponents([.hour, .minute], from: d)
                let wall = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) + stepMinutes
                let dayShift = wall / (24 * 60)
                let minuteOfDay = wall % (24 * 60)
                guard let day = calendar.date(byAdding: .day, value: dayShift, to: calendar.startOfDay(for: d)),
                      let result = calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: day),
                      result > d else { return d.addingTimeInterval(Double(stepMinutes) * 60) }
                return result
            }
            var next = anchor
            if next > date { next = step(next) }
            var count = 0
            while next <= date && count < 5000 {
                next = step(next)
                count += 1
            }
            return next > date ? next : date.addingTimeInterval(Double(stepMinutes) * 60)
        case .weekdays(let days, let hour, let minute):
            let validDays = days.filter { (1...7).contains($0) }
            guard !validDays.isEmpty else { return date.addingTimeInterval(7 * 86400) }
            let from = max(date, anchor)
            var best: Date?
            for day in validDays {
                var comps = DateComponents()
                comps.weekday = day
                comps.hour = hour
                comps.minute = minute
                if let candidate = calendar.nextDate(after: from, matching: comps, matchingPolicy: .nextTime),
                   best == nil || candidate < best! {
                    best = candidate
                }
            }
            return best ?? date.addingTimeInterval(7 * 86400)
        case .monthly(let day, let hour, let minute):
            let from = max(date, anchor)
            var month = calendar.dateComponents([.year, .month], from: from)
            for _ in 0..<14 {
                if let candidate = monthlyDate(year: month.year!, month: month.month!, day: day, hour: hour,
                                               minute: minute, calendar: calendar), candidate > from {
                    return candidate
                }
                month.month! += 1
                if month.month! > 12 { month.month = 1; month.year! += 1 }
            }
            return from.addingTimeInterval(30 * 86400)
        }
    }

    static func monthlyDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        var comps = DateComponents(year: year, month: month, day: 1)
        guard let first = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: first) else { return nil }
        comps.day = min(max(day, 1), range.count)
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)
    }

    // MARK: Ready-made ones

    static func mounjaroPreset(now: Date = Date()) -> Routine {
        // First dose: next Sunday at 8am, then every 3½ days (Sun 8am, Wed 8pm).
        var comps = DateComponents()
        comps.weekday = 1
        comps.hour = 8
        comps.minute = 0
        let first = Calendar.current.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) ?? now.addingTimeInterval(86400)
        return Routine(title: "Mounjaro", symbol: "syringe.fill", categoryID: "health", schedule: .every(hours: 84),
                       nextDue: first, nagMinutes: 5, useAlarm: true, trackSites: true, trackSupply: true)
    }

    static func rentPreset(now: Date = Date()) -> Routine {
        let schedule = RoutineSchedule.monthly(day: 1, hour: 9, minute: 0)
        let first = occurrence(of: schedule, after: now, anchor: now, calendar: .current)
        return Routine(title: "Pay rent", symbol: "house.fill", categoryID: "money", schedule: schedule,
                       nextDue: first, nagMinutes: 120)
    }
}

struct LogEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var routineID: UUID
    var title: String
    var dueDate: Date
    var doneDate: Date
    var site: String?
    var doseNote: String?
}

struct AgendaData: Codable, Sendable {
    var items: [Item] = []
    var routines: [Routine] = []
    var categories: [Category] = Category.defaults
    var log: [LogEntry] = []

    /// Brings lists saved by earlier versions up to date. Returns true if anything changed.
    mutating func upgrade() -> Bool {
        var changed = false
        if !categories.contains(where: \.isInbox) {
            categories.insert(Category.inbox, at: 0)
            changed = true
        }
        for index in categories.indices where Category.oldHints.contains(categories[index].hint) {
            categories[index].hint = ""
            changed = true
        }
        return changed
    }
}
