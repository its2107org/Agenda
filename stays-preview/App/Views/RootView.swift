import MapKit
import SwiftUI

@MainActor
@Observable
final class Router {
    static let shared = Router()
    var showAdd = false
    var showInvite = false
    var path: [UUID] = []
    var tab = 0

    func open(_ url: URL) {
        guard url.scheme == "stays" else { return }
        switch url.host {
        case "add":
            showAdd = true
        case "hotel":
            if let id = UUID(uuidString: url.lastPathComponent) {
                tab = 0
                path = [id]
            }
        default:
            break
        }
    }
}

struct RootView: View {
    @Environment(StaysStore.self) private var store
    @Bindable private var router = Router.shared

    var body: some View {
        if !store.isSetUp {
            WelcomeView()
        } else {
            TabView(selection: $router.tab) {
                Tab("Hotels", systemImage: "building.2", value: 0) {
                    NavigationStack(path: $router.path) {
                        HotelListView()
                            .navigationDestination(for: UUID.self) { HotelDetailView(hotelID: $0) }
                    }
                }
                Tab("Map", systemImage: "map", value: 1) {
                    NavigationStack {
                        HotelMapView()
                            .navigationDestination(for: UUID.self) { HotelDetailView(hotelID: $0) }
                    }
                }
                Tab("Settings", systemImage: "gearshape", value: 2) {
                    NavigationStack { SettingsView() }
                }
            }
            .sheet(isPresented: $router.showAdd) {
                AddHotelView()
            }
            .sheet(isPresented: $router.showInvite) {
                SharingGuide()
            }
        }
    }
}

struct HotelListView: View {
    @Environment(StaysStore.self) private var store
    @State private var filter = ""
    @AppStorage("stays.sort") private var sortRaw = StaysStore.Sort.best.rawValue
    @AppStorage("stays.sortDimension") private var dimensionRaw = ""

    private var sort: StaysStore.Sort { StaysStore.Sort(rawValue: sortRaw) ?? .best }
    private var dimension: Dimension? { sort == .best ? Dimension(rawValue: dimensionRaw) : nil }

    private var shown: [Hotel] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        let all = store.hotels.filter { h in
            q.isEmpty || [h.name, h.city, h.country].contains { $0.localizedCaseInsensitiveContains(q) }
        }
        return store.sorted(all, by: sort, dimension: dimension)
    }

    var body: some View {
        ScrollView {
            if store.hotels.isEmpty {
                ContentUnavailableView {
                    Label("No stays yet", systemImage: "building.2")
                } description: {
                    Text("Add a hotel you've stayed at, then rate it.")
                } actions: {
                    Button("Add a hotel") { Router.shared.showAdd = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 120)
            } else {
                LazyVStack(spacing: 16) {
                    if let dimension {
                        HStack {
                            Label("Best for \(dimension.name.lowercased())", systemImage: dimension.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Show all") { dimensionRaw = "" }
                                .font(.subheadline)
                        }
                        .padding(.horizontal, 4)
                    }
                    ForEach(shown) { hotel in
                        NavigationLink(value: hotel.id) {
                            HotelCard(hotel: hotel, dimension: dimension)
                        }
                        .buttonStyle(.plain)
                    }
                    if shown.isEmpty {
                        Text("Nothing matches “\(filter)”.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Stays")
        .searchable(text: $filter, prompt: "Hotel or city")
        .refreshable { store.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Order", selection: $sortRaw) {
                        ForEach(StaysStore.Sort.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Menu("Best for…") {
                        Picker("Best for", selection: Binding(get: { dimensionRaw }, set: { dimensionRaw = $0; sortRaw = StaysStore.Sort.best.rawValue })) {
                            Text("Overall").tag("")
                            ForEach(Dimension.allCases) { d in Label(d.name, systemImage: d.symbol).tag(d.rawValue) }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Order")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Router.shared.showAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a hotel")
            }
        }
        .overlay(alignment: .bottom) {
            if store.waiting > 0 {
                Label("Getting the latest from iCloud…", systemImage: "icloud.and.arrow.down")
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect()
                    .padding(.bottom, 12)
            }
        }
    }
}

struct HotelMapView: View {
    @Environment(StaysStore.self) private var store
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: UUID?

    var body: some View {
        Map(position: $position, selection: $selected) {
            ForEach(store.hotels.filter { $0.coordinate != nil }) { hotel in
                Annotation(hotel.name, coordinate: hotel.coordinate!, anchor: .bottom) {
                    VStack(spacing: 2) {
                        Text(Score.text(store.merged.overall(hotel.id)))
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(ScoreColour.of(store.merged.overall(hotel.id)), in: .capsule)
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 7))
                            .rotationEffect(.degrees(180))
                            .foregroundStyle(ScoreColour.of(store.merged.overall(hotel.id)))
                            .offset(y: -3)
                    }
                }
                .tag(hotel.id)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let id = selected, let hotel = store.hotel(id) {
                NavigationLink(value: id) {
                    HStack(spacing: 12) {
                        HotelPhoto(photo: hotel.photos.first, maxPixel: 300)
                            .frame(width: 64, height: 64)
                            .clipShape(.rect(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hotel.name).font(.headline).lineLimit(1)
                            Text(hotel.place).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        ScoreBadge(value: store.merged.overall(id))
                    }
                    .padding(10)
                    .glassEffect(in: .rect(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .overlay {
            if store.hotels.isEmpty {
                ContentUnavailableView("No stays yet", systemImage: "map", description: Text("Hotels you add appear here."))
            }
        }
    }
}
