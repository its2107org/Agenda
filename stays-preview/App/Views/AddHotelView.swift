import MapKit
import PhotosUI
import SwiftUI

/// Search for a real hotel, pick the photos you want, add it.
struct AddHotelView: View {
    @Environment(StaysStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = HotelSearch()
    @State private var draft: Hotel?
    @State private var resolving: String?
    @State private var manual = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    AddDetailsView(draft: draft) { dismiss() }
                } else {
                    searchList
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .onAppear {
            if let q = Demo.addQuery { search.query = q }
            if draft == nil, let d = Demo.addDraft { draft = d }
        }
    }

    private var searchList: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Hotel name, and city if you like", text: $search.query)
                        .focused($focused)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !search.query.isEmpty {
                        Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if !search.suggestions.isEmpty {
                Section {
                    ForEach(search.suggestions) { s in
                        Button { pick(s) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "bed.double.fill")
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(Color.accentColor, in: .rect(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.body).foregroundStyle(.primary)
                                    Text(s.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if resolving == s.id { ProgressView() }
                            }
                        }
                        .disabled(resolving != nil)
                    }
                }
            } else if search.query.count > 2 {
                Section {
                    Text(search.failed ? "Couldn't search just now. Check you're online." : "Searching…")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button { manual = true } label: {
                    Label("Can't find it? Add it by name", systemImage: "square.and.pencil")
                }
            }
        }
        .navigationTitle("Add a hotel")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
        .alert("Add by name", isPresented: $manual) {
            TextField("Hotel name", text: $search.query)
            Button("Next") {
                let name = search.query.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { draft = Hotel(name: name, addedBy: store.me.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func pick(_ s: HotelSearch.Suggestion) {
        resolving = s.id
        Task {
            defer { resolving = nil }
            if let item = try? await search.resolve(s) {
                draft = HotelSearch.draft(from: item, by: store.me.id)
            } else {
                draft = Hotel(name: s.title, addedBy: store.me.id)
            }
        }
    }
}

struct AddDetailsView: View {
    @Environment(StaysStore.self) private var store
    @State var draft: Hotel
    let done: () -> Void

    @State private var found: [PhotoFinder.Found] = []
    @State private var chosen = Set<UUID>()
    @State private var searching = true
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var hasDate = false
    @State private var rateNow: UUID?

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.name).font(.title.weight(.bold))
                    if !draft.address.isEmpty || !draft.place.isEmpty {
                        Text(draft.address.isEmpty ? draft.place : draft.address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let site = draft.website {
                        Link(destination: site) {
                            Label(site.host?.replacingOccurrences(of: "www.", with: "") ?? "Website", systemImage: "safari")
                                .font(.subheadline)
                        }
                        .padding(.top, 2)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Photos").font(.headline)
                        Spacer()
                        if searching {
                            ProgressView().controlSize(.small)
                            Text("Finding photos…").font(.footnote).foregroundStyle(.secondary)
                        } else if !found.isEmpty {
                            Text("\(chosen.count) chosen").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(found) { photo in
                            Button {
                                if chosen.contains(photo.id) { chosen.remove(photo.id) } else { chosen.insert(photo.id) }
                            } label: {
                                Color.clear
                                    .aspectRatio(1.3, contentMode: .fit)
                                    .overlay {
                                        if let ui = ImageKit.downsample(photo.data, maxPixel: 500) {
                                            Image(uiImage: ui).resizable().scaledToFill()
                                        }
                                    }
                                    .clipShape(.rect(cornerRadius: 14, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: chosen.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(.white, chosen.contains(photo.id) ? Color.accentColor : .black.opacity(0.25))
                                            .padding(8)
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        Text(photo.source)
                                            .font(.caption2)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(.black.opacity(0.35), in: .capsule)
                                            .padding(6)
                                    }
                                    .opacity(chosen.contains(photo.id) ? 1 : 0.55)
                            }
                            .buttonStyle(.plain)
                        }
                        PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                                .aspectRatio(1.3, contentMode: .fit)
                                .overlay {
                                    VStack(spacing: 6) {
                                        Image(systemName: "photo.badge.plus").font(.title2)
                                        Text("Your photos").font(.footnote)
                                    }
                                    .foregroundStyle(Color.accentColor)
                                }
                        }
                    }
                    if !searching && found.isEmpty {
                        Text("No photos found online for this one. You can add your own, or try again later from the hotel's page.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("We know when we stayed", isOn: $hasDate.animation())
                    if hasDate {
                        DatePicker("Stayed", selection: Binding(get: { draft.stayed ?? .now }, set: { draft.stayed = $0 }), in: ...Date.now, displayedComponents: .date)
                    }
                }
                .card()
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Add a hotel")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button(action: add) {
                Text("Add hotel")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .task {
            if let demo = Demo.foundPhotos {
                found = demo
            } else {
                found = await PhotoFinder.find(for: draft)
            }
            chosen = Set(found.prefix(5).map(\.id))
            searching = false
        }
        .onChange(of: pickerItems) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let jpeg = ImageKit.jpeg(data) {
                        let f = PhotoFinder.Found(data: jpeg, source: "Your photo")
                        found.insert(f, at: 0)
                        chosen.insert(f.id)
                    }
                }
                pickerItems = []
            }
        }
        .sheet(item: $rateNow, onDismiss: done) { id in
            RatingEditor(hotelID: id)
        }
    }

    private func add() {
        if !hasDate { draft.stayed = nil } else if draft.stayed == nil { draft.stayed = .now }
        let photos = found.filter { chosen.contains($0.id) }.map { ($0.data, $0.source) }
        let saved = store.add(draft, photos: photos)
        rateNow = saved.id
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
