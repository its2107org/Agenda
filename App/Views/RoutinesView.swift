import AlarmKit
import SwiftUI
import UserNotifications

/// Standing reminders: rent, Mounjaro, anything that comes round again. They keep nudging until done.
struct RoutinesView: View {
    private var store: AgendaStore { .shared }
    @State private var preset: Routine?

    var body: some View {
        NavigationStack {
            let _ = store.revision
            TimelineView(.everyMinute) { _ in
                List {
                    PermissionBanner()
                    if store.routines.isEmpty {
                        Section {
                            EmptyNote(symbol: "repeat.circle", title: "No standing reminders yet",
                                      message: "They come round on a schedule and keep nudging you until you tap Done.")
                            presetButtons
                        }
                    } else {
                        Section {
                            ForEach(store.routines) { routine in
                                RoutineCard(routine: routine)
                            }
                        }
                        Section {
                            presetButtons
                        } header: {
                            Text("Add")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Reminders")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New reminder", systemImage: "plus") { Router.shared.sheet = .routine(nil) }
                }
            }
            .sheet(item: $preset) { routine in
                RoutineEditor(routine: routine, isNew: true)
            }
        }
    }

    @ViewBuilder
    private var presetButtons: some View {
        if !store.routines.contains(where: { $0.title.localizedCaseInsensitiveContains("mounjaro") }) {
            Button { preset = Routine.mounjaroPreset() } label: {
                Label("Mounjaro (every 3½ days)", systemImage: "syringe.fill")
            }
        }
        if !store.routines.contains(where: { $0.title.localizedCaseInsensitiveContains("rent") }) {
            Button { preset = Routine.rentPreset() } label: {
                Label("Pay rent (monthly)", systemImage: "house.fill")
            }
        }
        Button { Router.shared.sheet = .routine(nil) } label: {
            Label("Something else", systemImage: "plus.circle")
        }
    }
}

/// A standing reminder with its next date, injection spot and pen count.
struct RoutineCard: View {
    let routine: Routine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoutineRow(routine: routine)
            if !routine.isPaused && (routine.suggestedSite != nil || routine.trackSupply) {
                HStack(spacing: 14) {
                    if let site = routine.suggestedSite {
                        Label("Next: \(site)", systemImage: "figure.stand")
                    }
                    if routine.trackSupply {
                        Label("\(max(routine.dosesLeft, 0)) of \(routine.dosesPerPen) left", systemImage: "cross.vial.fill")
                            .foregroundStyle(routine.supplyWarning == nil ? Color.secondary : .orange)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 44)
            }
        }
    }
}

struct RoutineDoneSheet: View {
    @Environment(\.dismiss) private var dismiss
    let routine: Routine
    @State private var site: String = ""
    @State private var restartFromNow = false
    private var store: AgendaStore { .shared }

    private var minutesLate: Int { Int(Date().timeIntervalSince(routine.nextDue) / 60) }

    private var isEvery: Bool {
        if case .every = routine.schedule { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                if routine.trackSites {
                    Section("Where did you inject?") {
                        Picker("Spot", selection: $site) {
                            ForEach(routine.sites, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                if isEvery && minutesLate > 60 {
                    Section {
                        Toggle("Count the next gap from now", isOn: $restartFromNow)
                    } footer: {
                        Text("You're \(RoutineSchedule.describe(hours: Double(minutesLate) / 60)) late. Turn this on to keep a full gap before the next one, or leave it off to stay on your usual days and times.")
                    }
                }
                if !routine.isDue() {
                    Section {
                        Text("This isn't due yet. Marking it done now moves you on to the next one.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(routine.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") {
                        store.markRoutineDone(routine.id, site: routine.trackSites ? site : nil, restartFromNow: restartFromNow)
                        dismiss()
                    }
                }
            }
            .onAppear { site = routine.suggestedSite ?? routine.sites.first ?? "" }
        }
    }
}

struct RoutineEditor: View {
    @State var routine: Routine
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    private var store: AgendaStore { .shared }

    @State private var kind: Kind = .weekdays
    @State private var everyDays = 3
    @State private var everyHours = 12
    @State private var weekdays: Set<Int> = [2]
    @State private var time = Date()
    @State private var monthDay = 1
    @State private var sitesText = ""
    @State private var confirmDelete = false
    @State private var showHistory = false

    enum Kind: String, CaseIterable, Identifiable {
        case every = "Every few days"
        case weekdays = "Weekly"
        case monthly = "Monthly"
        var id: String { rawValue }
    }

    static let symbols = ["repeat", "syringe.fill", "pills.fill", "cross.vial.fill", "heart.fill", "drop.fill",
                          "house.fill", "creditcard.fill", "doc.text.fill", "trash.fill", "leaf.fill", "pawprint.fill",
                          "phone.fill", "cart.fill", "bed.double.fill", "figure.run"]
    static let nagChoices = [1, 2, 5, 10, 15, 30, 60, 120, 240]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Pay rent", text: $routine.title)
                        .font(.title3.weight(.medium))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.symbols, id: \.self) { symbol in
                                Image(systemName: symbol)
                                    .font(.system(size: 17))
                                    .frame(width: 42, height: 42)
                                    .foregroundStyle(routine.symbol == symbol ? .white : .primary)
                                    .background(routine.symbol == symbol ? store.category(routine.categoryID).tint : Color.gray.opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 11))
                                    .onTapGesture { routine.symbol = symbol }
                            }
                        }
                    }
                    Picker("List", selection: $routine.categoryID) {
                        ForEach(store.categories) { Label($0.name, systemImage: $0.symbol).tag($0.id) }
                    }
                }

                Section {
                    Picker("Repeats", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch kind {
                    case .every:
                        Stepper("Every \(everyDays) day\(everyDays == 1 ? "" : "s")", value: $everyDays, in: 0...60)
                        Stepper("and \(everyHours) hour\(everyHours == 1 ? "" : "s")", value: $everyHours, in: 0...23)
                        DatePicker("Next one due", selection: $routine.nextDue)
                    case .weekdays:
                        WeekdayPicker(selection: $weekdays, tint: store.category(routine.categoryID).tint)
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    case .monthly:
                        Picker("Day of the month", selection: $monthDay) {
                            ForEach(1...31, id: \.self) { Text(RoutineSchedule.ordinal($0)).tag($0) }
                        }
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("When")
                } footer: {
                    switch kind {
                    case .every: Text("For twice a week, choose 3 days and 12 hours, then set when the next one is due. Agenda keeps that rhythm, for example Sunday 8am, then Wednesday 8pm.")
                    case .monthly: Text("In shorter months, the 31st becomes the last day of the month.")
                    case .weekdays: EmptyView()
                    }
                }

                Section {
                    Toggle("Ring like an alarm", isOn: $routine.useAlarm)
                    Picker("Nudge again every", selection: $routine.nagMinutes) {
                        ForEach(Self.nagChoices, id: \.self) { minutes in
                            Text(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hour\(minutes == 60 ? "" : "s")").tag(minutes)
                        }
                    }
                } header: {
                    Text("Nudges")
                } footer: {
                    Text("The alarm sounds even when your phone is on silent. Either way, Agenda keeps nudging until you tap Done.")
                }

                Section {
                    Toggle("Suggest where to inject", isOn: $routine.trackSites)
                    if routine.trackSites {
                        TextField("Spots, one per line", text: $sitesText, axis: .vertical)
                            .lineLimit(3...8)
                    }
                    Toggle("Count doses left in pen", isOn: $routine.trackSupply)
                    if routine.trackSupply {
                        Stepper("Doses per pen: \(routine.dosesPerPen)", value: $routine.dosesPerPen, in: 1...20)
                        Stepper("Doses left now: \(routine.dosesLeft)", value: $routine.dosesLeft, in: 0...20)
                        Button("Start a new pen") { routine.dosesLeft = routine.dosesPerPen }
                    }
                    TextField("Current dose, e.g. 5 mg (optional)", text: $routine.doseNote)
                } header: {
                    Text("Medication extras")
                }

                if !isNew {
                    Section {
                        Button("History", systemImage: "clock.arrow.circlepath") { showHistory = true }
                        Toggle("Pause", isOn: $routine.isPaused)
                        Button("Delete reminder", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "New reminder" : "Edit reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { save() }
                        .disabled(routine.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete \(routine.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    store.deleteRoutine(routine.id)
                    dismiss()
                }
            }
            .sheet(isPresented: $showHistory) { RoutineHistory(routine: routine) }
            .onAppear(perform: load)
        }
    }

    private func load() {
        sitesText = routine.sites.joined(separator: "\n")
        let calendar = Calendar.current
        func setTime(_ hour: Int, _ minute: Int) {
            time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        }
        switch routine.schedule {
        case .every(let hours):
            kind = .every
            let total = Int(hours.rounded())
            everyDays = total / 24
            everyHours = total % 24
        case .weekdays(let days, let hour, let minute):
            kind = .weekdays
            weekdays = Set(days)
            setTime(hour, minute)
        case .monthly(let day, let hour, let minute):
            kind = .monthly
            monthDay = day
            setTime(hour, minute)
        }
    }

    private func save() {
        routine.title = routine.title.trimmingCharacters(in: .whitespaces)
        let sites = sitesText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        routine.sites = sites.isEmpty ? Routine.defaultSites : sites
        if routine.dosesLeft > routine.dosesPerPen { routine.dosesLeft = routine.dosesPerPen }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let old = store.routine(routine.id)?.schedule

        switch kind {
        case .every:
            routine.schedule = .every(hours: Double(max(everyDays * 24 + everyHours, 1)))
        case .weekdays:
            let days = weekdays.isEmpty ? [2] : Array(weekdays).sorted()
            routine.schedule = .weekdays(days: days, hour: comps.hour ?? 9, minute: comps.minute ?? 0)
        case .monthly:
            routine.schedule = .monthly(day: monthDay, hour: comps.hour ?? 9, minute: comps.minute ?? 0)
        }
        // For weekly and monthly ones, work out the next date from now when the schedule changed.
        if kind != .every && (isNew || old != routine.schedule) {
            routine.nextDue = Routine.occurrence(of: routine.schedule, after: Date(), anchor: Date(), calendar: .current)
        }
        if routine.useAlarm {
            Task { _ = await Nudges.requestAlarmPermission(); await Nudges.rescheduleAll() }
        }
        store.upsertRoutine(routine)
        dismiss()
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    var tint: Color = .accentColor

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        HStack {
            ForEach(1...7, id: \.self) { day in
                let isOn = selection.contains(day)
                Text(symbols[day - 1])
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .foregroundStyle(isOn ? .white : .primary)
                    .background(isOn ? tint : Color.gray.opacity(0.15), in: Circle())
                    .onTapGesture {
                        if isOn { selection.remove(day) } else { selection.insert(day) }
                    }
            }
        }
    }
}

struct RoutineHistory: View {
    let routine: Routine
    @Environment(\.dismiss) private var dismiss
    private var store: AgendaStore { .shared }

    var body: some View {
        NavigationStack {
            let entries = store.log(for: routine.id)
            List {
                if entries.isEmpty {
                    Text("Nothing logged yet.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.doneDate.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))
                        let late = entry.doneDate.timeIntervalSince(entry.dueDate) / 3600
                        Text([late > 1 ? "\(RoutineSchedule.describe(hours: late)) late" : "On time",
                              entry.site ?? "", entry.doseNote ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { store.deleteLog(entries[index].id) }
                }
            }
            .navigationTitle("\(routine.title) history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: historyText) { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    private var historyText: String {
        let lines = store.log(for: routine.id).map { entry in
            [entry.doneDate.formatted(date: .abbreviated, time: .shortened), entry.site ?? "", entry.doseNote ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " – ")
        }
        return "\(routine.title)\n" + lines.joined(separator: "\n")
    }
}

/// Warns when notifications (or alarms) are switched off for Agenda.
struct PermissionBanner: View {
    @State private var notificationsAllowed = true
    @State private var alarmsAllowed = true
    @Environment(\.scenePhase) private var scenePhase
    private var store: AgendaStore { .shared }

    var body: some View {
        Group {
            if !notificationsAllowed || (!alarmsAllowed && store.routines.contains(where: \.useAlarm)) {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Agenda can't nudge you yet", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                        Text("Tap below, then turn on \(notificationsAllowed ? "Alarms" : "Notifications") for Agenda.")
                            .font(.subheadline)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.yellow.opacity(0.2))
            }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { Task { await refresh() } }
    }

    private func refresh() async {
        guard !Demo.isOn else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus != .denied
        alarmsAllowed = AlarmManager.shared.authorizationState != .denied
    }
}
