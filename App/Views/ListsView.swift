import SwiftUI

/// All the lists: smart ones at the top (Slipped, Anytime, Important) and Ian's sections below.
struct ListsView: View {
    private var store: AgendaStore { .shared }
    @State private var editingSections = false

    enum Destination: Hashable {
        case category(String)
        case tag(String)
        case anytime, flagged, slipped, done
    }

    var body: some View {
        NavigationStack {
            let _ = store.revision
            ScrollView {
                VStack(spacing: 18) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        SmartCard(title: "Slipped", symbol: "exclamationmark.circle.fill", tint: .red,
                                  count: store.overdue().count, destination: .slipped)
                        SmartCard(title: "Anytime", symbol: "tray.fill", tint: .gray,
                                  count: store.anytime.count, destination: .anytime)
                        SmartCard(title: "Important", symbol: "flag.fill", tint: .orange,
                                  count: store.flagged.count, destination: .flagged)
                        SmartCard(title: "Done", symbol: "checkmark.circle.fill", tint: .green,
                                  count: store.data.items.filter(\.isDone).count, destination: .done)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(store.categories.enumerated()), id: \.element.id) { index, category in
                            NavigationLink(value: Destination.category(category.id)) {
                                HStack(spacing: 14) {
                                    CategoryIcon(category: category, size: 34)
                                    Text(category.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(store.openCount(in: category.id))")
                                        .font(.body.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if index < store.categories.count - 1 {
                                Divider().padding(.leading, 64)
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))

                    let tags = store.tags
                    if !tags.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tags")
                                .font(.title3.weight(.bold))
                                .padding(.leading, 4)
                            FlowLayout(spacing: 8) {
                                ForEach(tags, id: \.name) { tag in
                                    NavigationLink(value: Destination.tag(tag.name)) {
                                        HStack(spacing: 6) {
                                            Text("#\(tag.name)").font(.subheadline.weight(.medium))
                                            Text("\(tag.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Lists")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit lists", systemImage: "slider.horizontal.3") { editingSections = true }
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                ListScreen(destination: destination)
            }
            .sheet(isPresented: $editingSections) { SectionsEditor() }
        }
    }
}

struct SmartCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let count: Int
    let destination: ListsView.Destination

    var body: some View {
        NavigationLink(value: destination) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(tint.gradient, in: Circle())
                    Spacer()
                    Text("\(count)")
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

/// One list's to-dos.
struct ListScreen: View {
    let destination: ListsView.Destination
    private var store: AgendaStore { .shared }
    @State private var showDone = false
    @State private var newTitle = ""
    @FocusState private var adding: Bool

    var body: some View {
        let _ = store.revision
        let parts = contents
        let open = parts.0
        let done = parts.1
        List {
            if let category {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(category.tint)
                        TextField("Add to \(category.name)", text: $newTitle)
                            .focused($adding)
                            .submitLabel(.done)
                            .onSubmit(addTyped)
                    }
                }
            }
            if open.isEmpty && done.isEmpty {
                EmptyNote(symbol: "checkmark.circle", title: "Nothing here", message: emptyMessage)
                    .listRowBackground(Color.clear)
            }
            if !open.isEmpty {
                Section {
                    ForEach(open) { item in
                        ItemRow(item: item, showCategory: category == nil, overdue: item.isOverdue())
                            .itemSwipes(item)
                    }
                }
            }
            if !done.isEmpty && destination != .done {
                Section {
                    if showDone {
                        ForEach(done) { ItemRow(item: $0, showCategory: category == nil).itemSwipes($0) }
                    }
                } header: {
                    SectionTitle(text: "Done", colour: .secondary, trailing: showDone ? "Hide" : "Show \(done.count)") {
                        withAnimation { showDone.toggle() }
                    }
                }
            } else if destination == .done {
                Section {
                    ForEach(done) { ItemRow(item: $0).itemSwipes($0) }
                } footer: {
                    Text("Ticked-off to-dos are cleared after 30 days.")
                }
            }
        }
        .navigationTitle(title)
        .animation(.snappy, value: store.revision)
    }

    private var category: Category? {
        if case .category(let id) = destination { return store.category(id) }
        return nil
    }

    private var title: String {
        switch destination {
        case .category: category?.name ?? "List"
        case .tag(let name): "#\(name)"
        case .anytime: "Anytime"
        case .flagged: "Important"
        case .slipped: "Slipped"
        case .done: "Done"
        }
    }

    private var emptyMessage: String {
        switch destination {
        case .slipped: "Nothing overdue. Well done."
        case .anytime: "To-dos without a date land here."
        case .flagged: "Say \"it's urgent\" or mark one Important to see it here."
        default: "Add one above, or use Brain dump."
        }
    }

    private var contents: ([Item], [Item]) {
        switch destination {
        case .category(let id):
            let all = store.items(in: id, includeDone: true)
            return (all.filter { !$0.isDone }, all.filter(\.isDone).sorted { ($0.doneAt ?? .now) > ($1.doneAt ?? .now) })
        case .anytime: return (store.anytime, [])
        case .flagged: return (store.flagged, [])
        case .slipped: return (store.overdue(), [])
        case .tag(let name):
            let all = store.items(tagged: name, includeDone: true)
            return (all.filter { !$0.isDone }, all.filter(\.isDone))
        case .done:
            return ([], store.data.items.filter(\.isDone).sorted { ($0.doneAt ?? .now) > ($1.doneAt ?? .now) })
        }
    }

    private func addTyped() {
        guard let category else { return }
        let text = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, Sorter.quickAdd(text, inCategory: category.id) != nil else { return }
        newTitle = ""
        adding = true
    }
}

/// Add, rename, recolour, reorder and remove lists.
struct SectionsEditor: View {
    @Environment(\.dismiss) private var dismiss
    private var store: AgendaStore { .shared }
    @State private var editing: Category?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.categories) { category in
                        Button {
                            editing = category
                        } label: {
                            HStack(spacing: 12) {
                                CategoryIcon(category: category)
                                Text(category.name).foregroundStyle(.primary)
                            }
                        }
                        .deleteDisabled(category.isInbox)
                    }
                    .onMove { store.moveCategories(from: $0, to: $1) }
                    .onDelete { offsets in
                        for index in offsets { store.deleteCategory(store.categories[index].id) }
                    }
                } footer: {
                    Text("Drag to reorder. Removing a list moves its to-dos to Unsorted.")
                }
                Section {
                    Button("New list", systemImage: "plus") {
                        editing = Category(id: "", name: "", symbol: "star.fill", colour: store.categories.count % Palette.colours.count)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Lists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .sheet(item: $editing) { category in
                CategoryEditor(category: category)
            }
        }
    }
}

struct CategoryEditor: View {
    @State var category: Category
    @Environment(\.dismiss) private var dismiss
    private var store: AgendaStore { .shared }

    static let symbols = ["briefcase.fill", "person.2.fill", "house.fill", "bag.fill", "heart.fill", "doc.text.fill",
                          "sparkles", "star.fill", "cart.fill", "airplane", "book.fill", "dumbbell.fill",
                          "fork.knife", "gift.fill", "pawprint.fill", "car.fill", "graduationcap.fill", "paintbrush.fill",
                          "leaf.fill", "wrench.and.screwdriver.fill", "creditcard.fill", "music.note", "camera.fill", "lightbulb.fill"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        CategoryIcon(category: category, size: 72)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    TextField("Name", text: $category.name)
                        .font(.title3.weight(.medium))
                }
                Section("Colour") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Palette.colours.indices, id: \.self) { index in
                            Circle()
                                .fill(Palette.colour(index).gradient)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if category.colour == index {
                                        Circle().strokeBorder(.primary, lineWidth: 3).padding(-4)
                                    }
                                }
                                .onTapGesture { category.colour = index }
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.system(size: 17))
                                .frame(width: 40, height: 40)
                                .foregroundStyle(category.symbol == symbol ? .white : .primary)
                                .background(category.symbol == symbol ? category.tint : Color.gray.opacity(0.15), in: Circle())
                                .onTapGesture { category.symbol = symbol }
                        }
                    }
                    .padding(.vertical, 6)
                }
                if !category.isInbox {
                    Section {
                        TextField("e.g. gym, physio", text: $category.hint, axis: .vertical)
                    } header: {
                        Text("Keywords")
                    } footer: {
                        Text("Say or type the list's name (\"\(category.name.isEmpty ? "work" : category.name.lowercased()) list\", #\(category.name.isEmpty ? "work" : category.name.lowercased().filter { $0.isLetter })) to file a to-do here. Add other words, separated by commas, that should file it here too. Anything else goes in Unsorted.")
                    }
                }
            }
            .navigationTitle(category.id.isEmpty ? "New list" : "Edit list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        category.name = category.name.trimmingCharacters(in: .whitespaces)
                        if category.id.isEmpty { category.id = store.newCategoryID(for: category.name) }
                        store.upsertCategory(category)
                        dismiss()
                    }
                    .disabled(category.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Lays out tag chips in rows that wrap.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
