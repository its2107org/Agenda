import Foundation
import MapKit
import UIKit

/// Checks run on the build computer (launched with -StaysSelfTest). Results go to selftest.json.
@MainActor
enum SelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-StaysSelfTest") }

    private static var results: [[String: Any]] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        results.append(["check": name, "ok": ok, "detail": detail])
        if !ok { failures += 1 }
    }

    private static func info(_ name: String, _ detail: String) {
        results.append(["check": name, "info": detail])
    }

    static func runIfRequested() async -> Bool {
        guard isRequested else { return false }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Scores
        check("overall of 5,4,3 is 8.0", Score.overall(["room": 5, "sleep": 4, "value": 3]) == 8.0)
        check("skipped dimensions don't count", Score.overall(["room": 5]) == 10.0)
        check("nothing rated has no score", Score.overall([:]) == nil)
        check("score text", Score.text(8.25) == "8.2" || Score.text(8.25) == "8.3")
        check("score text when empty", Score.text(nil) == "–")

        // Merging two people's files
        let a = UUID(), b = UUID()
        let old = Date(timeIntervalSince1970: 1_700_000_000), new = old.addingTimeInterval(60)
        let h1 = Hotel(name: "One", addedBy: a, created: old, updated: old)
        var h1edited = h1; h1edited.name = "One (renamed)"; h1edited.updated = new
        let h2 = Hotel(name: "Two", addedBy: b, created: new, updated: new)
        var h2deleted = h2; h2deleted.deleted = true; h2deleted.updated = new.addingTimeInterval(5)
        let fa = PersonFile(personID: a, name: "Ian", hotels: [h1, h2deleted], reviews: [Review(hotelID: h1.id, scores: ["room": 5, "pool": 3])])
        let fb = PersonFile(personID: b, name: "Sam", hotels: [h1edited, h2], reviews: [Review(hotelID: h1.id, scores: ["room": 3])])
        let m = Merged.build([fa, fb])
        check("merge keeps one copy per hotel", m.hotels.count == 1, "\(m.hotels.map(\.name))")
        check("latest edit wins", m.hotels.first?.name == "One (renamed)")
        check("deleting removes for both", !m.hotels.contains { $0.id == h2.id })
        check("each person's review kept", m.reviews[h1.id]?.count == 2)
        check("combined overall", m.overall(h1.id) == 7.0, "\(String(describing: m.overall(h1.id)))")
        check("combined per dimension", m.score(h1.id, .room) == 8.0 && m.score(h1.id, .pool) == 6.0 && m.score(h1.id, .spa) == nil)
        check("both people listed", m.people.count == 2)
        let reversed = Merged.build([fb, fa])
        check("merge order doesn't matter", reversed.hotels.map(\.name) == m.hotels.map(\.name))

        // Files on disk
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stays-test-\(UUID().uuidString)")
        let lib = Library(root: tmp, isShared: false)
        do {
            try lib.write(fa)
            try lib.write(fb)
            let read = lib.readAll()
            check("files read back", read.files.count == 2 && read.waiting == 0)
            let back = read.files.first { $0.personID == a }
            check("file content survives", back?.hotels.count == 2 && back?.reviews.first?.scores["room"] == 5)
            try "x".write(to: lib.peopleFolder.appendingPathComponent(".someone.json.icloud"), atomically: true, encoding: .utf8)
            check("iCloud placeholders noticed", lib.readAll().waiting == 1)
            let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).jpegData(withCompressionQuality: 0.8) { ctx in
                UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            }
            let name = try lib.savePhoto(jpeg)
            check("photo saved and loaded", lib.photoData(name)?.count == jpeg.count)
        } catch {
            check("files on disk", false, error.localizedDescription)
        }
        check("placeholder name", Library.placeholderTarget(".abc.json.icloud") == "abc.json" && Library.placeholderTarget("abc.json") == nil)

        // The store, end to end (in a scratch folder)
        let store = StaysStore.shared
        let storeLib = Library(root: tmp.appendingPathComponent("store"), isShared: false)
        store.resetForTesting(name: "Ian")
        store.load(using: storeLib)
        let added = store.add(Hotel(name: "Test Hotel", city: "Rome", addedBy: UUID()), photos: [])
        var r = store.myReview(added.id); r.scores["room"] = 4; r.verdict = .yes
        store.setMyReview(r)
        check("store adds and rates", store.hotels.count == 1 && store.merged.overall(added.id) == 8.0)
        // Someone else's file turns up (as if iCloud synced it).
        try? lib.write(PersonFile(personID: b, name: "Sam", hotels: [], reviews: []))
        try? storeLib.write(PersonFile(personID: b, name: "Sam", hotels: [], reviews: [Review(hotelID: added.id, scores: ["room": 2])]))
        store.refresh()
        check("partner's scores picked up", store.partner?.name == "Sam" && store.merged.overall(added.id) == 6.0)
        store.delete(added.id)
        check("store deletes", store.hotels.isEmpty)
        let snap = WidgetSnapshot.load()
        check("widget snapshot written", snap.count == 0)

        // Reading web pages for photos
        let html = """
        <html><head><meta property="og:image" content="/img/hero.jpg"><meta name="twitter:image" content="https://cdn.example.com/t.jpg">
        <link rel="icon" href="/favicon.png"></head><body>
        <img src="/logo.png"><img srcset="/a-400.jpg 400w, /a-1600.jpg 1600w" src="/a-400.jpg">
        <div style="background-image: url('/bg/pool.jpg')"></div></body></html>
        """
        let base = URL(string: "https://hotel.example.com/en/")!
        let urls = PhotoFinder.imageCandidates(in: html, base: base).map(\.absoluteString)
        check("share image found first", urls.first == "https://hotel.example.com/img/hero.jpg", urls.joined(separator: " "))
        check("widest srcset picture chosen", urls.contains("https://hotel.example.com/a-1600.jpg") && !urls.contains("https://hotel.example.com/a-400.jpg"))
        check("background pictures found", urls.contains("https://hotel.example.com/bg/pool.jpg"))
        check("logos skipped", !urls.contains { $0.contains("logo") || $0.contains("favicon") })
        check("name words", PhotoFinder.significantWords("The Savoy") == ["savoy"] && PhotoFinder.significantWords("Hôtel du Cap-Eden-Roc") == ["cap", "eden", "roc"])
        check("name matching", PhotoFinder.matchesName("File:The Savoy Hotel, Strand.jpg", ["savoy"]) && !PhotoFinder.matchesName("Strand", ["savoy"]))

        // Real photo search, online
        let savoy = Hotel(name: "The Savoy", city: "London", latitude: 51.5104, longitude: -0.1205,
                          website: URL(string: "https://www.thesavoylondon.com"), addedBy: a)
        let started = Date()
        let found = await PhotoFinder.find(for: savoy)
        let sources = Dictionary(grouping: found, by: \.source).mapValues(\.count)
        check("photos found online for The Savoy", !found.isEmpty, "\(found.count) in \(Int(Date().timeIntervalSince(started)))s: \(sources)")
        for (i, f) in found.prefix(6).enumerated() {
            try? f.data.write(to: docs.appendingPathComponent("found-savoy-\(i)-\(f.source.replacingOccurrences(of: " ", with: "")).jpg"))
        }
        let site = await PhotoFinder.fromWebsite(URL(string: "https://www.thesavoylondon.com"))
        info("Savoy website photos", "\(site.count)")
        let wiki = await PhotoFinder.fromWikimedia(savoy)
        check("Wikipedia photos found", !wiki.isEmpty, "\(wiki.count)")
        let ritz = await PhotoFinder.find(for: Hotel(name: "The Ritz London", city: "London", latitude: 51.5070, longitude: -0.1416,
                                                      website: URL(string: "https://www.theritzlondon.com"), addedBy: a))
        info("Ritz photos", "\(Dictionary(grouping: ritz, by: \.source).mapValues(\.count))")

        // Apple Maps search (the build computer may not reach it, so this is information only)
        do {
            let items = try await HotelSearch.search("The Savoy London")
            let first = items.first.map { HotelSearch.draft(from: $0, by: a) }
            info("Maps search", "\(items.count) results; first: \(first?.name ?? "-"), \(first?.city ?? "-"), site \(first?.website?.absoluteString ?? "-")")
            if let first {
                let photos = await PhotoFinder.find(for: first)
                info("photos for Maps result", "\(Dictionary(grouping: photos, by: \.source).mapValues(\.count))")
            }
        } catch {
            info("Maps search", "failed: \(error.localizedDescription)")
        }

        // Write the report
        let summary = failures == 0 ? "all passed" : "\(failures) failed"
        let report: [String: Any] = ["summary": summary, "results": results]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: docs.appendingPathComponent("selftest.json"))
        }
        try? FileManager.default.removeItem(at: tmp)
        return true
    }
}
