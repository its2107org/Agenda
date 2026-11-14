import SwiftUI
import UIKit

/// Pretend data for the screenshots taken on the build computer. Never used on a real phone.
@MainActor
enum Demo {
    static let args = ProcessInfo.processInfo.arguments
    static var isOn: Bool { args.contains("-StaysDemo") }
    static var addQuery: String? { isOn && args.contains("-StaysDemoSearch") ? "Savoy London" : nil }
    static var foundPhotos: [PhotoFinder.Found]? { nil }
    static var addDraft: Hotel? {
        guard isOn, args.contains("-StaysDemoAddDetails") else { return nil }
        return Hotel(name: "The Ritz London", city: "London", country: "United Kingdom", address: "150 Piccadilly, London W1J 9BR",
                     latitude: 51.5070, longitude: -0.1416, website: URL(string: "https://www.theritzlondon.com"), addedBy: UUID())
    }

    struct Sample {
        let name, city, country, address: String
        let lat, lon: Double
        let site: String
        let monthsAgo: Int
        let ian: [Dimension: Int]
        let sam: [Dimension: Int]
        let ianVerdict, samVerdict: Verdict
        let note: String
    }

    static let samples: [Sample] = [
        Sample(name: "Le Sirenuse", city: "Positano", country: "Italy", address: "Via Cristoforo Colombo 30, Positano", lat: 40.6286, lon: 14.4875,
               site: "https://www.sirenuse.it", monthsAgo: 3,
               ian: [.room: 5, .sleep: 4, .location: 5, .service: 5, .food: 5, .pool: 5, .atmosphere: 5, .value: 3],
               sam: [.room: 5, .sleep: 5, .location: 5, .service: 5, .food: 4, .spa: 4, .pool: 5, .atmosphere: 5, .value: 3],
               ianVerdict: .yes, samVerdict: .yes, note: "Sea-view room on the third floor. Champagne bar at sunset."),
        Sample(name: "The Savoy", city: "London", country: "United Kingdom", address: "Strand, London WC2R 0EZ", lat: 51.5104, lon: -0.1205,
               site: "https://www.thesavoylondon.com", monthsAgo: 7,
               ian: [.room: 4, .sleep: 4, .location: 5, .service: 5, .food: 4, .atmosphere: 4, .value: 3],
               sam: [.room: 4, .sleep: 3, .location: 5, .service: 4, .food: 5, .pool: 3, .atmosphere: 5, .value: 3],
               ianVerdict: .yes, samVerdict: .maybe, note: "Ask for a river view. Beaufort Bar is the highlight."),
        Sample(name: "Aman Tokyo", city: "Tokyo", country: "Japan", address: "The Otemachi Tower, 1-5-6 Otemachi, Chiyoda", lat: 35.6857, lon: 139.7653,
               site: "https://www.aman.com/hotels/aman-tokyo", monthsAgo: 14,
               ian: [.room: 5, .sleep: 5, .location: 4, .service: 5, .food: 4, .spa: 5, .pool: 5, .atmosphere: 4, .value: 3],
               sam: [.room: 5, .sleep: 5, .location: 4, .service: 5, .food: 4, .spa: 5, .pool: 4, .atmosphere: 4, .value: 2],
               ianVerdict: .yes, samVerdict: .yes, note: ""),
        Sample(name: "The Lowell", city: "New York", country: "United States", address: "28 East 63rd Street, New York", lat: 40.7660, lon: -73.9690,
               site: "https://www.lowellhotel.com", monthsAgo: 20,
               ian: [.room: 4, .sleep: 4, .location: 5, .service: 4, .food: 3, .atmosphere: 4, .value: 3],
               sam: [.room: 3, .sleep: 4, .location: 5, .service: 4, .food: 4, .atmosphere: 4],
               ianVerdict: .maybe, samVerdict: .maybe, note: ""),
        Sample(name: "Hôtel du Cap-Eden-Roc", city: "Antibes", country: "France", address: "Boulevard J. F. Kennedy, Antibes", lat: 43.5450, lon: 7.1180,
               site: "https://www.oetkercollection.com/hotels/hotel-du-cap-eden-roc/", monthsAgo: 26,
               ian: [.room: 4, .sleep: 4, .location: 4, .service: 3, .food: 4, .pool: 5, .atmosphere: 5, .value: 2],
               sam: [.room: 4, .sleep: 3, .location: 4, .service: 3, .food: 3, .spa: 3, .pool: 5, .atmosphere: 4, .value: 2],
               ianVerdict: .maybe, samVerdict: .no, note: "Pool cabana worth it. Service was slow.")
    ]

    /// Sets up the pretend list. Returns true if demo mode is on.
    static func runIfRequested() async -> Bool {
        guard isOn else { return false }
        let store = StaysStore.shared
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let library = Library(root: docs.appendingPathComponent("DemoLibrary"), isShared: false)
        let ianID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let samID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let existing = library.readAll().files
        if existing.count < 2 {
            // First run: build the list, with real photos found online (kept for later runs).
            try? FileManager.default.removeItem(at: library.root)
            library.prepare()
            var ian = PersonFile(personID: ianID, name: "Ian")
            var sam = PersonFile(personID: samID, name: "Sam")
            for (i, s) in samples.enumerated() {
                var h = Hotel(name: s.name, city: s.city, country: s.country, address: s.address, latitude: s.lat, longitude: s.lon,
                              website: URL(string: s.site), addedBy: i % 2 == 0 ? ianID : samID,
                              created: Date.now.addingTimeInterval(Double(-i) * 86400))
                h.stayed = Calendar.current.date(byAdding: .month, value: -s.monthsAgo, to: .now)
                let found = await PhotoFinder.find(for: h)
                h.photos = found.prefix(5).compactMap { f in
                    (try? library.savePhoto(f.data)).map { Photo(file: $0, source: f.source) }
                }
                if i % 2 == 0 { ian.hotels.append(h) } else { sam.hotels.append(h) }
                ian.reviews.append(Review(hotelID: h.id, scores: Dictionary(uniqueKeysWithValues: s.ian.map { ($0.key.rawValue, $0.value) }), verdict: s.ianVerdict, note: s.note))
                sam.reviews.append(Review(hotelID: h.id, scores: Dictionary(uniqueKeysWithValues: s.sam.map { ($0.key.rawValue, $0.value) }), verdict: s.samVerdict,
                                          note: i == 1 ? "Breakfast in the Thames Foyer was lovely." : ""))
            }
            try? library.write(ian)
            try? library.write(sam)
        }

        store.resetForTesting(name: "Ian", id: ianID)
        UserDefaults.standard.set(ianID.uuidString, forKey: "stays.me.id")
        UserDefaults.standard.set("Ian", forKey: "stays.me.name")
        store.isSetUp = !args.contains("-StaysDemoWelcome")
        store.load(using: library)
        store.writeSnapshot()

        let router = Router.shared
        let first = store.sorted(store.hotels, by: .best, dimension: nil).first?.id
        if args.contains("-StaysDemoMap") { router.tab = 1 }
        if args.contains("-StaysDemoSettings") { router.tab = 2 }
        if args.contains("-StaysDemoBestPool") { UserDefaults.standard.set("pool", forKey: "stays.sortDimension") } else { UserDefaults.standard.set("", forKey: "stays.sortDimension") }
        if args.contains("-StaysDemoDetail") || args.contains("-StaysDemoRate"), let first { router.path = [first] }
        if args.contains("-StaysDemoSearch") || args.contains("-StaysDemoAddDetails") { router.showAdd = true }
        if args.contains("-StaysDemoInvite") { router.showInvite = true }
        return true
    }

    static var opensRatingEditor: Bool { isOn && args.contains("-StaysDemoRate") }
}
