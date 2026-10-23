import SwiftUI

struct TodayView: View {
    private var store: AgendaStore { .shared }
    @State private var calendarLink = CalendarLink.shared
    @State private var router = Router.shared
    @State private var showDone = false

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                content(now: context.date)
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { router.sheet = .settings }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New to-do", systemImage: "plus") { router.sheet = .newItem }
                }
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let _ = store.revision
        let late = store.overdue(now: now)
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let dueRoutines = store.routinesDue(by: endOfToday, now: now)
        let lateRoutines = dueRoutines.filter { $0.nextDue < now }
        let laterRoutines = dueRoutines.filter { $0.nextDue >= now }
        let today = store.today(now: now)
        let phone = calendarLink.events(on: now).filter { $0.end > now || $0.allDay }
        let done = store.doneToday(now: now)
        let upcoming = store.upcoming(days: 7, now: now)
        let remaining = late.count + lateRoutines.count + laterRoutines.count + today.filter { !$0.isEvent }.count

        List {
            Section {
                DayHeader(now: now, remaining: remaining, done: done.count)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
                    .listRowBackground(Color.clear)
            }

            if !late.isEmpty || !lateRoutines.isEmpty {
                Section {
                    ForEach(lateRoutines) { RoutineRow(routine: $0, compact: true) }
                    ForEach(late) { item in
                        ItemRow(item: item, overdue: true)
                            .itemSwipes(item)
                    }
                } header: {
                    SectionTitle(text: "Slipped", colour: .red,
                                 trailing: late.isEmpty ? nil : "Move to tomorrow") {
                        withAnimation { store.moveToTomorrow(late.map(\.id), now: now) }
                    }
                }
            }

            Section {
                if laterRoutines.isEmpty && today.isEmpty && phone.isEmpty {
                    EmptyNote(symbol: late.isEmpty ? "sun.max" : "checkmark.circle",
                              title: late.isEmpty ? "Nothing else today" : "Nothing new today",
                              message: "Tap the microphone below and say what's on your mind. Agenda sorts it into lists.")
                }
                ForEach(laterRoutines) { RoutineRow(routine: $0, compact: true) }
                ForEach(timeline(today: today, phone: phone)) { entry in
                    switch entry {
                    case .item(let item):
                        ItemRow(item: item, showDate: item.hasTime || item.isEvent)
                            .itemSwipes(item)
                    case .phone(let event):
                        PhoneEventRow(event: event)
                    }
                }
            } header: {
                SectionTitle(text: "Today")
            }

            if !upcoming.isEmpty {
                Section {
                    ForEach(upcoming.prefix(8)) { item in
                        ItemRow(item: item).itemSwipes(item)
                    }
                    if upcoming.count > 8 {
                        Button("See all in Calendar") { router.tab = .calendar }
                            .font(.subheadline)
                    }
                } header: {
                    SectionTitle(text: "Coming up")
                }
            }

            if !done.isEmpty {
                Section {
                    if showDone {
                        ForEach(done) { ItemRow(item: $0) }
                    }
                } header: {
                    SectionTitle(text: "Done today", colour: .secondary,
                                 trailing: showDone ? "Hide" : "Show \(done.count)") {
                        withAnimation { showDone.toggle() }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .refreshable {
            store.reload()
            await calendarLink.refresh()
        }
        .animation(.snappy, value: store.revision)
    }

    enum Entry: Identifiable {
        case item(Item)
        case phone(PhoneEvent)

        var id: String {
            switch self {
            case .item(let item): item.id.uuidString
            case .phone(let event): "phone-\(event.id)"
            }
        }

        var sortDate: Date {
            switch self {
            case .item(let item): item.hasTime || item.isEvent ? (item.due ?? .distantFuture) : .distantFuture
            case .phone(let event): event.allDay ? .distantPast : event.start
            }
        }
    }

    /// Today's timed things in order, then the to-dos with no particular time.
    private func timeline(today: [Item], phone: [PhoneEvent]) -> [Entry] {
        (today.map(Entry.item) + phone.map(Entry.phone)).sorted { $0.sortDate < $1.sortDate }
    }
}

/// Date and a progress ring at the top of Today.
struct DayHeader: View {
    let now: Date
    let remaining: Int
    let done: Int

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            ZStack {
                Circle().stroke(Color.accentColor.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(done)")
                    .font(.headline.monospacedDigit())
            }
            .frame(width: 46, height: 46)
            .animation(.snappy, value: progress)
            .accessibilityLabel("\(done) done today")
        }
    }

    private var progress: Double {
        let total = remaining + done
        return total == 0 ? 0 : Double(done) / Double(total)
    }

    private var summary: String {
        switch (remaining, done) {
        case (0, 0): "A clear day"
        case (0, _): "All done. Nice."
        case (1, _): "1 thing to do"
        default: "\(remaining) things to do"
        }
    }
}

extension View {
    /// Swipe right to tick off, left for tomorrow or delete.
    func itemSwipes(_ item: Item) -> some View {
        let store = AgendaStore.shared
        return self
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !item.isEvent {
                    Button(item.isDone ? "Undo" : "Done", systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark") {
                        withAnimation { store.setDone(item.id, !item.isDone) }
                    }
                    .tint(.green)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    withAnimation { store.delete(item.id) }
                }
                if !item.isDone && !item.isEvent {
                    Button("Tomorrow", systemImage: "arrow.right") {
                        withAnimation { store.moveToTomorrow([item.id]) }
                    }
                    .tint(.indigo)
                }
            }
            .contextMenu {
                if !item.isEvent {
                    Button(item.isDone ? "Mark as not done" : "Done", systemImage: "checkmark") { store.setDone(item.id, !item.isDone) }
                    Button("Tomorrow", systemImage: "arrow.right") { store.moveToTomorrow([item.id]) }
                    Button(item.flagged ? "Not important" : "Important", systemImage: "flag") {
                        var copy = item
                        copy.flagged.toggle()
                        store.update(copy)
                    }
                }
                Button("Edit", systemImage: "pencil") { Router.shared.sheet = .item(item.id) }
                Button("Delete", systemImage: "trash", role: .destructive) { store.delete(item.id) }
            }
    }
}
