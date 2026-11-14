import Foundation
import UIKit

/// Where the list lives: a folder of files. Either on this phone only, or in an iCloud Drive
/// folder the two of you share.
///
/// Folder layout:
///   people/<person id>.json   one file per person (only its owner writes it)
///   photos/<photo id>.jpg     hotel photos, shared by both
struct Library: Sendable {
    let root: URL
    let isShared: Bool

    var peopleFolder: URL { root.appendingPathComponent("people", isDirectory: true) }
    var photosFolder: URL { root.appendingPathComponent("photos", isDirectory: true) }

    static var local: Library {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return Library(root: base.appendingPathComponent("Stays", isDirectory: true), isShared: false)
    }

    // MARK: Shared folder bookmark

    private static let bookmarkKey = "stays.sharedFolderBookmark"

    /// Remembers the chosen folder so the app can open it again after a restart.
    static func remember(_ url: URL) throws {
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    static var hasShared: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    /// The shared folder, opened for use. Nil if none chosen, or it can no longer be reached.
    static func openShared() -> Library? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale { try? remember(url) }
        return Library(root: url, isShared: true)
    }

    // MARK: Files

    func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: peopleFolder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: photosFolder, withIntermediateDirectories: true)
    }

    /// Reads every person's file. Files iCloud hasn't downloaded yet are asked for, and
    /// counted in `waiting` so the app can look again shortly.
    func readAll() -> (files: [PersonFile], waiting: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: peopleFolder.path) else { return ([], 0) }
        var files: [PersonFile] = []
        var waiting = 0
        for name in names {
            if let real = Library.placeholderTarget(name) {
                if real.hasSuffix(".json") {
                    waiting += 1
                    try? fm.startDownloadingUbiquitousItem(at: peopleFolder.appendingPathComponent(real))
                }
                continue
            }
            guard name.hasSuffix(".json") else { continue }
            let url = peopleFolder.appendingPathComponent(name)
            if isShared { try? fm.startDownloadingUbiquitousItem(at: url) }
            if let data = coordinatedRead(url), let file = try? Library.decoder.decode(PersonFile.self, from: data) {
                files.append(file)
            }
        }
        return (files, waiting)
    }

    func write(_ file: PersonFile) throws {
        prepare()
        let data = try Library.encoder.encode(file)
        try coordinatedWrite(data, to: peopleFolder.appendingPathComponent("\(file.personID.uuidString).json"))
    }

    func savePhoto(_ jpeg: Data) throws -> String {
        prepare()
        let name = "\(UUID().uuidString).jpg"
        try coordinatedWrite(jpeg, to: photosFolder.appendingPathComponent(name))
        return name
    }

    /// The photo's bytes, or nil if it isn't on this phone yet (it's then asked for from iCloud).
    func photoData(_ name: String) -> Data? {
        let url = photosFolder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            return coordinatedRead(url)
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return nil
    }

    func deletePhoto(_ name: String) {
        let url = photosFolder.appendingPathComponent(name)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { u in
            try? FileManager.default.removeItem(at: u)
        }
    }

    /// Copies everything from another library into this one (used when moving to a shared folder).
    func copyIn(from other: Library) {
        prepare()
        let fm = FileManager.default
        for folder in ["people", "photos"] {
            let src = other.root.appendingPathComponent(folder)
            let dst = root.appendingPathComponent(folder)
            for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where !name.hasPrefix(".") {
                let target = dst.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) { continue }
                if let data = try? Data(contentsOf: src.appendingPathComponent(name)) {
                    try? coordinatedWrite(data, to: target)
                }
            }
        }
    }

    // MARK: Helpers

    /// iCloud keeps not-yet-downloaded files as ".name.icloud". Returns "name" for those.
    static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    private func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var error: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeError = error }
        }
        if let error { throw error }
        if let writeError { throw writeError }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: text) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        return d
    }()
}
