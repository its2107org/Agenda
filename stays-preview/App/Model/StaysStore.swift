import Foundation
import Observation
import SwiftUI
import UIKit
import WidgetKit

@MainActor
@Observable
final class StaysStore {
    static let shared = StaysStore()

    private(set) var library: Library = .local
    private(set) var mine: PersonFile
    private(set) var others: [PersonFile] = []
    private(set) var merged = Merged(hotels: [], people: [], reviews: [:])
    /// Files iCloud is still bringing down.
    private(set) var waiting = 0
    /// Goes up whenever photos may have arrived, so pictures redraw.
    private(set) var photoRevision = 0
    private(set) var lastError: String?

    var isSetUp: Bool {
        didSet { UserDefaults.standard.set(isSetUp, forKey: "stays.setUp") }
    }

    private let imageCache = NSCache<NSString, UIImage>()

    init() {
        let defaults = UserDefaults.standard
        let id: UUID
        if let s = defaults.string(forKey: "stays.me.id"), let u = UUID(uuidString: s) {
            id = u
        } else {
            id = UUID()
            defaults.set(id.uuidString, forKey: "stays.me.id")
        }
        mine = PersonFile(personID: id, name: defaults.string(forKey: "stays.me.name") ?? "")
        isSetUp = defaults.bool(forKey: "stays.setUp")
    }

    // MARK: People

    var me: Person { Person(id: mine.personID, name: mine.name.isEmpty ? "Me" : mine.name) }

    var partner: Person? {
        merged.people.first { $0.id != mine.personID }
    }

    /// Me first, then the other person.
    var everyone: [Person] {
        [me] + merged.people.filter { $0.id != mine.personID }
    }

    func setName(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        mine.name = clean
        UserDefaults.standard.set(clean, forKey: "stays.me.name")
        save()
    }

    // MARK: Loading and saving

    func load(using override: Library? = nil) {
        if let override {
            library = override
        } else if let shared = Library.openShared() {
            library = shared
        } else {
            library = .local
        }
        library.prepare()
        refresh()
    }

    /// Reads everyone's files again (picks up the other person's changes).
    func refresh() {
        let result = library.readAll()
        waiting = result.waiting
        if let saved = result.files.first(where: { $0.personID == mine.personID }), saved.updated > mine.updated || mine.hotels.isEmpty && mine.reviews.isEmpty {
            let name = mine.name
            mine = saved
            if !name.isEmpty { mine.name = name }
        }
        others = result.files.filter { $0.personID != mine.personID }
        rebuild()
        photoRevision += 1
    }

    private func rebuild() {
        merged = Merged.build([mine] + others)
    }

    func save() {
        mine.updated = .now
        do {
            try library.write(mine)
            lastError = nil
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
        rebuild()
        writeSnapshot()
    }

    // MARK: Hotels

    var hotels: [Hotel] { merged.hotels }

    func hotel(_ id: UUID) -> Hotel? { merged.hotels.first { $0.id == id } }

    @discardableResult
    func add(_ hotel: Hotel, photos: [(Data, String)]) -> Hotel {
        var h = hotel
        h.addedBy = mine.personID
        h.created = .now
        h.updated = .now
        h.photos = photos.compactMap { data, source in
            guard let name = try? library.savePhoto(data) else { return nil }
            return Photo(file: name, source: source)
        }
        mine.hotels.append(h)
        save()
        return h
    }

    func update(_ hotel: Hotel) {
        var h = hotel
        h.updated = .now
        if let i = mine.hotels.firstIndex(where: { $0.id == h.id }) {
            mine.hotels[i] = h
        } else {
            mine.hotels.append(h)
        }
        save()
    }

    func delete(_ id: UUID) {
        guard var h = hotel(id) else { return }
        h.deleted = true
        mine.reviews.removeAll { $0.hotelID == id }
        update(h)
    }

    func addPhotos(_ photos: [(Data, String)], to id: UUID) {
        guard var h = hotel(id) else { return }
        for (data, source) in photos {
            if let name = try? library.savePhoto(data) { h.photos.append(Photo(file: name, source: source)) }
        }
        update(h)
    }

    func removePhoto(_ photo: Photo, from id: UUID) {
        guard var h = hotel(id) else { return }
        h.photos.removeAll { $0.file == photo.file }
        update(h)
    }

    func movePhotoToFront(_ photo: Photo, in id: UUID) {
        guard var h = hotel(id), let i = h.photos.firstIndex(of: photo) else { return }
        h.photos.remove(at: i)
        h.photos.insert(photo, at: 0)
        update(h)
    }

    // MARK: Reviews

    func review(_ hotel: UUID, by person: UUID) -> Review? {
        merged.reviews[hotel]?[person]
    }

    func myReview(_ hotel: UUID) -> Review {
        mine.reviews.first { $0.hotelID == hotel } ?? Review(hotelID: hotel)
    }

    func setMyReview(_ review: Review) {
        var r = review
        r.updated = .now
        mine.reviews.removeAll { $0.hotelID == r.hotelID }
        if !r.isEmpty { mine.reviews.append(r) }
        save()
    }

    // MARK: Sharing

    /// Moves the list into a folder in iCloud Drive. Returns the people already in it (other than me).
    func useSharedFolder(_ url: URL) throws -> [Person] {
        _ = url.startAccessingSecurityScopedResource()
        try Library.remember(url)
        let previous = library
        let shared = Library(root: url, isShared: true)
        shared.prepare()
        shared.copyIn(from: previous)
        library = shared
        refresh()
        save()
        return others.map { Person(id: $0.personID, name: $0.name) }
    }

    /// "That's me": carry on as someone already in the shared folder (for example on a new phone).
    func becomeExisting(_ person: Person) {
        guard let file = others.first(where: { $0.personID == person.id }) else { return }
        // Fold anything added on this phone into that person's file.
        var adopted = file
        for h in mine.hotels where !adopted.hotels.contains(where: { $0.id == h.id }) { adopted.hotels.append(h) }
        for r in mine.reviews where !adopted.reviews.contains(where: { $0.hotelID == r.hotelID }) { adopted.reviews.append(r) }
        let oldFile = library.peopleFolder.appendingPathComponent("\(mine.personID.uuidString).json")
        try? FileManager.default.removeItem(at: oldFile)
        UserDefaults.standard.set(person.id.uuidString, forKey: "stays.me.id")
        UserDefaults.standard.set(person.name, forKey: "stays.me.name")
        mine = adopted
        others.removeAll { $0.personID == person.id }
        save()
    }

    /// Stops using the shared folder; keeps a copy of everything on this phone.
    func stopSharing() {
        let shared = library
        let local = Library.local
        local.copyIn(from: shared)
        Library.forget()
        library = local
        try? local.write(mine)
        refresh()
    }

    var folderName: String {
        library.isShared ? library.root.lastPathComponent : "This phone only"
    }

    // MARK: Photos

    func image(_ photo: Photo, maxPixel: CGFloat = 1400) -> UIImage? {
        let key = "\(photo.file)-\(Int(maxPixel))" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let data = library.photoData(photo.file), let image = ImageKit.downsample(data, maxPixel: maxPixel) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    // MARK: Ordering

    enum Sort: String, CaseIterable, Identifiable {
        case best, recent, name
        var id: String { rawValue }
        var label: String {
            switch self {
            case .best: "Best first"
            case .recent: "Most recent"
            case .name: "A to Z"
            }
        }
    }

    func sorted(_ hotels: [Hotel], by sort: Sort, dimension: Dimension?) -> [Hotel] {
        switch sort {
        case .name:
            return hotels.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent:
            return hotels.sorted { ($0.stayed ?? $0.created) > ($1.stayed ?? $1.created) }
        case .best:
            let value: (Hotel) -> Double = { h in
                (dimension.map { self.merged.score(h.id, $0) } ?? self.merged.overall(h.id)) ?? -1
            }
            return hotels.sorted { value($0) == value($1) ? $0.created > $1.created : value($0) > value($1) }
        }
    }

    // MARK: Widget

    func writeSnapshot() {
        let ranked = sorted(hotels, by: .best, dimension: nil)
        var snap = WidgetSnapshot()
        snap.count = hotels.count
        snap.rows = ranked.prefix(6).map { h in
            let thumb = h.photos.first.flatMap { image($0, maxPixel: 500) }?.jpegData(compressionQuality: 0.72)
            return .init(id: h.id.uuidString, name: h.name, place: h.place, score: merged.overall(h.id), thumb: thumb)
        }
        snap.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Only for the self-check and demo pictures.
    func resetForTesting(name: String, id: UUID = UUID()) {
        mine = PersonFile(personID: id, name: name)
        others = []
        rebuild()
    }
}

enum ImageKit {
    /// Decodes an image at a smaller size, which is much faster and lighter than full size.
    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Shrinks any image to a JPEG of at most `maxPixel` on its longest side.
    static func jpeg(_ data: Data, maxPixel: CGFloat = 1800) -> Data? {
        downsample(data, maxPixel: maxPixel)?.jpegData(compressionQuality: 0.82)
    }

    static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
    }
}
