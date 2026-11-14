import Foundation
import MapKit
import UIKit

/// Finds pictures of a hotel without any accounts or keys: the hotel's own website,
/// Wikipedia and Wikimedia Commons, and Apple's Look Around street view.
enum PhotoFinder {
    struct Found: Identifiable, Hashable, Sendable {
        let id = UUID()
        /// A JPEG, already shrunk to a sensible size.
        let data: Data
        let source: String
    }

    static let maxPhotos = 10

    static func find(for hotel: Hotel) async -> [Found] {
        async let site = fromWebsite(hotel.website)
        async let wiki = fromWikimedia(hotel)
        async let street = fromLookAround(hotel.coordinate)
        var all = await site
        all += await wiki
        if let s = await street { all.append(s) }
        return dedupe(all).prefix(maxPhotos).map { $0 }
    }

    // MARK: Hotel website

    static func fromWebsite(_ url: URL?) async -> [Found] {
        guard let url, let page = try? await fetch(url, accept: "text/html"),
              let html = String(data: page.0, encoding: .utf8) ?? String(data: page.0, encoding: .isoLatin1) else { return [] }
        let base = page.1.url ?? url
        let candidates = imageCandidates(in: html, base: base)
        return await download(candidates.prefix(16).map { $0 }, source: "Hotel website", minWidth: 600, keep: 6)
    }

    /// Picture addresses on a web page, best first: the page's share image, then large images.
    static func imageCandidates(in html: String, base: URL) -> [URL] {
        var found: [String] = []
        // Share images (what shows when the page is sent in Messages).
        for pattern in [
            #"<meta[^>]+(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image(?::src)?)["'][^>]*content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image(?::src)?)["']"#,
            #"<link[^>]+rel=["']image_src["'][^>]*href=["']([^"']+)["']"#
        ] {
            found += matches(pattern, in: html)
        }
        // Structured data: "image": "..." or "image": ["...", ...]
        found += matches(#""image"\s*:\s*"([^"]+\.(?:jpe?g|png|webp)[^"]*)""#, in: html)
        found += matches(#""(?:url|contentUrl)"\s*:\s*"(https?:[^"]+\.(?:jpe?g|webp)[^"]*)""#, in: html)
        // Regular pictures: take the widest from srcset where given.
        for tag in matches(#"(<img[^>]+>|<source[^>]+>)"#, in: html) {
            if let set = matches(#"(?:data-)?srcset=["']([^"']+)["']"#, in: tag).first, let best = widestFromSrcset(set) {
                found.append(best)
            } else if let src = matches(#"(?:data-src|data-lazy-src|src)=["']([^"']+)["']"#, in: tag).first {
                found.append(src)
            }
        }
        // Background images in inline styles.
        found += matches(#"background(?:-image)?\s*:\s*url\(\s*['"]?([^'")]+)['"]?\s*\)"#, in: html)

        var seen = Set<String>()
        var urls: [URL] = []
        for raw in found {
            let cleaned = raw.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "\\/", with: "/")
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, !cleaned.hasPrefix("data:"),
                  let url = URL(string: cleaned, relativeTo: base)?.absoluteURL,
                  let scheme = url.scheme, scheme.hasPrefix("http") else { continue }
            let lower = url.absoluteString.lowercased()
            let skip = ["logo", "icon", "favicon", "sprite", ".svg", ".gif", "badge", "tripadvisor", "pixel", "tracking", "avatar", "flag", "map-", "/maps/", "award", "payment"]
            if skip.contains(where: lower.contains) { continue }
            if seen.insert(lower).inserted { urls.append(url) }
        }
        return urls
    }

    static func widestFromSrcset(_ srcset: String) -> String? {
        var best: (String, Double)?
        for part in srcset.components(separatedBy: ",") {
            let bits = part.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").filter { !$0.isEmpty }
            guard let url = bits.first else { continue }
            let size = bits.count > 1 ? Double(bits[1].dropLast()) ?? 1 : 1
            if best == nil || size > best!.1 { best = (url, size) }
        }
        return best?.0
    }

    // MARK: Wikipedia and Wikimedia Commons

    static func fromWikimedia(_ hotel: Hotel) async -> [Found] {
        let words = significantWords(hotel.name)
        guard !words.isEmpty else { return [] }
        var urls: [URL] = []

        // Wikipedia articles near the hotel (or by name), with their main picture.
        var wiki = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        var q = [URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "format", value: "json"),
                 URLQueryItem(name: "prop", value: "pageimages"), URLQueryItem(name: "piprop", value: "original")]
        if let c = hotel.coordinate {
            q += [URLQueryItem(name: "generator", value: "geosearch"), URLQueryItem(name: "ggscoord", value: "\(c.latitude)|\(c.longitude)"),
                  URLQueryItem(name: "ggsradius", value: "500"), URLQueryItem(name: "ggslimit", value: "20")]
        } else {
            q += [URLQueryItem(name: "generator", value: "search"), URLQueryItem(name: "gsrsearch", value: "\(hotel.name) \(hotel.city)"),
                  URLQueryItem(name: "gsrlimit", value: "5")]
        }
        wiki.queryItems = q
        if let url = wiki.url, let result = try? await fetch(url, accept: "application/json"),
           let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
           let pages = (json["query"] as? [String: Any])?["pages"] as? [String: Any] {
            for case let page as [String: Any] in pages.values {
                guard let title = page["title"] as? String, matchesName(title, words),
                      let original = (page["original"] as? [String: Any])?["source"] as? String,
                      let u = URL(string: original) else { continue }
                urls.append(u)
            }
        }

        // Photos on Wikimedia Commons named after the hotel.
        var commons = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        commons.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "search"), URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrsearch", value: "\(hotel.name) \(hotel.city) filetype:bitmap"),
            URLQueryItem(name: "gsrlimit", value: "12"),
            URLQueryItem(name: "prop", value: "imageinfo"), URLQueryItem(name: "iiprop", value: "url|size"),
            URLQueryItem(name: "iiurlwidth", value: "1600")
        ]
        if let url = commons.url, let result = try? await fetch(url, accept: "application/json"),
           let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
           let pages = (json["query"] as? [String: Any])?["pages"] as? [String: Any] {
            let ordered = pages.values.compactMap { $0 as? [String: Any] }.sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
            for page in ordered {
                guard let title = page["title"] as? String, matchesName(title, words),
                      let info = (page["imageinfo"] as? [[String: Any]])?.first,
                      let thumb = (info["thumburl"] as? String) ?? (info["url"] as? String),
                      let u = URL(string: thumb) else { continue }
                urls.append(u)
            }
        }
        return await download(urls, source: "Wikipedia", minWidth: 500, keep: 5)
    }

    /// The distinctive words in a hotel's name ("The Savoy, London" gives ["savoy"]).
    static func significantWords(_ name: String) -> [String] {
        let common: Set<String> = ["the", "hotel", "hotels", "and", "&", "resort", "spa", "by", "a", "an", "of", "at", "in", "le", "la", "les",
                                   "el", "il", "das", "der", "de", "du", "di", "hôtel", "inn", "suites", "collection", "autograph",
                                   "marriott", "hilton", "hyatt", "residence", "residences", "house", "club", "palace", "grand",
                                   "boutique", "luxury", "hostel", "lodge", "new", "york", "london", "paris", "city"]
        return name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !common.contains($0) }
    }

    static func matchesName(_ title: String, _ words: [String]) -> Bool {
        let t = title.lowercased()
        let hits = words.filter { t.contains($0) }.count
        return words.count <= 2 ? hits >= 1 : hits >= 2
    }

    // MARK: Look Around (street view)

    static func fromLookAround(_ coordinate: CLLocationCoordinate2D?) async -> Found? {
        guard let coordinate else { return nil }
        do {
            guard let scene = try await MKLookAroundSceneRequest(coordinate: coordinate).scene else { return nil }
            let options = MKLookAroundSnapshotter.Options()
            options.size = CGSize(width: 1200, height: 800)
            let snapshot = try await MKLookAroundSnapshotter(scene: scene, options: options).snapshot
            guard let jpeg = snapshot.image.jpegData(compressionQuality: 0.82) else { return nil }
            return Found(data: jpeg, source: "Look Around")
        } catch {
            return nil
        }
    }

    // MARK: Helpers

    static func download(_ urls: [URL], source: String, minWidth: CGFloat, keep: Int) async -> [Found] {
        await withTaskGroup(of: (Int, Found?).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    guard let data = try? await fetch(url, accept: "image/*").0,
                          let size = ImageKit.pixelSize(data),
                          size.width >= minWidth, size.height >= minWidth * 0.45,
                          size.width / size.height < 3.2,
                          let jpeg = ImageKit.jpeg(data) else { return (i, nil) }
                    return (i, Found(data: jpeg, source: source))
                }
            }
            var results: [(Int, Found)] = []
            for await (i, found) in group { if let found { results.append((i, found)) } }
            return results.sorted { $0.0 < $1.0 }.prefix(keep).map(\.1)
        }
    }

    /// Drops copies of the same picture (same pixels at a slightly different size).
    static func dedupe(_ photos: [Found]) -> [Found] {
        var seen = Set<String>()
        return photos.filter { photo in
            guard let image = ImageKit.downsample(photo.data, maxPixel: 8)?.cgImage,
                  let bytes = image.dataProvider?.data as Data? else { return true }
            let key = bytes.prefix(256).map { String($0 >> 5) }.joined()
            return seen.insert(key).inserted
        }
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    static func fetch(_ url: URL, accept: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        let isWikimedia = url.host?.contains("wiki") == true
        request.setValue(isWikimedia ? "Stays/1.0 (personal hotel journal app)"
                         : "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return (data, response)
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { m in
            let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
            guard let swiftRange = Range(r, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}
