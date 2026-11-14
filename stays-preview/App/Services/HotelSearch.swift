import Foundation
import MapKit
import Observation

/// Finds real hotels by name as you type, using Apple Maps.
@MainActor
@Observable
final class HotelSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet {
            let q = query.trimmingCharacters(in: .whitespaces)
            if q.isEmpty { suggestions = []; completer.cancel() } else { completer.queryFragment = q }
        }
    }
    private(set) var suggestions: [Suggestion] = []
    private(set) var failed = false

    struct Suggestion: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let completion: MKLocalSearchCompletion?
        let item: MKMapItem?

        static func == (a: Suggestion, b: Suggestion) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = [.pointOfInterest]
        completer.pointOfInterestFilter = MKPointOfInterestFilter(including: [.hotel])
        completer.delegate = self
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results.map { c in
            Suggestion(id: c.title + "|" + c.subtitle, title: c.title, subtitle: c.subtitle, completion: c, item: nil)
        }
        MainActor.assumeIsolated {
            self.failed = false
            self.suggestions = results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.failed = true }
    }

    /// Turns a suggestion into a full place (address, website, phone, map position).
    func resolve(_ suggestion: Suggestion) async throws -> MKMapItem {
        if let item = suggestion.item { return item }
        guard let completion = suggestion.completion else { throw URLError(.badURL) }
        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.pointOfInterest]
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw URLError(.cannotFindHost) }
        return item
    }

    /// A one-off search (used by the self-check and as a fallback).
    static func search(_ text: String) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.pointOfInterest]
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.hotel])
        return try await MKLocalSearch(request: request).start().mapItems
    }

    /// A new hotel filled in from Apple Maps.
    static func draft(from item: MKMapItem, by person: UUID) -> Hotel {
        let p = item.placemark
        let address = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let line = [address, p.locality, p.postalCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return Hotel(
            name: item.name ?? "Hotel",
            city: p.locality ?? p.administrativeArea ?? "",
            country: p.country ?? "",
            address: line,
            latitude: p.coordinate.latitude,
            longitude: p.coordinate.longitude,
            website: item.url,
            phone: item.phoneNumber,
            mapsID: item.identifier?.rawValue,
            addedBy: person
        )
    }
}

extension Hotel {
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Opens the hotel in Apple Maps (its own place card when Maps knows it).
    var mapsURL: URL? {
        var parts = URLComponents(string: "https://maps.apple.com/")!
        var items = [URLQueryItem(name: "q", value: name)]
        if let latitude, let longitude { items.append(URLQueryItem(name: "ll", value: "\(latitude),\(longitude)")) }
        if let mapsID { items.append(URLQueryItem(name: "place-id", value: mapsID)) }
        parts.queryItems = items
        return parts.url
    }

    var googleURL: URL? {
        var parts = URLComponents(string: "https://www.google.com/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: [name, city].filter { !$0.isEmpty }.joined(separator: " "))]
        return parts.url
    }

    var phoneURL: URL? {
        guard let phone else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }
}
