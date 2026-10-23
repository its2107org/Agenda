import AppIntents
import SwiftUI
import WidgetKit

@main
struct AgendaWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        BrainDumpWidget()
        BrainDumpControl()
        QuickAddControl()
    }
}

// MARK: - Data

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { TodayEntry(date: .now, snapshot: WidgetSample.snapshot) }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        let snapshot = WidgetSnapshot.load()
        completion(TodayEntry(date: .now, snapshot: snapshot.rows.isEmpty && context.isPreview ? WidgetSample.snapshot : snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        // One entry per upcoming time today, so things turn red as they slip. The app refreshes the rest.
        var dates: [Date] = [.now]
        for row in snapshot.rows where row.hasTime {
            if let time = row.time, time > .now, time < .now.addingTimeInterval(12 * 3600) { dates.append(time) }
        }
        let entries = Array(Set(dates)).sorted().prefix(10).map { TodayEntry(date: $0, snapshot: snapshot) }
        let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: Array(entries), policy: .after(min(midnight, .now.addingTimeInterval(2 * 3600)))))
    }
}

enum WidgetSample {
    static let snapshot: WidgetSnapshot = {
        var s = WidgetSnapshot()
        let now = Date()
        s.rows = [
            .init(id: "1", kind: .task, title: "Return the jacket", colour: 3, symbol: "bag.fill", time: nil, hasTime: false, overdue: true),
            .init(id: "2", kind: .task, title: "Send Q3 memo", colour: 0, symbol: "briefcase.fill", time: now.addingTimeInterval(3600), hasTime: true, overdue: false),
            .init(id: "3", kind: .event, title: "Dinner at Via Carota", colour: 1, symbol: "calendar", time: now.addingTimeInterval(5 * 3600), hasTime: true, overdue: false),
            .init(id: "4", kind: .routine, title: "Mounjaro", colour: 4, symbol: "syringe.fill", time: now.addingTimeInterval(6 * 3600), hasTime: true, overdue: false),
            .init(id: "5", kind: .task, title: "Call Mum", colour: 1, symbol: "person.2.fill", time: nil, hasTime: false, overdue: false)
        ]
        s.todayCount = 5
        s.overdueCount = 1
        s.doneToday = 2
        return s
    }()
}

extension WidgetSnapshot.Row {
    func isLate(at date: Date) -> Bool {
        if overdue { return true }
        guard kind != .event, hasTime, let time else { return false }
        return time < date
    }

    func timeText(at date: Date) -> String? {
        guard let time else { return nil }
        let calendar = Calendar.current
        if !calendar.isDate(time, inSameDayAs: date) {
            if calendar.isDate(time, inSameDayAs: date.addingTimeInterval(86400)) {
                return hasTime ? "Tmrw \(time.formatted(date: .omitted, time: .shortened))" : "Tmrw"
            }
            return time > date ? time.formatted(.dateTime.weekday(.abbreviated)) : nil
        }
        return hasTime ? time.formatted(date: .omitted, time: .shortened) : nil
    }
}

// MARK: - Today widget

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Today's to-dos, bookings and reminders. Tick them off right here.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    private var rows: [WidgetSnapshot.Row] { entry.snapshot.rows }
    private var remaining: Int { entry.snapshot.todayCount }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        case .systemSmall: small
        default: list(limit: family == .systemLarge ? 9 : 4)
        }
    }

    private var headline: String {
        if remaining == 0 { return entry.snapshot.doneToday > 0 ? "All done" : "Clear day" }
        return "\(remaining) to do"
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -2) {
                Text("\(remaining)").font(.title2.weight(.bold))
                Image(systemName: entry.snapshot.overdueCount > 0 ? "exclamationmark" : "checklist")
                    .font(.caption2.weight(.bold))
            }
        }
        .widgetURL(URL(string: "agenda://today"))
    }

    private var inline: some View {
        Label(rows.first.map { "\($0.title)\($0.timeText(at: entry.date).map { " · \($0)" } ?? "")" } ?? "Nothing to do",
              systemImage: "checklist")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headline).font(.headline).widgetAccentable()
            ForEach(rows.prefix(2)) { row in
                HStack(spacing: 4) {
                    Image(systemName: row.kind == .event ? "calendar" : (row.isLate(at: entry.date) ? "exclamationmark.circle" : "circle"))
                        .font(.caption2)
                    Text(row.title).lineLimit(1)
                    if let time = row.timeText(at: entry.date) {
                        Spacer(minLength: 2)
                        Text(time).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "agenda://today"))
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.date.formatted(.dateTime.weekday(.abbreviated).day()).uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
                Spacer()
                Link(destination: URL(string: "agenda://dump")!) {
                    Image(systemName: "mic.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor.gradient, in: Circle())
                }
            }
            Text(headline).font(.title3.weight(.bold))
            ForEach(rows.prefix(3)) { row in
                HStack(spacing: 5) {
                    Circle().fill(Palette.colour(row.colour)).frame(width: 6, height: 6)
                    Text(row.title).font(.caption).lineLimit(1)
                        .foregroundStyle(row.isLate(at: entry.date) ? Color.red : .primary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "agenda://today"))
    }

    private func list(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 9 : 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline).font(.headline)
                if entry.snapshot.overdueCount > 0 {
                    Text("\(entry.snapshot.overdueCount) slipped").font(.caption.weight(.semibold)).foregroundStyle(.red)
                }
                Spacer()
                Link(destination: URL(string: "agenda://dump")!) {
                    Label("Brain dump", systemImage: "mic.fill")
                        .labelStyle(.iconOnly)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.gradient, in: Circle())
                }
            }
            if rows.isEmpty {
                Spacer()
                Text("Nothing on. Tap the microphone to add things.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(rows.prefix(limit)) { row in
                    WidgetRowView(row: row, date: entry.date)
                }
                if rows.count > limit {
                    Text("+ \(rows.count - limit) more").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct WidgetRowView: View {
    let row: WidgetSnapshot.Row
    let date: Date

    var body: some View {
        let tint = Palette.colour(row.colour)
        let late = row.isLate(at: date)
        HStack(spacing: 8) {
            if row.kind == .event {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
            } else {
                Button(intent: TickOffIntent(id: row.id, kind: row.kind.rawValue)) {
                    Image(systemName: row.kind == .routine ? "repeat.circle" : "circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(tint)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
            Text(row.title)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(late ? Color.red : .primary)
            Spacer(minLength: 4)
            if let time = row.timeText(at: date) {
                Text(time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(late ? Color.red.opacity(0.8) : .secondary)
            } else if late {
                Text("Late").font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Brain dump button widget

struct BrainDumpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BrainDump", provider: TodayProvider()) { _ in
            VStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor.gradient, in: Circle())
                Text("Brain dump").font(.subheadline.weight(.semibold))
            }
            .widgetURL(URL(string: "agenda://dump"))
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Brain dump")
        .description("One tap to start talking. Agenda turns it into sorted to-dos.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Control Centre and Lock Screen buttons

struct BrainDumpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "BrainDumpControl") {
            ControlWidgetButton(action: BrainDumpIntent()) {
                Label("Brain dump", systemImage: "mic.fill")
            }
        }
        .displayName("Brain dump")
        .description("Opens Agenda and starts listening.")
    }
}

struct QuickAddControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "QuickAddControl") {
            ControlWidgetButton(action: QuickAddIntent()) {
                Label("New to-do", systemImage: "plus.circle")
            }
        }
        .displayName("New to-do")
        .description("Opens Agenda ready to type.")
    }
}
