import SwiftUI

/// The form fields for a to-do or booking, used by the editor and when checking suggestions.
struct ItemFields: View {
    @Binding var item: Item
    private var store: AgendaStore { .shared }

    private var hasDate: Binding<Bool> {
        Binding(
            get: { item.due != nil },
            set: { on in
                if on {
                    item.due = Calendar.current.startOfDay(for: Date())
                    item.hasTime = false
                } else {
                    item.due = nil
                    item.hasTime = false
                    item.end = nil
                }
            })
    }

    private var hasTime: Binding<Bool> {
        Binding(
            get: { item.hasTime },
            set: { on in
                let calendar = Calendar.current
                let day = item.due ?? Date()
                if on {
                    let next = calendar.component(.hour, from: Date()) + 1
                    item.due = calendar.date(bySettingHour: min(max(next, 9), 21), minute: 0, second: 0, of: day)
                } else {
                    item.due = calendar.startOfDay(for: day)
                }
                item.hasTime = on
            })
    }

    private var dueBinding: Binding<Date> {
        Binding(get: { item.due ?? Date() }, set: { item.due = $0 })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { item.end ?? (item.due ?? Date()).addingTimeInterval(2 * 3600) }, set: { item.end = $0 })
    }

    var body: some View {
        Section {
            TextField("What needs doing?", text: $item.title, axis: .vertical)
                .font(.title3.weight(.medium))
            TextField("Notes", text: $item.notes, axis: .vertical)
                .lineLimit(1...6)
        }

        Section {
            Picker(selection: $item.categoryID) {
                ForEach(store.categories) { category in
                    Label(category.name, systemImage: category.symbol).tag(category.id)
                }
            } label: {
                Label("List", systemImage: "square.grid.2x2")
            }
            Picker(selection: $item.kind) {
                Text("To-do").tag(Item.Kind.task)
                Text("Booking or plan").tag(Item.Kind.event)
            } label: {
                Label("Type", systemImage: item.isEvent ? "calendar" : "checkmark.circle")
            }
            Toggle(isOn: $item.flagged) {
                Label("Important", systemImage: "flag")
            }
        }

        Section {
            Toggle(isOn: hasDate) { Label(item.isEvent ? "Date" : "Due date", systemImage: "calendar") }
            if item.due != nil {
                DatePicker(item.isEvent ? "Starts" : "Day", selection: dueBinding,
                           displayedComponents: item.hasTime ? [.date, .hourAndMinute] : [.date])
                Toggle(isOn: hasTime) { Label("Time", systemImage: "clock") }
                if item.isEvent && item.hasTime {
                    DatePicker("Ends", selection: endBinding, in: (item.due ?? .distantPast)...,
                               displayedComponents: [.date, .hourAndMinute])
                }
                if item.hasTime || item.isEvent {
                    Toggle(isOn: $item.remind) {
                        Label(item.isEvent ? "Heads-up beforehand" : "Nudge me at the time", systemImage: "bell")
                    }
                }
            }
        } footer: {
            if item.due == nil && !item.isEvent {
                Text("No date: it lives in its list and in Anytime.")
            }
        }

        if item.isEvent {
            Section("Booking details") {
                TextField("Place or address", text: $item.location)
                TextField("Confirmation number", text: $item.reference)
                TextField("Link", text: $item.link)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
            }
        }
    }
}

struct ItemEditor: View {
    @State var item: Item
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    private var store: AgendaStore { .shared }

    var body: some View {
        NavigationStack {
            Form {
                ItemFields(item: $item)

                if !isNew {
                    Section {
                        if !item.isEvent {
                            Button(item.isDone ? "Mark as not done" : "Mark as done",
                                   systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark.circle") {
                                item.doneAt = item.isDone ? nil : Date()
                                save()
                            }
                            if !item.isDone && item.due != nil {
                                Button("Move to tomorrow", systemImage: "arrow.right.circle") {
                                    store.update(item)
                                    store.moveToTomorrow([item.id])
                                    dismiss()
                                }
                            }
                        }
                        if let url = URL(string: item.link), !item.link.isEmpty {
                            Link(destination: url) { Label("Open link", systemImage: "safari") }
                        }
                        if item.isEvent && !item.location.isEmpty,
                           let url = URL(string: "maps://?q=\(item.location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                            Link(destination: url) { Label("Directions", systemImage: "map") }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                    Section {
                        Text(addedLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(isNew ? "New" : (item.isEvent ? "Booking" : "To-do"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { save() }
                        .disabled(item.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete \(item.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if item.calendarEventID != nil { CalendarLink.shared.remove(item) }
                    store.delete(item.id)
                    dismiss()
                }
            }
        }
    }

    private var addedLine: String {
        let how: String
        switch item.source {
        case .voice: how = "from a brain dump"
        case .shared: how = "from something you shared"
        case .siri: how = "with Siri"
        case .typed: how = ""
        }
        return "Added \(When.short(item.created, hasTime: false).lowercasedFirst) \(how)".trimmingCharacters(in: .whitespaces)
    }

    private func save() {
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.isEvent && item.due == nil { item.kind = .task }
        if let end = item.end, let start = item.due, end <= start { item.end = nil }
        store.update(item)
        if item.isEvent && (item.calendarEventID != nil || (isNew && CalendarLink.shared.copyBookings)) {
            let snapshot = item
            Task {
                if let id = await CalendarLink.shared.save(snapshot), var saved = store.item(snapshot.id) {
                    saved.calendarEventID = id
                    store.update(saved)
                }
            }
        }
        dismiss()
    }
}
