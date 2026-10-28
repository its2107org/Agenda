import AppIntents
import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct AgendaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    if await SelfTest.runIfRequested() { return }
                    await Demo.runIfRequested()
                    guard !Demo.isOn else { return }
                    // Gets the speech engine ready now, so the microphone starts instantly later.
                    Task.detached(priority: .utility) { try? await LiveTranscriber.prepareSpeechFiles() }
                    await Nudges.requestPermissions()
                    await Nudges.rescheduleAll()
                    AgendaStore.shared.tidyOldDone()
                }
                .onOpenURL { url in Router.shared.open(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !Demo.isOn, !SelfTest.isRequested else { return }
            if phase == .background { AgendaStore.shared.flushPending() }
            guard phase == .active else { return }
            AgendaStore.shared.reload()
            AgendaStore.shared.writeSnapshot()
            Router.shared.checkShareInbox()
            Task {
                await CalendarLink.shared.refresh()
                await Nudges.rescheduleAll()
            }
            BackgroundRefresh.schedule()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Nudges.registerCategories()
        BackgroundRefresh.register()
        AgendaShortcuts.updateAppShortcutParameters()
        return true
    }

    // Show nudges even while Agenda is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    // Buttons on a nudge (Done, In an hour, Tomorrow), or a tap on it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        await Nudges.handle(action: action, userInfo: info)
    }
}

/// Keeps the morning and evening round-ups fresh even if Agenda isn't opened for a while.
enum BackgroundRefresh {
    static let identifier = "agenda.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            schedule()
            let work = Task { @MainActor in
                AgendaStore.shared.reload()
                AgendaStore.shared.writeSnapshot()
                await Nudges.rescheduleAll()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

enum AppTab: Hashable {
    case today, lists, calendar, routines, search
}

/// Which screen and sheet are showing. Siri, widgets and links use it to jump to the right place.
@MainActor
@Observable
final class Router {
    static let shared = Router()

    enum Sheet: Identifiable, Equatable {
        case brainDump(listening: Bool)
        case review
        case settings
        case newItem
        case item(UUID)
        case routine(UUID?)

        var id: String {
            switch self {
            case .brainDump: "dump"
            case .review: "review"
            case .settings: "settings"
            case .newItem: "new"
            case .item(let id): "item-\(id)"
            case .routine(let id): "routine-\(id?.uuidString ?? "new")"
            }
        }
    }

    var tab: AppTab = .today
    var sheet: Sheet?
    /// What the sorter suggested, waiting for Ian to check on the review sheet.
    var proposals: [Proposal] = []
    var proposalNote: String?
    var isSorting = false
    var sortingLabel = ""

    /// A short "Added …" note shown after a quick add, so Ian can see where it went.
    var toast: Toast?

    struct Toast: Equatable {
        var id = UUID()
        var itemID: UUID
        var title: String
        var detail: String
    }

    private init() {}

    func showAdded(_ item: Item) {
        let store = AgendaStore.shared
        var parts: [String] = []
        if let due = item.due { parts.append(DateWords.short(due, hasTime: item.hasTime)) }
        parts.append(store.category(item.categoryID).name)
        parts += item.tagList.map { "#\($0)" }
        let toast = Toast(itemID: item.id, title: item.title, detail: parts.joined(separator: " · "))
        self.toast = toast
        guard !Demo.isOn else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if self.toast?.id == toast.id { self.toast = nil }
        }
    }

    /// Shows the latest version of a quick-added to-do (the AI may have refined its list and tags).
    func refreshToast() {
        guard let toast, let item = AgendaStore.shared.item(toast.itemID) else { return }
        var parts: [String] = []
        if let due = item.due { parts.append(DateWords.short(due, hasTime: item.hasTime)) }
        parts.append(AgendaStore.shared.category(item.categoryID).name)
        parts += item.tagList.map { "#\($0)" }
        self.toast?.detail = parts.joined(separator: " · ")
    }

    func startBrainDump(listening: Bool) {
        sheet = .brainDump(listening: listening)
    }

    func open(_ url: URL) {
        guard url.scheme == "agenda" else { return }
        switch url.host() {
        case "dump": startBrainDump(listening: true)
        case "type", "new": startBrainDump(listening: false)
        case "today": tab = .today
        case "calendar": tab = .calendar
        case "reminders": tab = .routines
        case "item":
            if let id = UUID(uuidString: url.lastPathComponent) { sheet = .item(id) }
        case "routine":
            if let id = UUID(uuidString: url.lastPathComponent) { sheet = .routine(id) }
        default: break
        }
    }

    /// Sorts words Ian said or typed, then shows the suggestions for him to check.
    func sort(_ text: String, source: Item.Source) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSorting = true
        sortingLabel = "Sorting your list…"
        sheet = .review
        Task {
            let outcome = await Sorter.sort(trimmed, categories: AgendaStore.shared.categories, source: source)
            proposals = outcome.proposals
            proposalNote = outcome.note
            isSorting = false
        }
    }

    /// Picks up anything shared to Agenda from another app and sorts it.
    func checkShareInbox() {
        let drops = ShareInbox.all()
        guard !drops.isEmpty, !isSorting, sheet == nil else { return }
        isSorting = true
        sortingLabel = drops.count == 1 ? "Reading what you shared…" : "Reading \(drops.count) things you shared…"
        sheet = .review
        Task {
            var all: [Proposal] = []
            var notes: [String] = []
            for drop in drops {
                let outcome = await Sorter.sortShared(drop, categories: AgendaStore.shared.categories)
                all += outcome.proposals
                if let note = outcome.note { notes.append(note) }
                ShareInbox.remove(drop.id)
            }
            proposals = all
            proposalNote = notes.first
            isSorting = false
        }
    }
}
