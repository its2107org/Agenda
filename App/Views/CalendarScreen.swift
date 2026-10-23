import SwiftUI

/// A month at a glance with coloured dots, and everything on the chosen day underneath.
struct CalendarScreen: View {
    private var store: AgendaStore { .shared }
    @State private var calendarLink = CalendarLink.shared
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            let _ = store.revision
            List {
                Section {
                    MonthGrid(month: $month, selected: $selected,
                              dots: dots(for: month))
                        .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 12, trailing: 10))
                }
                dayList
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Today") {
                        withAnimation(.snappy) {
                            selected = calendar.startOfDay(for: Date())
                            month = calendar.dateInterval(of: .month, for: Date())!.start
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add on this day", systemImage: "plus") {
                        var item = Item(title: "", categoryID: "personal")
                        item.due = selected
                        pendingNew = item
                    }
                }
            }
            .task { await calendarLink.refresh() }
            .refreshable { await calendarLink.refresh() }
            .sheet(item: $pendingNew) { item in
                ItemEditor(item: item, isNew: true)
            }
        }
    }

    @State private var pendingNew: Item?

    @ViewBuilder
    private var dayList: some View {
        let items = store.items(on: selected)
        let routines = store.routineTimes(on: selected)
        let phone = calendarLink.events(on: selected)
        Section {
            if items.isEmpty && routines.isEmpty && phone.isEmpty {
                Text("Nothing on.")
                    .foregroundStyle(.secondary)
            }
            ForEach(phone.filter(\.allDay)) { PhoneEventRow(event: $0) }
            ForEach(entries(items: items, routines: routines, phone: phone.filter { !$0.allDay })) { entry in
                switch entry.kind {
                case .item(let item): ItemRow(item: item, showDate: item.hasTime || item.isEvent).itemSwipes(item)
                case .routine(let routine, let at): RoutineOccurrenceRow(routine: routine, at: at)
                case .phone(let event): PhoneEventRow(event: event)
                }
            }
        } header: {
            SectionTitle(text: When.dayHeading(selected))
        }
    }

    struct Entry: Identifiable {
        enum Kind {
            case item(Item)
            case routine(Routine, Date)
            case phone(PhoneEvent)
        }
        var id: String
        var date: Date
        var kind: Kind
    }

    private func entries(items: [Item], routines: [(Routine, Date)], phone: [PhoneEvent]) -> [Entry] {
        var result: [Entry] = []
        for item in items {
            let date = (item.hasTime || item.isEvent) ? (item.due ?? .distantFuture) : .distantFuture
            result.append(Entry(id: item.id.uuidString, date: date, kind: .item(item)))
        }
        for (routine, at) in routines {
            result.append(Entry(id: "\(routine.id)-\(at.timeIntervalSince1970)", date: at, kind: .routine(routine, at)))
        }
        for event in phone {
            result.append(Entry(id: "phone-\(event.id)", date: event.start, kind: .phone(event)))
        }
        return result.sorted { $0.date < $1.date }
    }

    private func dots(for month: Date) -> [Date: [Int]] {
        let start = calendar.date(byAdding: .day, value: -7, to: month)!
        let end = calendar.date(byAdding: .day, value: 45, to: month)!
        var result = store.busyDays(from: start, to: end)
        for event in calendarLink.events where event.start >= start && event.start < end {
            result[calendar.startOfDay(for: event.start), default: []].append(9)
        }
        return result
    }
}

struct RoutineOccurrenceRow: View {
    let routine: Routine
    let at: Date
    private var store: AgendaStore { .shared }

    var body: some View {
        let category = store.category(routine.categoryID)
        HStack(spacing: 12) {
            Image(systemName: routine.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(category.tint.gradient, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.title)
                Text("\(at.formatted(date: .omitted, time: .shortened)) · \(routine.schedule.summary)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { Router.shared.sheet = .routine(routine.id) }
    }
}

struct MonthGrid: View {
    @Binding var month: Date
    @Binding var selected: Date
    let dots: [Date: [Int]]

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    shift(-1)
                } label: {
                    Image(systemName: "chevron.left").font(.headline).frame(width: 36, height: 36)
                }
                .accessibilityLabel("Previous month")
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()
                Button {
                    shift(1)
                } label: {
                    Image(systemName: "chevron.right").font(.headline).frame(width: 36, height: 36)
                }
                .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            let symbols = weekdaySymbols
            HStack(spacing: 0) {
                ForEach(symbols.indices, id: \.self) { index in
                    Text(symbols[index])
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < -40 { shift(1) }
            if value.translation.width > 40 { shift(-1) }
        })
    }

    private func dayCell(_ day: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let isToday = calendar.isDateInToday(day)
        let colours = Array(Set(dots[calendar.startOfDay(for: day)] ?? [])).sorted().prefix(3)
        return Button {
            withAnimation(.snappy) { selected = day }
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout.weight(isToday || isSelected ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white : (isToday ? Color.accentColor : (inMonth ? .primary : .secondary.opacity(0.5))))
                    .frame(width: 34, height: 34)
                    .background {
                        if isSelected { Circle().fill(Color.accentColor.gradient) }
                    }
                HStack(spacing: 3) {
                    ForEach(Array(colours), id: \.self) { colour in
                        Circle().fill(Palette.colour(colour)).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
                .opacity(inMonth ? 1 : 0.4)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var days: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let lead = (firstWeekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: interval.start)!
        let count = calendar.range(of: .day, in: .month, for: month)!.count
        let cells = Int(ceil(Double(lead + count) / 7)) * 7
        return (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func shift(_ months: Int) {
        withAnimation(.snappy) {
            month = calendar.date(byAdding: .month, value: months, to: month)!
            if !calendar.isDate(selected, equalTo: month, toGranularity: .month) {
                selected = calendar.isDate(Date(), equalTo: month, toGranularity: .month) ? calendar.startOfDay(for: Date()) : month
            }
        }
    }
}
