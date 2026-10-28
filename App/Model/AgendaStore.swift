import Foundation
import Observation
import WidgetKit

/// The one place that reads and changes to-dos, bookings, standing reminders and sections.
/// Used by the app, the widget buttons, Siri, notifications and alarms.
@MainActor
@Observable
final class AgendaStore {
    static let shared = AgendaStore()

    private(set) var data: AgendaData
    /// Bumped on every change so views that cache things know to refresh.
    private(set) var revision = 0

    /// Pretend data for screenshots; never saved.
    private let inMemory: Bool

    private init() {
        if Demo.isOn {
            inMemory = true
            data = Demo.sample()
        } else {
            inMemory = false
            data = AgendaStore.loadFromDisk() ?? AgendaData()
            let date = AgendaStore.fileDate()
            AgendaStore.writer.sync { AgendaStore.savedFileDate = date }
        }
    }

    /// For the self-check: a store that starts empty and never touches the disk.
    init(testing data: AgendaData) {
        inMemory = true
        self.data = data
    }

    // MARK: - Saving

    nonisolated private static let fileURL: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("agenda.json")
    }()

    /// Saving happens on its own queue, in order, so the screen never waits for the disk.
    private static let writer = DispatchQueue(label: "agenda.save", qos: .userInitiated)
    /// When the file was last written or read by Agenda (only touched on `writer`).
    nonisolated(unsafe) private static var savedFileDate: Date?

    nonisolated private static func fileDate() -> Date? {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func loadFromDisk() -> AgendaData? {
        guard let raw = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AgendaData.self, from: raw)
    }

    /// Re-reads the file, but only if something other than this copy of Agenda changed it.
    func reload() {
        guard !inMemory else { return }
        let unchanged = AgendaStore.writer.sync {
            let date = AgendaStore.fileDate()
            return date != nil && date == AgendaStore.savedFileDate
        }
        guard !unchanged, let fresh = AgendaStore.loadFromDisk() else { return }
        let date = AgendaStore.fileDate()
        AgendaStore.writer.sync { AgendaStore.savedFileDate = date }
        data = fresh
        revision += 1
    }

    private func persist(reschedule: Bool = true) {
        revision += 1
        guard !inMemory || Demo.isOn else { return }
        if !inMemory {
            let snapshot = data
            AgendaStore.writer.async {
                guard let raw = try? JSONEncoder().encode(snapshot) else { return }
                // Readable after the first unlock, so nudges and widget buttons work while the phone is locked.
                try? raw.write(to: AgendaStore.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                AgendaStore.savedFileDate = AgendaStore.fileDate()
            }
        }
        writeSnapshotSoon()
        if reschedule && !inMemory { Nudges.scheduleSoon() }
    }

    /// Waits until everything is on disk (used before Agenda goes into the background).
    nonisolated static func flushToDisk() {
        writer.sync {}
    }

    // MARK: - Sections

    var categories: [Category] { data.categories }

    func category(_ id: String) -> Category {
        data.categories.first { $0.id == id } ?? data.categories.first { $0.id == "personal" }
            ?? data.categories.first ?? Category.defaults[6]
    }

    func upsertCategory(_ category: Category) {
        if let index = data.categories.firstIndex(where: { $0.id == category.id }) {
            data.categories[index] = category
        } else {
            data.categories.append(category)
        }
        persist(reschedule: false)
    }

    func deleteCategory(_ id: String) {
        guard data.categories.count > 1 else { return }
        data.categories.removeAll { $0.id == id }
        let fallback = category("personal").id
        for index in data.items.indices where data.items[index].categoryID == id {
            data.items[index].categoryID = fallback
        }
        for index in data.routines.indices where data.routines[index].categoryID == id {
            data.routines[index].categoryID = fallback
        }
        persist(reschedule: false)
    }

    func moveCategories(from source: IndexSet, to destination: Int) {
        data.categories.move(fromOffsets: source, toOffset: destination)
        persist(reschedule: false)
    }

    func newCategoryID(for name: String) -> String {
        let base = name.lowercased().filter { $0.isLetter || $0.isNumber }
        var id = base.isEmpty ? "section" : base
        var n = 2
        while data.categories.contains(where: { $0.id == id }) {
            id = "\(base)\(n)"
            n += 1
        }
        return id
    }

    // MARK: - To-dos and bookings

    func item(_ id: UUID) -> Item? { data.items.first { $0.id == id } }

    func add(_ items: [Item]) {
        data.items.append(contentsOf: items)
        persist()
    }

    func update(_ item: Item) {
        if let index = data.items.firstIndex(where: { $0.id == item.id }) {
            data.items[index] = item
        } else {
            data.items.append(item)
        }
        persist()
    }

    func delete(_ id: UUID) {
        data.items.removeAll { $0.id == id }
        persist()
    }

    func setDone(_ id: UUID, _ done: Bool, at now: Date = Date()) {
        guard let index = data.items.firstIndex(where: { $0.id == id }) else { return }
        data.items[index].doneAt = done ? now : nil
        persist()
    }

    /// Moves a to-do to a new time (keeping "no time" to-dos as day-only).
    func reschedule(_ id: UUID, to date: Date, hasTime: Bool? = nil) {
        guard let index = data.items.firstIndex(where: { $0.id == id }) else { return }
        data.items[index].due = date
        if let hasTime { data.items[index].hasTime = hasTime }
        persist()
    }

    /// Moves to-dos to tomorrow, keeping their time of day if they had one.
    func moveToTomorrow(_ ids: [UUID], now: Date = Date()) {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        for id in ids {
            guard let index = data.items.firstIndex(where: { $0.id == id }) else { continue }
            var item = data.items[index]
            if item.hasTime, let due = item.due {
                let time = calendar.dateComponents([.hour, .minute], from: due)
                item.due = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: tomorrow)
            } else {
                item.due = tomorrow
            }
            data.items[index] = item
        }
        persist()
    }

    /// Clears out to-dos ticked off more than 30 days ago so the list stays light.
    func tidyOldDone(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-30 * 86400)
        let before = data.items.count
        data.items.removeAll { item in
            guard let done = item.doneAt else { return item.kind == .event && (item.end ?? item.due ?? now) < cutoff }
            return done < cutoff
        }
        if data.items.count != before { persist(reschedule: false) }
    }

    // MARK: - Standing reminders

    var routines: [Routine] {
        data.routines.sorted { a, b in
            if a.isPaused != b.isPaused { return !a.isPaused }
            return a.nextDue < b.nextDue
        }
    }

    func routine(_ id: UUID) -> Routine? { data.routines.first { $0.id == id } }

    func upsertRoutine(_ routine: Routine) {
        if let index = data.routines.firstIndex(where: { $0.id == routine.id }) {
            data.routines[index] = routine
        } else {
            data.routines.append(routine)
        }
        persist()
    }

    func deleteRoutine(_ id: UUID) {
        data.routines.removeAll { $0.id == id }
        persist()
    }

    var log: [LogEntry] { data.log.sorted { $0.doneDate > $1.doneDate } }

    func log(for id: UUID) -> [LogEntry] { log.filter { $0.routineID == id } }

    /// Marks a standing reminder as done. `restartFromNow` moves the rhythm so the next one is a full gap from now.
    @discardableResult
    func markRoutineDone(_ id: UUID, site: String? = nil, restartFromNow: Bool = false, at now: Date = Date()) -> Routine? {
        guard var routine = routine(id) else { return nil }
        let usedSite = site ?? routine.suggestedSite
        data.log.append(LogEntry(routineID: routine.id, title: routine.title, dueDate: routine.nextDue, doneDate: now,
                                 site: usedSite, doseNote: routine.doseNote.isEmpty ? nil : routine.doseNote))
        if data.log.count > 1000 {
            data.log.sort { $0.doneDate < $1.doneDate }
            data.log.removeFirst(data.log.count - 1000)
        }
        if let usedSite { routine.lastSite = usedSite }
        if routine.trackSupply {
            routine.dosesLeft -= 1
            if routine.dosesLeft < 0 { routine.dosesLeft = routine.dosesPerPen - 1 }
        }
        routine.lastDone = now
        if restartFromNow, case .every(let hours) = routine.schedule {
            routine.nextDue = now.addingTimeInterval(hours * 3600)
        } else {
            routine.nextDue = routine.nextOccurrence(after: now)
        }
        upsertRoutine(routine)
        return routine
    }

    func startNewPen(_ id: UUID) {
        guard var routine = routine(id) else { return }
        routine.dosesLeft = routine.dosesPerPen
        upsertRoutine(routine)
    }

    func deleteLog(_ id: UUID) {
        data.log.removeAll { $0.id == id }
        persist(reschedule: false)
    }

    /// Saves which alarms belong to a reminder, without rescheduling everything again.
    func setAlarmIDs(_ ids: [UUID], for id: UUID) {
        guard let index = data.routines.firstIndex(where: { $0.id == id }) else { return }
        data.routines[index].alarmIDs = ids
        persist(reschedule: false)
    }

    // MARK: - Views of the list

    var openTasks: [Item] { data.items.filter { $0.kind == .task && !$0.isDone } }

    func overdue(now: Date = Date()) -> [Item] {
        openTasks.filter { $0.isOverdue(now: now) }.sorted(by: Self.byDue)
    }

    /// To-dos due today that aren't late yet, plus today's bookings.
    func today(now: Date = Date()) -> [Item] {
        data.items.filter { item in
            guard item.isOn(now) else { return false }
            if item.kind == .event { return true }
            return !item.isDone && !item.isOverdue(now: now)
        }.sorted(by: Self.byDue)
    }

    /// Ticked off today (shown faded at the bottom of Today).
    func doneToday(now: Date = Date()) -> [Item] {
        data.items.filter { $0.doneAt.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false }
            .sorted { ($0.doneAt ?? now) > ($1.doneAt ?? now) }
    }

    func routinesDue(by end: Date, now: Date = Date()) -> [Routine] {
        routines.filter { !$0.isPaused && $0.nextDue < end }
    }

    /// The next few days (not today), to-dos and bookings.
    func upcoming(days: Int = 7, now: Date = Date()) -> [Item] {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let end = calendar.date(byAdding: .day, value: days, to: tomorrow)!
        return data.items.filter { item in
            guard !item.isDone, let due = item.due else { return false }
            return due >= tomorrow && due < end
        }.sorted(by: Self.byDue)
    }

    /// To-dos with no date.
    var anytime: [Item] {
        openTasks.filter { $0.due == nil }.sorted { a, b in
            if a.flagged != b.flagged { return a.flagged }
            return a.created > b.created
        }
    }

    func items(in categoryID: String, includeDone: Bool = false) -> [Item] {
        data.items.filter { $0.categoryID == categoryID && (includeDone || !$0.isDone) }
            .filter { $0.kind == .task || ($0.end ?? $0.due ?? .distantFuture) >= Date() }
            .sorted { a, b in
                switch (a.due, b.due) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.created > b.created
                }
            }
    }

    func openCount(in categoryID: String) -> Int {
        data.items.filter { $0.categoryID == categoryID && !$0.isDone && $0.kind == .task }.count
    }

    /// Tags on open to-dos and upcoming bookings, most used first.
    var tags: [(name: String, count: Int)] {
        var counts: [String: (String, Int)] = [:]
        for item in data.items where !item.isDone && (item.kind == .task || (item.end ?? item.due ?? .distantFuture) >= Date()) {
            for tag in item.tagList {
                let key = tag.lowercased()
                counts[key] = (counts[key]?.0 ?? tag, (counts[key]?.1 ?? 0) + 1)
            }
        }
        return counts.values.map { (name: $0.0, count: $0.1) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    func items(tagged tag: String, includeDone: Bool = false) -> [Item] {
        data.items.filter { item in
            (includeDone || !item.isDone) && item.tagList.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }.sorted(by: Self.byDue)
    }

    var flagged: [Item] { openTasks.filter(\.flagged).sorted(by: Self.byDue) }

    /// Everything on a given day: to-dos, bookings and standing reminders.
    func items(on day: Date) -> [Item] {
        data.items.filter { $0.isOn(day) }.sorted(by: Self.byDue)
    }

    func routineTimes(on day: Date) -> [(Routine, Date)] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return routines.flatMap { routine in routine.occurrences(from: start, to: end).map { (routine, $0) } }
            .sorted { $0.1 < $1.1 }
    }

    /// Which days in a range have something on, for the dots under the calendar.
    func busyDays(from start: Date, to end: Date) -> [Date: [Int]] {
        let calendar = Calendar.current
        var result: [Date: [Int]] = [:]
        for item in data.items where !(item.kind == .task && item.isDone) {
            guard let due = item.due, due >= start, due < end else { continue }
            result[calendar.startOfDay(for: due), default: []].append(category(item.categoryID).colour)
        }
        for routine in routines {
            for date in routine.occurrences(from: start, to: end) {
                result[calendar.startOfDay(for: date), default: []].append(category(routine.categoryID).colour)
            }
        }
        return result
    }

    func search(_ text: String) -> [Item] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return data.items.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.notes.localizedCaseInsensitiveContains(needle)
                || $0.location.localizedCaseInsensitiveContains(needle)
                || $0.tagList.contains { $0.localizedCaseInsensitiveContains(needle.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }
        }.sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            return Self.byDue(a, b)
        }
    }

    nonisolated static func byDue(_ a: Item, _ b: Item) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?):
            if x != y { return x < y }
            if a.flagged != b.flagged { return a.flagged }
            return a.created < b.created
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.created < b.created
        }
    }

    // MARK: - Widgets

    func makeSnapshot(now: Date = Date()) -> WidgetSnapshot {
        let calendar = Calendar.current
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        var snapshot = WidgetSnapshot(updated: now)

        func row(_ item: Item, overdue: Bool) -> WidgetSnapshot.Row {
            let category = category(item.categoryID)
            return WidgetSnapshot.Row(id: item.id.uuidString, kind: item.isEvent ? .event : .task, title: item.title,
                                      colour: category.colour, symbol: item.isEvent ? "calendar" : category.symbol,
                                      time: item.due, hasTime: item.hasTime, overdue: overdue)
        }

        let late = overdue(now: now)
        let dueRoutines = routinesDue(by: endOfToday, now: now)
        let todays = today(now: now).filter { !($0.isEvent && ($0.end ?? $0.due ?? now) < now) }

        var rows: [(Date, WidgetSnapshot.Row)] = []
        for item in late { rows.append((.distantPast, row(item, overdue: true))) }
        for routine in dueRoutines {
            let category = category(routine.categoryID)
            rows.append((routine.nextDue < now ? .distantPast : routine.nextDue,
                         WidgetSnapshot.Row(id: routine.id.uuidString, kind: .routine, title: routine.title,
                                            colour: category.colour, symbol: routine.symbol, time: routine.nextDue,
                                            hasTime: true, overdue: routine.nextDue < now)))
        }
        for item in todays {
            rows.append((item.hasTime ? (item.due ?? endOfToday) : endOfToday, row(item, overdue: false)))
        }
        rows.sort { $0.0 < $1.0 }
        snapshot.overdueCount = late.count + dueRoutines.filter { $0.nextDue < now }.count
        snapshot.todayCount = rows.count
        snapshot.doneToday = doneToday(now: now).count
        // A few upcoming ones too, so the widget isn't empty on a quiet day.
        var all = rows.map(\.1)
        if all.count < 8 {
            for item in upcoming(days: 3, now: now).prefix(8 - all.count) { all.append(row(item, overdue: false)) }
        }
        snapshot.rows = Array(all.prefix(12))
        return snapshot
    }

    func writeSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = nil
        makeSnapshot().save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    @ObservationIgnored private var snapshotTask: Task<Void, Never>?

    /// Updates the widgets shortly after a change; several quick changes only update them once.
    private func writeSnapshotSoon() {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.writeSnapshot()
        }
    }

    /// Writes anything still waiting, so nothing is lost when Agenda is closed.
    func flushPending() {
        if snapshotTask != nil { writeSnapshot() }
        AgendaStore.flushToDisk()
    }
}
