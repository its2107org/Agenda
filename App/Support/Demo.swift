import Foundation

/// Pretend to-dos for screenshots (started with -AgendaDemo). Nothing is saved.
enum Demo {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var isOn: Bool { arguments.contains("-AgendaDemo") }
    static func flag(_ name: String) -> Bool { arguments.contains("-AgendaDemo\(name)") }

    static let dumpText = "Okay so I need to send the Q3 memo to Tom by Friday, and book a table somewhere for Sam's birthday next Saturday. Also pick up the dry cleaning, oh and the bathroom tap is still dripping so call the super. Pay rent on the first of every month. And I should really renew my passport, that's urgent."

    @MainActor
    static func runIfRequested() async {
        guard isOn else { return }
        try? await Task.sleep(for: .milliseconds(300))
        let router = Router.shared
        if flag("Lists") { router.tab = .lists }
        if flag("Calendar") { router.tab = .calendar }
        if flag("Reminders") { router.tab = .routines }
        if flag("Settings") { router.sheet = .settings }
        if flag("Dump") { router.sheet = .brainDump(listening: true) }
        if flag("Review") {
            router.proposals = Sorter.proposals(from: sampleDump(), categories: Category.defaults, source: .voice)
            router.sheet = .review
        }
        if flag("Booking"), let dinner = AgendaStore.shared.data.items.first(where: { $0.title.hasPrefix("Dinner") }) {
            router.sheet = .item(dinner.id)
        }
    }

    private static func at(_ dayOffset: Int, _ hour: Int? = nil, _ minute: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: Date()))!
        guard let hour else { return day }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    static func sample() -> AgendaData {
        var data = AgendaData()
        func task(_ title: String, _ category: String, _ due: Date? = nil, time: Bool = false, flagged: Bool = false,
                  done: Bool = false, notes: String = "") -> Item {
            var item = Item(title: title, notes: notes, categoryID: category)
            item.due = due
            item.hasTime = time
            item.flagged = flagged
            item.doneAt = done ? Date().addingTimeInterval(-3600) : nil
            item.created = Date().addingTimeInterval(-86400 * 2)
            return item
        }
        func event(_ title: String, _ category: String, _ start: Date, hours: Double, place: String, ref: String = "") -> Item {
            var item = Item(title: title, categoryID: category, kind: .event, due: start, hasTime: true,
                            end: start.addingTimeInterval(hours * 3600), location: place, reference: ref)
            item.source = .shared
            return item
        }
        data.items = [
            task("Return the Zara jacket", "errands", at(-1)),
            task("Reply to Hannah about the wedding", "social", at(-2)),
            task("Send Q3 memo to Tom", "work", at(0, 11), time: true, flagged: true),
            event("Dinner at Via Carota", "social", at(0, 19, 30), hours: 2, place: "51 Grove St", ref: "VC-4821"),
            task("Book dentist check-up", "health", at(0)),
            task("Pick up dry cleaning", "errands", at(0)),
            task("Call Mum", "social", at(0)),
            task("Pay electricity bill", "money", at(0), done: true),
            task("Order more Omnipods", "health", at(0), done: true),
            task("Board deck review", "work", at(1, 10), time: true),
            task("Clean the fridge", "home", at(1)),
            task("Renew passport", "money", at(3), flagged: true),
            event("Sam's birthday drinks", "social", at(2, 20), hours: 3, place: "Bemelmans Bar"),
            event("Flight to London · BA 178", "personal", at(6, 18, 25), hours: 7, place: "JFK Terminal 8", ref: "X7K2QP"),
            task("Read Poor Charlie's Almanack", "personal"),
            task("Find a new barber", "personal"),
            task("Fix the bathroom tap", "home", flagged: false, notes: "Call the super if it's still dripping")
        ]
        var mounjaro = Routine.mounjaroPreset()
        mounjaro.nextDue = at(0, 20)
        mounjaro.lastSite = "Tummy (left)"
        mounjaro.dosesLeft = 2
        var rent = Routine.rentPreset()
        rent.nextDue = Routine.occurrence(of: rent.schedule, after: Date(), anchor: Date(), calendar: .current)
        let plants = Routine(title: "Water the plants", symbol: "leaf.fill", categoryID: "home",
                             schedule: .weekdays(days: [1, 4], hour: 9, minute: 0), nextDue: at(1, 9))
        data.routines = [mounjaro, rent, plants]
        return data
    }

    static func phoneEvents() -> [PhoneEvent] {
        [
            PhoneEvent(id: "p1", title: "Team stand-up", start: at(0, 9, 30), end: at(0, 10), allDay: false,
                       location: "", calendarName: "Work", colour: CGColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1)),
            PhoneEvent(id: "p2", title: "Gym with Alex", start: at(1, 7), end: at(1, 8), allDay: false,
                       location: "Equinox E 74th", calendarName: "Home", colour: CGColor(red: 0.3, green: 0.75, blue: 0.5, alpha: 1)),
            PhoneEvent(id: "p3", title: "Portfolio review", start: at(4, 14), end: at(4, 15, 30), allDay: false,
                       location: "", calendarName: "Work", colour: CGColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1))
        ]
    }

    static func sampleDump() -> SortedDump {
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        let friday = calendar.nextDate(after: Date(), matching: DateComponents(weekday: 6), matchingPolicy: .nextTime)!
        let saturday = calendar.date(byAdding: .day, value: 8, to: friday)!
        func entry(_ title: String, _ category: String, kind: String = "task", date: Date? = nil, time: String = "",
                   flagged: Bool = false, repeatType: String = "none", repeatDay: Int = 0, notes: String = "") -> SortedDump.Entry {
            SortedDump.Entry(title: title, category: category, kind: kind, date: date.map(iso.string) ?? "", time: time,
                             endDate: "", endTime: "", location: "", reference: "", notes: notes, flagged: flagged,
                             repeatType: repeatType, repeatHours: 0, repeatWeekdays: [], repeatDay: repeatDay)
        }
        return SortedDump(items: [
            entry("Send Q3 memo to Tom", "work", date: friday),
            entry("Book a table for Sam's birthday", "social", date: saturday, notes: "Next Saturday"),
            entry("Pick up dry cleaning", "errands"),
            entry("Call the super about the bathroom tap", "home"),
            entry("Pay rent", "money", repeatType: "monthly", repeatDay: 1),
            entry("Renew passport", "money", flagged: true)
        ])
    }
}
