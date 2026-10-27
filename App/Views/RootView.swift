import SwiftUI

struct RootView: View {
    @State private var router = Router.shared

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Today", systemImage: "sun.max.fill", value: AppTab.today) {
                TodayView()
            }
            Tab("Lists", systemImage: "square.grid.2x2.fill", value: AppTab.lists) {
                ListsView()
            }
            Tab("Calendar", systemImage: "calendar", value: AppTab.calendar) {
                CalendarScreen()
            }
            Tab("Reminders", systemImage: "repeat", value: AppTab.routines) {
                RoutinesView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchScreen()
            }
        }
        .tabViewBottomAccessory {
            BrainDumpBar()
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .top) {
            if let toast = router.toast {
                AddedToast(toast: toast)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture {
                        router.toast = nil
                        router.sheet = .item(toast.itemID)
                    }
            }
        }
        .animation(.snappy, value: router.toast)
        .onChange(of: AgendaStore.shared.revision) { router.refreshToast() }
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .brainDump(let listening):
                BrainDumpView(startListening: listening)
                    .presentationDetents([.medium, .large])
            case .review:
                ReviewView()
            case .settings:
                SettingsView()
            case .newItem:
                ItemEditor(item: Item(title: "", categoryID: "personal"), isNew: true)
            case .item(let id):
                if let item = AgendaStore.shared.item(id) {
                    ItemEditor(item: item, isNew: false)
                } else {
                    EmptyNote(symbol: "questionmark.circle", title: "Already gone", message: "This one has been deleted.")
                        .presentationDetents([.medium])
                }
            case .routine(let id):
                if let id, let routine = AgendaStore.shared.routine(id) {
                    RoutineEditor(routine: routine, isNew: false)
                } else {
                    RoutineEditor(routine: Routine(title: "", schedule: .weekdays(days: [2], hour: 9, minute: 0),
                                                   nextDue: Date().addingTimeInterval(3600)), isNew: true)
                }
            }
        }
    }
}

/// The bar above the tabs: tap the microphone to talk, or the pencil to type.
struct BrainDumpBar: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Router.shared.startBrainDump(listening: true)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.gradient, in: Circle())
                    if placement != .inline {
                        Text("Brain dump")
                            .font(.subheadline.weight(.semibold))
                        Text("say anything on your mind")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Brain dump: talk through everything on your mind")

            Button {
                Router.shared.startBrainDump(listening: false)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Type a to-do")
        }
        .padding(.horizontal, 12)
    }
}

/// "Added: Respond to John · Today 7:00 PM · Work · #John"
struct AddedToast: View {
    let toast: Router.Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(toast.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("Edit").font(.caption.weight(.semibold)).foregroundStyle(.tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
    }
}
