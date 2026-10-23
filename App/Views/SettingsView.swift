import SwiftUI
import EventKit

struct SearchScreen: View {
    @State private var text = ""
    private var store: AgendaStore { .shared }

    var body: some View {
        NavigationStack {
            let _ = store.revision
            let results = store.search(text)
            List {
                if text.isEmpty {
                    EmptyNote(symbol: "magnifyingglass", title: "Search everything",
                              message: "To-dos, bookings and notes, done or not.")
                        .listRowBackground(Color.clear)
                } else if results.isEmpty {
                    Text("No matches.").foregroundStyle(.secondary)
                }
                ForEach(results) { ItemRow(item: $0).itemSwipes($0) }
            }
            .navigationTitle("Search")
            .searchable(text: $text, prompt: "To-dos and bookings")
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var calendarLink = CalendarLink.shared
    @State private var key = KeyStore.claudeKey ?? ""
    @State private var keyStatus: String?
    @State private var checking = false
    @State private var morningOn = Nudges.morningOn
    @State private var eveningOn = Nudges.eveningOn
    @State private var morning = Settings.date(minutes: Nudges.morningMinutes)
    @State private var evening = Settings.date(minutes: Nudges.eveningMinutes)
    @State private var bookingLead = Nudges.bookingLead

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Morning round-up", isOn: $morningOn)
                    if morningOn {
                        DatePicker("At", selection: $morning, displayedComponents: .hourAndMinute)
                    }
                    Toggle("Evening check", isOn: $eveningOn)
                    if eveningOn {
                        DatePicker("At", selection: $evening, displayedComponents: .hourAndMinute)
                    }
                    Picker("Heads-up before bookings", selection: $bookingLead) {
                        Text("Off").tag(0)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                        Text("1 day").tag(1440)
                    }
                } header: {
                    Text("Nudges")
                } footer: {
                    Text("The morning round-up lists today's to-dos and anything that slipped. The evening check tells you what's still open, with a button to move it all to tomorrow. To-dos with a time nudge you at that time, and again an hour later if they're not done.")
                }

                Section {
                    switch calendarLink.status {
                    case .fullAccess:
                        Toggle("Show my calendar", isOn: $calendarLink.showPhoneCalendar)
                        Toggle("Add bookings to my calendar", isOn: $calendarLink.copyBookings)
                    case .denied, .restricted:
                        Button("Allow in Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    default:
                        Button("Connect my calendar") {
                            Task { _ = await calendarLink.requestAccess() }
                        }
                    }
                } header: {
                    Text("Calendar")
                } footer: {
                    Text("Shows your calendar's events (iCloud, Google, work) next to your to-dos. Bookings you share to Agenda are copied into it too.")
                }

                Section {
                    SecureField("Paste your Claude key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button(checking ? "Checking…" : "Save key") { Task { await saveKey() } }
                            .disabled(checking)
                        Spacer()
                        if let keyStatus {
                            Text(keyStatus).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if KeyStore.hasClaudeKey {
                        LabeledContent("Spent this month", value: Spend.thisMonth.formatted(.currency(code: "USD")))
                        Button("Remove key", role: .destructive) {
                            KeyStore.claudeKey = nil
                            key = ""
                            keyStatus = "Removed"
                        }
                    }
                } header: {
                    Text("Smart sorting")
                } footer: {
                    Text("With your Claude key (the same one as in Decant), brain dumps and shared bookings are sorted by Claude, which is best at dates and splitting things up. A brain dump costs about 1 cent. Without a key, your phone's built-in AI sorts them, and nothing leaves the phone.")
                }

                Section {
                    Link(destination: URL(string: "agenda://dump")!) {
                        Label("Brain dump link (for the Action Button)", systemImage: "link")
                    }
                } footer: {
                    Text("To start a brain dump from the Action Button: open the Settings app, tap Action Button, swipe to Shortcut, tap Choose a Shortcut, then pick Agenda and Brain Dump.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .onChange(of: morningOn) { Nudges.morningOn = morningOn; Nudges.scheduleSoon() }
            .onChange(of: eveningOn) { Nudges.eveningOn = eveningOn; Nudges.scheduleSoon() }
            .onChange(of: morning) { Nudges.morningMinutes = Settings.minutes(morning); Nudges.scheduleSoon() }
            .onChange(of: evening) { Nudges.eveningMinutes = Settings.minutes(evening); Nudges.scheduleSoon() }
            .onChange(of: bookingLead) { Nudges.bookingLead = bookingLead; Nudges.scheduleSoon() }
            .onChange(of: calendarLink.showPhoneCalendar) { Task { await calendarLink.refresh() } }
        }
    }

    private func saveKey() async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        checking = true
        let previous = KeyStore.claudeKey
        KeyStore.claudeKey = trimmed
        do {
            try await Claude.checkKey()
            keyStatus = "Working ✓"
        } catch {
            keyStatus = (error as? LocalizedError)?.errorDescription ?? "Didn't work"
            if case ClaudeError.badKey = error { KeyStore.claudeKey = previous }
        }
        checking = false
    }
}

enum Settings {
    static func date(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    static func minutes(_ date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }
}
