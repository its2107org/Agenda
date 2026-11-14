import SwiftUI

/// A hotel photo from the list's folder. Shows a soft placeholder until it's on the phone.
struct HotelPhoto: View {
    @Environment(StaysStore.self) private var store
    let photo: Photo?
    var maxPixel: CGFloat = 1400

    var body: some View {
        let _ = store.photoRevision
        if let photo, let image = store.image(photo, maxPixel: maxPixel) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            PlaceholderArt(seed: photo?.file ?? "")
        }
    }
}

/// A quiet gradient used where there's no photo.
struct PlaceholderArt: View {
    let seed: String

    var body: some View {
        let hue = Double(seed.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 360) / 360
        LinearGradient(colors: [Color(hue: hue, saturation: 0.25, brightness: 0.85), Color(hue: hue, saturation: 0.35, brightness: 0.6)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: "building.2")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
            }
    }
}

/// The score in a small rounded badge, e.g. "8.6".
struct ScoreBadge: View {
    let value: Double?
    var large = false

    var body: some View {
        Text(Score.text(value))
            .font(large ? .title2.weight(.bold) : .subheadline.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(value == nil ? Color.secondary : Color.white)
            .padding(.horizontal, large ? 14 : 9)
            .padding(.vertical, large ? 8 : 5)
            .background(value == nil ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(ScoreColour.of(value)), in: .capsule)
    }
}

enum ScoreColour {
    static func of(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        switch value {
        case 8.5...: return Color(red: 0.16, green: 0.58, blue: 0.40)
        case 7..<8.5: return Color(red: 0.36, green: 0.62, blue: 0.30)
        case 5.5..<7: return Color(red: 0.85, green: 0.60, blue: 0.16)
        default: return Color(red: 0.80, green: 0.33, blue: 0.27)
        }
    }
}

/// Five dots, filled up to the score. Read-only.
struct ScoreDots: View {
    let score: Int?
    var size: CGFloat = 7

    var body: some View {
        HStack(spacing: size * 0.55) {
            ForEach(1...5, id: \.self) { i in
                Circle()
                    .fill(score.map { i <= $0 } == true ? Color.accentColor : Color.secondary.opacity(0.22))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityLabel(score.map { "\($0) out of 5" } ?? "Not rated")
    }
}

/// Tap a dot to score 1 to 5; tap the same dot again to clear it.
struct ScorePicker: View {
    @Binding var score: Int?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(1...5, id: \.self) { i in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { score = score == i ? nil : i }
                } label: {
                    Circle()
                        .fill(score.map { i <= $0 } == true ? Color.accentColor : Color.secondary.opacity(0.16))
                        .frame(width: 30, height: 30)
                        .overlay {
                            Text("\(i)")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(score.map { i <= $0 } == true ? Color.white : Color.secondary)
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: score)
                .accessibilityLabel("\(i) out of 5")
            }
        }
    }
}

/// The big photo card on the main list.
struct HotelCard: View {
    @Environment(StaysStore.self) private var store
    let hotel: Hotel
    var dimension: Dimension?

    var body: some View {
        let value = dimension.map { store.merged.score(hotel.id, $0) } ?? store.merged.overall(hotel.id)
        Color.clear
            .aspectRatio(1.45, contentMode: .fit)
            .overlay { HotelPhoto(photo: hotel.photos.first, maxPixel: 1100) }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hotel.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if !hotel.place.isEmpty { Text(hotel.place) }
                        if let stayed = hotel.stayed {
                            Text("·")
                            Text(stayed, format: .dateTime.month(.abbreviated).year())
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(16)
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 6) {
                    ScoreBadge(value: value)
                    if dimension != nil {
                        Label(dimension!.name, systemImage: dimension!.symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.35), in: .capsule)
                    } else {
                        PeopleScores(hotel: hotel)
                    }
                }
                .padding(12)
            }
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
            .contentShape(.rect(cornerRadius: 22))
    }
}

/// "Ian 8.4  Sam 9.0" in tiny type, for the card.
struct PeopleScores: View {
    @Environment(StaysStore.self) private var store
    let hotel: Hotel

    var body: some View {
        let people = store.everyone.filter { store.review(hotel.id, by: $0.id)?.overall != nil }
        if people.count > 1 {
            HStack(spacing: 8) {
                ForEach(people) { p in
                    Text("\(p.name.prefix(1)) \(Score.text(store.review(hotel.id, by: p.id)?.overall))")
                        .monospacedDigit()
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.35), in: .capsule)
        }
    }
}

/// Initials in a coloured circle.
struct Avatar: View {
    let person: Person
    let isMe: Bool
    var size: CGFloat = 26

    var body: some View {
        Text(person.name.prefix(1).uppercased())
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(isMe ? Color.accentColor : Color(red: 0.36, green: 0.47, blue: 0.62), in: .circle)
    }
}

extension View {
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
    }
}
