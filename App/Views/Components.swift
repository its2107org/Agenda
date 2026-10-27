import SwiftUI

// MARK: - Dates in plain words

enum DateWords {
    /// "3:00 pm", "Tomorrow", "Tomorrow 3:00 pm", "Fri 31 Oct", "Fri 31 Oct, 3:00 pm".
    static func short(_ date: Date, hasTime: Bool, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return hasTime ? time : "Today" }
        if calendar.isDateInTomorrow(date) { return hasTime ? "Tomorrow \(time)" : "Tomorrow" }
        if calendar.isDateInYesterday(date) { return hasTime ? "Yesterday \(time)" : "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let day: String
        if days > 0 && days < 7 {
            day = date.formatted(.dateTime.weekday(.wide))
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        } else {
            day = date.formatted(.dateTime.day().month(.abbreviated).year())
        }
        return hasTime ? "\(day), \(time)" : day
    }

    static func dayHeading(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func range(_ item: Item) -> String? {
        guard let start = item.due else { return nil }
        if item.isEvent, let end = item.end {
            let calendar = Calendar.current
            if !item.hasTime {
                let last = end.addingTimeInterval(-1)
                return calendar.isDate(start, inSameDayAs: last) ? short(start, hasTime: false)
                    : "\(short(start, hasTime: false)) – \(short(last, hasTime: false))"
            }
            if calendar.isDate(start, inSameDayAs: end) {
                return "\(short(start, hasTime: true)) – \(end.formatted(date: .omitted, time: .shortened))"
            }
            return "\(short(start, hasTime: true)) – \(short(end, hasTime: true))"
        }
        return short(start, hasTime: item.hasTime)
    }
}

// MARK: - The tick circle

struct CheckCircle: View {
    var done: Bool
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(done ? tint : tint.opacity(0.55), lineWidth: 2)
                    .background(Circle().fill(done ? tint : .clear))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle().inset(by: -10))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: done) { _, new in new }
        .accessibilityLabel(done ? "Done" : "Not done")
    }
}

// MARK: - Rows

struct ItemRow: View {
    let item: Item
    var showCategory = true
    var showDate = true
    var overdue = false
    private var store: AgendaStore { .shared }

    var body: some View {
        let category = store.category(item.categoryID)
        HStack(alignment: .top, spacing: 12) {
            if item.isEvent {
                Image(systemName: "calendar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(category.tint)
                    .frame(width: 24, height: 24)
                    .background(category.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.top, 1)
            } else {
                CheckCircle(done: item.isDone, tint: category.tint) {
                    withAnimation(.snappy) { store.setDone(item.id, !item.isDone) }
                }
                .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                        .strikethrough(item.isDone, color: .secondary)
                    if item.flagged && !item.isDone {
                        Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                let details = detailLine(category: category)
                if !details.isEmpty {
                    Text(details)
                        .font(.footnote)
                        .foregroundStyle(overdue ? Color.red.opacity(0.9) : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { Router.shared.sheet = .item(item.id) }
    }

    private func detailLine(category: Category) -> String {
        var parts: [String] = []
        if showDate, let when = DateWords.range(item) { parts.append(when) }
        if !item.location.isEmpty { parts.append(item.location) }
        if showCategory { parts.append(category.name) }
        parts += item.tagList.map { "#\($0)" }
        if parts.isEmpty, !item.notes.isEmpty { parts.append(item.notes) }
        return parts.joined(separator: " · ")
    }
}

struct PhoneEventRow: View {
    let event: PhoneEvent
    var showDay = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.colour.map { Color(cgColor: $0) } ?? .gray)
                .frame(width: 4, height: 30)
                .padding(.horizontal, 10)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                Text(details).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var details: String {
        var parts: [String] = []
        if event.allDay {
            parts.append(showDay ? DateWords.short(event.start, hasTime: false) : "All day")
        } else {
            let start = showDay ? DateWords.short(event.start, hasTime: true) : event.start.formatted(date: .omitted, time: .shortened)
            parts.append("\(start) – \(event.end.formatted(date: .omitted, time: .shortened))")
        }
        if !event.location.isEmpty { parts.append(event.location) }
        parts.append(event.calendarName)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct RoutineRow: View {
    let routine: Routine
    var compact = false
    private var store: AgendaStore { .shared }
    @State private var completing: Routine?

    var body: some View {
        let category = store.category(routine.categoryID)
        let due = routine.isDue()
        HStack(spacing: 12) {
            Image(systemName: routine.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background((due ? Color.red : category.tint).gradient, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.title).font(.body.weight(.medium))
                Text(statusLine)
                    .font(.footnote)
                    .foregroundStyle(due ? .red : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !routine.isPaused {
                Button {
                    if routine.trackSites || (isEvery && Date().timeIntervalSince(routine.nextDue) > 3600) {
                        completing = routine
                    } else {
                        withAnimation(.snappy) { _ = store.markRoutineDone(routine.id) }
                    }
                } label: {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(due ? .green : .secondary)
                .sensoryFeedback(.success, trigger: routine.lastDone)
            }
        }
        .padding(.vertical, compact ? 0 : 2)
        .contentShape(Rectangle())
        .onTapGesture { Router.shared.sheet = .routine(routine.id) }
        .sheet(item: $completing) { routine in
            RoutineDoneSheet(routine: routine)
                .presentationDetents([.medium, .large])
        }
    }

    private var isEvery: Bool {
        if case .every = routine.schedule { return true }
        return false
    }

    private var statusLine: String {
        if routine.isPaused { return "Paused" }
        if routine.isDue() {
            return "Due \(DateWords.short(routine.nextDue, hasTime: true).lowercasedFirst)"
        }
        var text = DateWords.short(routine.nextDue, hasTime: true)
        if compact { return text }
        text += " · \(routine.schedule.summary)"
        return text
    }
}

extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        // Keep "Fri" capitalised; only lower words like "Today" / "Tomorrow".
        if ["Today", "Tomorrow", "Yesterday"].contains(where: { hasPrefix($0) }) { return first.lowercased() + dropFirst() }
        return self
    }
}

// MARK: - Bits and pieces

struct CategoryIcon: View {
    let category: Category
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(category.tint.gradient, in: Circle())
    }
}

struct SectionTitle: View {
    let text: String
    var colour: Color = .primary
    var trailing: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(text)
                .font(.title3.weight(.bold))
                .foregroundStyle(colour)
                .textCase(nil)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action)
                    .font(.subheadline.weight(.medium))
                    .textCase(nil)
            }
        }
    }
}

struct EmptyNote: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
