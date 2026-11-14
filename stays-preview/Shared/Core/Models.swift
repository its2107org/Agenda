import Foundation

// MARK: - What gets rated

/// The things each of you can score a hotel on. Any of them can be left blank ("didn't use it").
enum Dimension: String, Codable, CaseIterable, Identifiable, Sendable {
    case room, sleep, location, service, food, spa, pool, atmosphere, value

    var id: String { rawValue }

    var name: String {
        switch self {
        case .room: "Room"
        case .sleep: "Sleep"
        case .location: "Location"
        case .service: "Service"
        case .food: "Food & drink"
        case .spa: "Spa"
        case .pool: "Pool"
        case .atmosphere: "Atmosphere"
        case .value: "Value"
        }
    }

    /// A few words under the name, so you both score the same thing.
    var hint: String {
        switch self {
        case .room: "Size, view, design, bathroom"
        case .sleep: "Bed, quiet, blackout"
        case .location: "Area, getting around"
        case .service: "Staff, check-in, little touches"
        case .food: "Breakfast, restaurant, bar"
        case .spa: "Treatments, sauna, gym"
        case .pool: "Pool, loungers, setting"
        case .atmosphere: "Feel, crowd, style"
        case .value: "Worth the price?"
        }
    }

    var symbol: String {
        switch self {
        case .room: "bed.double.fill"
        case .sleep: "moon.zzz.fill"
        case .location: "mappin.and.ellipse"
        case .service: "bell.fill"
        case .food: "fork.knife"
        case .spa: "leaf.fill"
        case .pool: "figure.pool.swim"
        case .atmosphere: "sparkles"
        case .value: "tag.fill"
        }
    }
}

/// Would you go back?
enum Verdict: String, Codable, CaseIterable, Sendable {
    case yes, maybe, no

    var label: String {
        switch self {
        case .yes: "Would go back"
        case .maybe: "Maybe"
        case .no: "Wouldn't go back"
        }
    }

    var short: String {
        switch self {
        case .yes: "Yes"
        case .maybe: "Maybe"
        case .no: "No"
        }
    }

    var symbol: String {
        switch self {
        case .yes: "hand.thumbsup.fill"
        case .maybe: "hand.raised.fill"
        case .no: "hand.thumbsdown.fill"
        }
    }
}

// MARK: - Saved data

struct Photo: Codable, Hashable, Identifiable, Sendable {
    /// File name inside the list's photos folder.
    var file: String
    /// Where it came from ("Hotel website", "Wikipedia", "Look Around", "Your photo").
    var source: String
    var id: String { file }
}

struct Hotel: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var city: String
    var country: String
    var address: String
    var latitude: Double?
    var longitude: Double?
    var website: URL?
    var phone: String?
    /// Apple Maps' own id for the place, when it has one.
    var mapsID: String?
    var photos: [Photo]
    /// When you stayed (month is enough).
    var stayed: Date?
    var addedBy: UUID
    var created: Date
    var updated: Date
    var deleted: Bool

    init(id: UUID = UUID(), name: String, city: String = "", country: String = "", address: String = "",
         latitude: Double? = nil, longitude: Double? = nil, website: URL? = nil, phone: String? = nil,
         mapsID: String? = nil, photos: [Photo] = [], stayed: Date? = nil, addedBy: UUID,
         created: Date = .now, updated: Date = .now, deleted: Bool = false) {
        self.id = id
        self.name = name
        self.city = city
        self.country = country
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.website = website
        self.phone = phone
        self.mapsID = mapsID
        self.photos = photos
        self.stayed = stayed
        self.addedBy = addedBy
        self.created = created
        self.updated = updated
        self.deleted = deleted
    }

    var place: String {
        [city, country].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// One person's scores for one hotel.
struct Review: Codable, Hashable, Sendable {
    var hotelID: UUID
    /// Dimension id to a score from 1 to 5. Missing means "not rated / didn't use it".
    var scores: [String: Int]
    var verdict: Verdict?
    var note: String
    var updated: Date

    init(hotelID: UUID, scores: [String: Int] = [:], verdict: Verdict? = nil, note: String = "", updated: Date = .now) {
        self.hotelID = hotelID
        self.scores = scores
        self.verdict = verdict
        self.note = note
        self.updated = updated
    }

    func score(_ d: Dimension) -> Int? { scores[d.rawValue] }

    var isEmpty: Bool { scores.isEmpty && verdict == nil && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Average of the rated dimensions, on a 10-point scale.
    var overall: Double? { Score.overall(scores) }
}

/// Everything one person has written. Each of you only ever writes your own file, so two phones
/// saving at once can never overwrite each other.
struct PersonFile: Codable, Sendable {
    var format: Int = 1
    var personID: UUID
    var name: String
    var hotels: [Hotel]
    var reviews: [Review]
    var updated: Date

    init(personID: UUID, name: String, hotels: [Hotel] = [], reviews: [Review] = [], updated: Date = .now) {
        self.personID = personID
        self.name = name
        self.hotels = hotels
        self.reviews = reviews
        self.updated = updated
    }
}

struct Person: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
}

// MARK: - Maths

enum Score {
    /// Average of 1-5 scores, shown on a 10-point scale (5 stars = 10).
    static func overall(_ scores: [String: Int]) -> Double? {
        let values = scores.values.filter { (1...5).contains($0) }
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count) * 2
    }

    static func average(_ values: [Double?]) -> Double? {
        let v = values.compactMap { $0 }
        guard !v.isEmpty else { return nil }
        return v.reduce(0, +) / Double(v.count)
    }

    /// "8.4", or "–" when nothing's rated.
    static func text(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_GB")))
    }
}

/// The combined view of everyone's files.
struct Merged: Sendable {
    var hotels: [Hotel]
    var people: [Person]
    /// hotel id -> person id -> review
    var reviews: [UUID: [UUID: Review]]

    static func build(_ files: [PersonFile]) -> Merged {
        var latest: [UUID: Hotel] = [:]
        var reviews: [UUID: [UUID: Review]] = [:]
        var people: [Person] = []
        for file in files {
            people.append(Person(id: file.personID, name: file.name))
            for hotel in file.hotels {
                // Whoever changed a hotel last wins (each edit saves a full copy of it).
                if let current = latest[hotel.id], current.updated >= hotel.updated { continue }
                latest[hotel.id] = hotel
            }
            for review in file.reviews {
                reviews[review.hotelID, default: [:]][file.personID] = review
            }
        }
        let hotels = latest.values.filter { !$0.deleted }.sorted { $0.created > $1.created }
        let unique = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values
        return Merged(hotels: hotels, people: unique.sorted { $0.name < $1.name }, reviews: reviews)
    }

    func overall(_ hotel: UUID) -> Double? {
        Score.average((reviews[hotel] ?? [:]).values.map(\.overall))
    }

    func score(_ hotel: UUID, _ d: Dimension) -> Double? {
        Score.average((reviews[hotel] ?? [:]).values.map { $0.score(d).map { Double($0) * 2 } })
    }
}

// MARK: - Widget

/// What the widgets show, saved by the app in the shared keychain space.
struct WidgetSnapshot: Codable, Sendable {
    struct Row: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var place: String
        var score: Double?
        /// A small JPEG of the hotel's first photo.
        var thumb: Data?
    }

    var rows: [Row] = []
    var count: Int = 0
    var updated: Date = .now

    static let service = "stays.widget"

    static func load() -> WidgetSnapshot {
        guard let data = SharedVault.read(service: service, account: "snapshot"),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return WidgetSnapshot() }
        return snap
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        SharedVault.write(data, service: Self.service, account: "snapshot")
    }
}
