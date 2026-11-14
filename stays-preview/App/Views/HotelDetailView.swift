import MapKit
import PhotosUI
import SwiftUI

struct HotelDetailView: View {
    @Environment(StaysStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let hotelID: UUID

    @State private var rating = false
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var findingPhotos = false
    @State private var photoPage = 0

    var body: some View {
        if let hotel = store.hotel(hotelID) {
            content(hotel)
        } else {
            ContentUnavailableView("Hotel removed", systemImage: "building.2")
        }
    }

    private func content(_ hotel: Hotel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                gallery(hotel)

                VStack(alignment: .leading, spacing: 6) {
                    Text(hotel.name)
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if !hotel.place.isEmpty { Text(hotel.place) }
                        if let stayed = hotel.stayed {
                            Text("·")
                            Text("Stayed \(stayed.formatted(.dateTime.month(.wide).year()))")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)

                links(hotel)
                    .padding(.horizontal, 20)

                scores(hotel)
                    .padding(.horizontal, 16)

                notes(hotel)
                    .padding(.horizontal, 16)

                if let c = hotel.coordinate {
                    Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 1600, longitudinalMeters: 1600)), interactionModes: []) {
                        Marker(hotel.name, systemImage: "bed.double.fill", coordinate: c)
                            .tint(Color.accentColor)
                    }
                    .frame(height: 170)
                    .clipShape(.rect(cornerRadius: 20, style: .continuous))
                    .onTapGesture { if let u = hotel.mapsURL { openURL(u) } }
                    .padding(.horizontal, 16)
                    if !hotel.address.isEmpty {
                        Text(hotel.address)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { editing = true } label: { Label("Edit details", systemImage: "pencil") }
                    Button { showPicker = true } label: { Label("Add your photos", systemImage: "photo.badge.plus") }
                    Button { findMorePhotos(hotel) } label: { Label("Find more photos", systemImage: "sparkle.magnifyingglass") }
                    if let first = hotel.photos.indices.contains(photoPage) ? hotel.photos[photoPage] : nil {
                        Button { store.movePhotoToFront(first, in: hotel.id); photoPage = 0 } label: { Label("Use this photo first", systemImage: "star") }
                        Button(role: .destructive) { store.removePhoto(first, from: hotel.id); photoPage = 0 } label: { Label("Remove this photo", systemImage: "photo.badge.minus") }
                    }
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete hotel", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .confirmationDialog("Delete \(hotel.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete for both of you", role: .destructive) {
                store.delete(hotel.id)
                dismiss()
            }
        } message: {
            Text("It goes from the shared list, with everyone's scores.")
        }
        .sheet(isPresented: $rating) { RatingEditor(hotelID: hotel.id) }
        .onAppear { if Demo.opensRatingEditor { rating = true } }
        .sheet(isPresented: $editing) { HotelEditor(hotel: hotel) }
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var photos: [(Data, String)] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let jpeg = ImageKit.jpeg(data) {
                        photos.append((jpeg, "Your photo"))
                    }
                }
                store.addPhotos(photos, to: hotel.id)
                pickerItems = []
            }
        }
    }

    // MARK: Pieces

    private func gallery(_ hotel: Hotel) -> some View {
        Group {
            if hotel.photos.isEmpty {
                PlaceholderArt(seed: hotel.name)
                    .overlay(alignment: .bottom) {
                        if findingPhotos {
                            ProgressView().tint(.white).padding()
                        } else {
                            Button("Find photos") { findMorePhotos(hotel) }
                                .buttonStyle(.glass)
                                .padding()
                        }
                    }
            } else {
                TabView(selection: $photoPage) {
                    ForEach(Array(hotel.photos.enumerated()), id: \.element.id) { i, photo in
                        Color.clear
                            .overlay { HotelPhoto(photo: photo) }
                            .clipped()
                            .overlay(alignment: .bottomTrailing) {
                                Text(photo.source)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.black.opacity(0.3), in: .capsule)
                                    .padding(10)
                                    .padding(.bottom, 18)
                            }
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: hotel.photos.count > 1 ? .always : .never))
            }
        }
        .frame(height: 330)
        .clipShape(.rect(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func links(_ hotel: Hotel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let site = hotel.website { linkButton("Website", "safari", site) }
                if let maps = hotel.mapsURL { linkButton("Maps", "map", maps) }
                if let phone = hotel.phoneURL { linkButton("Call", "phone", phone) }
                if let google = hotel.googleURL { linkButton("Search", "magnifyingglass", google) }
            }
        }
        .scrollClipDisabled()
    }

    private func linkButton(_ title: String, _ symbol: String, _ url: URL) -> some View {
        Button { openURL(url) } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    private func scores(_ hotel: Hotel) -> some View {
        let people = store.everyone
        let reviews = people.map { store.review(hotel.id, by: $0.id) }
        let rated = Dimension.allCases.filter { d in reviews.contains { $0?.score(d) != nil } }
        let mine = store.myReview(hotel.id)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overall").font(.headline)
                    Text(people.count > 1 ? "Both of you, out of 10" : "Out of 10")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ScoreBadge(value: store.merged.overall(hotel.id), large: true)
            }

            // One column per person.
            if !rated.isEmpty || reviews.contains(where: { $0?.verdict != nil }) {
                Divider()
                HStack {
                    Spacer()
                    ForEach(Array(people.enumerated()), id: \.element.id) { i, p in
                        VStack(spacing: 4) {
                            Avatar(person: p, isMe: i == 0)
                            Text(Score.text(reviews[i]?.overall))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                        .frame(width: 74)
                    }
                }
                ForEach(rated) { d in
                    HStack(spacing: 10) {
                        Image(systemName: d.symbol)
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)
                        Text(d.name).font(.subheadline)
                        Spacer()
                        ForEach(Array(people.enumerated()), id: \.element.id) { i, _ in
                            Group {
                                if let s = reviews[i]?.score(d) { ScoreDots(score: s) } else { Text("–").foregroundStyle(.tertiary) }
                            }
                            .frame(width: 74)
                        }
                    }
                }
                let verdicts = reviews.map { $0?.verdict }
                if verdicts.contains(where: { $0 != nil }) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)
                        Text("Go back?").font(.subheadline)
                        Spacer()
                        ForEach(Array(people.enumerated()), id: \.element.id) { i, _ in
                            Text(verdicts[i]?.short ?? "–")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(verdicts[i] == .no ? Color.red : verdicts[i] == .yes ? Color.green : Color.secondary)
                                .frame(width: 74)
                        }
                    }
                }
            }

            Button { rating = true } label: {
                Text(mine.isEmpty ? "Rate this hotel" : "Change my scores")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.top, 4)
        }
        .card()
    }

    @ViewBuilder
    private func notes(_ hotel: Hotel) -> some View {
        let notes = store.everyone.enumerated().compactMap { i, p -> (Person, Bool, String)? in
            guard let n = store.review(hotel.id, by: p.id)?.note.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
            return (p, i == 0, n)
        }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Notes").font(.headline)
                ForEach(notes, id: \.0.id) { person, isMe, note in
                    HStack(alignment: .top, spacing: 10) {
                        Avatar(person: person, isMe: isMe, size: 24)
                        Text(note).font(.subheadline)
                    }
                }
            }
            .card()
        }
    }

    private func findMorePhotos(_ hotel: Hotel) {
        guard !findingPhotos else { return }
        findingPhotos = true
        Task {
            let found = await PhotoFinder.find(for: hotel)
            store.addPhotos(found.prefix(6).map { ($0.data, $0.source) }, to: hotel.id)
            findingPhotos = false
        }
    }
}

/// Your own scores for one hotel.
struct RatingEditor: View {
    @Environment(StaysStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let hotelID: UUID
    @State private var review: Review?

    var body: some View {
        NavigationStack {
            Form {
                if review != nil {
                    Section {
                        ForEach(Dimension.allCases) { d in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 10) {
                                    Image(systemName: d.symbol)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(d.name).font(.body.weight(.medium))
                                        Text(d.hint).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if review?.score(d) == nil {
                                        Text("Skip").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                ScorePicker(score: binding(d))
                                    .padding(.leading, 34)
                            }
                            .padding(.vertical, 4)
                        }
                    } footer: {
                        Text("Leave any you didn't try. Tap a score again to clear it.")
                    }

                    Section("Would you go back?") {
                        Picker("Would you go back?", selection: Binding(get: { review?.verdict }, set: { review?.verdict = $0 })) {
                            ForEach(Verdict.allCases, id: \.self) { Text($0.short).tag(Optional($0)) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Section("Notes") {
                        TextField("Best room, what to order, what to avoid…", text: Binding(get: { review?.note ?? "" }, set: { review?.note = $0 }), axis: .vertical)
                            .lineLimit(3...8)
                    }
                }
            }
            .navigationTitle(store.hotel(hotelID)?.name ?? "Rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let review { store.setMyReview(review) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { if review == nil { review = store.myReview(hotelID) } }
        }
    }

    private func binding(_ d: Dimension) -> Binding<Int?> {
        Binding(get: { review?.scores[d.rawValue] }, set: { review?.scores[d.rawValue] = $0 })
    }
}

/// Name, place and when you stayed.
struct HotelEditor: View {
    @Environment(StaysStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var hotel: Hotel
    @State private var hasDate = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $hotel.name)
                    TextField("City", text: $hotel.city)
                    TextField("Country", text: $hotel.country)
                }
                Section {
                    Toggle("We know when we stayed", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Stayed", selection: Binding(get: { hotel.stayed ?? .now }, set: { hotel.stayed = $0 }), displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("Edit details")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { hasDate = hotel.stayed != nil }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if !hasDate { hotel.stayed = nil } else if hotel.stayed == nil { hotel.stayed = .now }
                        store.update(hotel)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(hotel.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
