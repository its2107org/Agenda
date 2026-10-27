import SwiftUI

/// Shows what the sorter made of a brain dump or a shared booking, grouped by list, for a quick check.
struct ReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var router = Router.shared
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable { let id: UUID }
    struct ProposalGroup: Identifiable { let category: Category; let indices: [Int]; var id: String { category.id } }
    private var store: AgendaStore { .shared }

    private var chosen: [Proposal] { router.proposals.filter(\.include) }

    var body: some View {
        NavigationStack {
            Group {
                if router.isSorting {
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text(router.sortingLabel).font(.headline)
                        Text("Splitting it up, picking lists and working out dates.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if router.proposals.isEmpty {
                    EmptyNote(symbol: "text.magnifyingglass", title: "Nothing to add",
                              message: "Couldn't find anything to do in that. Try again with a bit more detail.")
                } else {
                    list
                }
            }
            .navigationTitle(router.isSorting ? "" : "Check and add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(chosen.count)") { addAll() }
                        .fontWeight(.semibold)
                        .disabled(router.isSorting || chosen.isEmpty)
                }
            }
            .sheet(item: $editing) { target in
                if let index = router.proposals.firstIndex(where: { $0.id == target.id }) {
                    ProposalEditor(proposal: $router.proposals[index])
                }
            }
        }
        .interactiveDismissDisabled(router.isSorting)
    }

    private var groups: [ProposalGroup] {
        var order: [String] = []
        var map: [String: [Int]] = [:]
        for (index, proposal) in router.proposals.enumerated() {
            let key = proposal.repeats != nil ? "__repeat" : (proposal.item.isEvent ? "__event" : proposal.item.categoryID)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(index)
        }
        return order.map { key in
            let category: Category
            switch key {
            case "__repeat": category = Category(id: key, name: "Standing reminders", symbol: "repeat", colour: 9)
            case "__event": category = Category(id: key, name: "Bookings and plans", symbol: "calendar", colour: 0)
            default: category = store.category(key)
            }
            return ProposalGroup(category: category, indices: map[key] ?? [])
        }
    }

    private var list: some View {
        List {
            if let note = router.proposalNote {
                Section {
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                let category = group.category
                Section {
                    ForEach(group.indices, id: \.self) { index in
                        ProposalRow(proposal: $router.proposals[index])
                            .contentShape(Rectangle())
                            .onTapGesture { editing = EditTarget(id: router.proposals[index].id) }
                    }
                } header: {
                    Label(category.name, systemImage: category.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(category.tint)
                        .textCase(nil)
                }
            }
            Section {
                Text("Untick anything you don't want. Tap one to change its list, date or wording.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private func close() {
        router.proposals = []
        router.proposalNote = nil
        dismiss()
    }

    private func addAll() {
        var items: [Item] = []
        for proposal in chosen {
            if let routine = proposal.makeRoutine() {
                store.upsertRoutine(routine)
            } else {
                items.append(proposal.item)
            }
        }
        store.add(items)
        let bookings = items.filter(\.isEvent)
        if !bookings.isEmpty && CalendarLink.shared.copyBookings {
            Task {
                for booking in bookings {
                    if let id = await CalendarLink.shared.save(booking), var saved = store.item(booking.id) {
                        saved.calendarEventID = id
                        store.update(saved)
                    }
                }
                await CalendarLink.shared.refresh()
            }
        }
        close()
    }
}

struct ProposalRow: View {
    @Binding var proposal: Proposal
    private var store: AgendaStore { .shared }

    var body: some View {
        let category = store.category(proposal.item.categoryID)
        HStack(alignment: .top, spacing: 12) {
            Button {
                proposal.include.toggle()
            } label: {
                Image(systemName: proposal.include ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(proposal.include ? category.tint : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(proposal.include ? "Will be added" : "Won't be added")

            VStack(alignment: .leading, spacing: 4) {
                Text(proposal.item.title)
                    .foregroundStyle(proposal.include ? .primary : .secondary)
                HStack(spacing: 6) {
                    Chip(text: category.name, symbol: category.symbol, tint: category.tint)
                    if let repeats = proposal.repeats {
                        Chip(text: repeats.summary, symbol: "repeat", tint: .secondary)
                    } else if let when = DateWords.range(proposal.item) {
                        Chip(text: when, symbol: proposal.item.isEvent ? "calendar" : "clock", tint: .secondary)
                    }
                    ForEach(proposal.item.tagList, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if proposal.item.flagged {
                        Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                if !proposal.item.location.isEmpty || !proposal.item.reference.isEmpty {
                    Text([proposal.item.location, proposal.item.reference.isEmpty ? "" : "Ref \(proposal.item.reference)"]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .opacity(proposal.include ? 1 : 0.6)
    }
}

struct Chip: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((tint == .secondary ? Color.gray : tint).opacity(0.14), in: Capsule())
    }
}

/// Tweaks one suggestion before it's added.
struct ProposalEditor: View {
    @Binding var proposal: Proposal
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ItemFields(item: $proposal.item)
                if proposal.repeats != nil {
                    Section {
                        Toggle("Repeats (\(proposal.repeats!.summary))", isOn: Binding(
                            get: { proposal.repeats != nil },
                            set: { if !$0 { proposal.repeats = nil } }))
                    } footer: {
                        Text("Turn off to add it as a one-off to-do instead of a standing reminder.")
                    }
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}
