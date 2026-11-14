import SwiftUI
import WidgetKit

@main
struct StaysWidgets: WidgetBundle {
    var body: some Widget {
        MemoryWidget()
        TopHotelsWidget()
    }
}

// MARK: - Data

struct StaysEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    /// Which hotel the photo widget shows now (it moves through your favourites).
    let index: Int
}

struct StaysProvider: TimelineProvider {
    func placeholder(in context: Context) -> StaysEntry { StaysEntry(date: .now, snapshot: WidgetSample.snapshot, index: 0) }

    func getSnapshot(in context: Context, completion: @escaping (StaysEntry) -> Void) {
        let snap = WidgetSnapshot.load()
        completion(StaysEntry(date: .now, snapshot: snap.rows.isEmpty && context.isPreview ? WidgetSample.snapshot : snap, index: 0))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StaysEntry>) -> Void) {
        let snap = WidgetSnapshot.load()
        let count = max(snap.rows.count, 1)
        // A different hotel every three hours.
        let start = Int(Date().timeIntervalSince1970 / 10_800)
        let entries = (0..<8).map { i in
            StaysEntry(date: Date().addingTimeInterval(Double(i) * 10_800), snapshot: snap, index: (start + i) % count)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

enum WidgetSample {
    static let snapshot: WidgetSnapshot = {
        var s = WidgetSnapshot()
        s.rows = [
            .init(id: "1", name: "Le Sirenuse", place: "Positano, Italy", score: 9.4, thumb: nil),
            .init(id: "2", name: "Aman Tokyo", place: "Tokyo, Japan", score: 9.0, thumb: nil),
            .init(id: "3", name: "The Savoy", place: "London, United Kingdom", score: 8.2, thumb: nil)
        ]
        s.count = 3
        return s
    }()
}

// MARK: - Pieces

private let accent = Color(red: 0.784, green: 0.424, blue: 0.290)

struct ThumbView: View {
    let row: WidgetSnapshot.Row

    var body: some View {
        if let data = row.thumb, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            LinearGradient(colors: [accent.opacity(0.7), accent], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay { Image(systemName: "building.2").font(.title2).foregroundStyle(.white.opacity(0.7)) }
        }
    }
}

struct WidgetScore: View {
    let value: Double?
    var body: some View {
        Text(Score.text(value))
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.35), in: .capsule)
    }
}

func hotelURL(_ row: WidgetSnapshot.Row?) -> URL {
    guard let row else { return URL(string: "stays://add")! }
    return URL(string: "stays://hotel/\(row.id)")!
}

// MARK: - Memory widget (a photo of one of your hotels)

struct MemoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StaysMemory", provider: StaysProvider()) { entry in
            MemoryView(entry: entry)
        }
        .configurationDisplayName("Hotel Memories")
        .description("A photo from one of your favourite stays, changing through the day.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct MemoryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StaysEntry

    var body: some View {
        let rows = entry.snapshot.rows
        let row = rows.isEmpty ? nil : rows[entry.index % rows.count]
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 1) {
                Label("Best stay", systemImage: "building.2").font(.caption2.weight(.semibold))
                Text(rows.first?.name ?? "Add a hotel").font(.headline).lineLimit(1)
                if let first = rows.first { Text("\(Score.text(first.score)) · \(first.place)").font(.caption).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.clear, for: .widget)
            .widgetURL(hotelURL(rows.first))
        } else if let row {
            Color.clear
                .overlay { ThumbView(row: row) }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(family == .systemSmall ? .subheadline.weight(.semibold) : .headline).lineLimit(2)
                        Text(row.place).font(.caption2).opacity(0.85).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                }
                .overlay(alignment: .topTrailing) {
                    if row.score != nil { WidgetScore(value: row.score).padding(10) }
                }
                .containerBackground(.black, for: .widget)
                .widgetURL(hotelURL(row))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "plus.circle.fill").font(.title).foregroundStyle(accent)
                Text("Add a hotel").font(.footnote.weight(.medium))
            }
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: "stays://add"))
        }
    }
}

// MARK: - Top hotels widget

struct TopHotelsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StaysTop", provider: StaysProvider()) { entry in
            TopHotelsView(entry: entry)
        }
        .configurationDisplayName("Our Best Hotels")
        .description("Your best-rated hotels, from both of your scores.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TopHotelsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StaysEntry

    var body: some View {
        let rows = Array(entry.snapshot.rows.prefix(family == .systemLarge ? 6 : 3))
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 7) {
            HStack {
                Text("Our best hotels").font(.subheadline.weight(.semibold))
                Spacer()
                Link(destination: URL(string: "stays://add")!) {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(accent)
                }
            }
            if rows.isEmpty {
                Spacer()
                Text("Hotels you rate show up here.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    Link(destination: hotelURL(row)) {
                        HStack(spacing: 10) {
                            ThumbView(row: row)
                                .frame(width: family == .systemLarge ? 44 : 30, height: family == .systemLarge ? 44 : 30)
                                .clipShape(.rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(row.name).font(.footnote.weight(.semibold)).lineLimit(1)
                                if family == .systemLarge || i == 0 {
                                    Text(row.place).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            Text(Score.text(row.score))
                                .font(.footnote.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(accent)
                        }
                    }
                }
                if family == .systemLarge { Spacer(minLength: 0) }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
