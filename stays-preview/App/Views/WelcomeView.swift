import SwiftUI
import UniformTypeIdentifiers

/// First run: your name, then start a list, join your partner's, or keep it on this phone.
struct WelcomeView: View {
    @Environment(StaysStore.self) private var store
    @State private var name = ""
    @State private var step = 0
    @State private var choosing: FolderChoice?
    @State private var matches: [Person] = []
    @State private var problem: String?
    @FocusState private var nameFocused: Bool

    enum FolderChoice { case start, join }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "building.2.crop.circle.fill")
                .font(.system(size: 76, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 18)
            Text("Stays")
                .font(.largeTitle.weight(.bold))
            Text("The hotels you've stayed at, and what you both thought.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 6)
            Spacer()

            if step == 0 {
                VStack(spacing: 14) {
                    TextField("Your first name", text: $name)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .textContentType(.givenName)
                        .submitLabel(.next)
                        .focused($nameFocused)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
                        .onSubmit(next)
                    Button(action: next) {
                        Text("Next").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 24)
                .onAppear { nameFocused = true }
            } else {
                VStack(spacing: 12) {
                    choice("Start our list", "Pick or make a folder in iCloud Drive to share", "plus.circle.fill") { choosing = .start }
                    choice("Join my partner's list", "Pick the folder they shared with you", "person.2.circle.fill") { choosing = .join }
                    Button("Just on this phone for now") { finish() }
                        .font(.subheadline)
                        .padding(.top, 6)
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
            }
            Spacer().frame(height: 40)
        }
        .fileImporter(isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                      allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                do {
                    matches = try store.useSharedFolder(url)
                    if matches.isEmpty {
                        finish()
                        if choosing == .start { Router.shared.showInvite = true }
                    }
                } catch {
                    problem = "Couldn't use that folder. Try another one."
                }
            case .failure:
                break
            }
            choosing = nil
        }
        .sheet(isPresented: Binding(get: { !matches.isEmpty }, set: { if !$0 { matches = [] } })) {
            WhoAreYou(people: matches) { person in
                if let person { store.becomeExisting(person) }
                matches = []
                finish()
            }
            .presentationDetents([.medium])
        }
    }

    private func choice(_ title: String, _ detail: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func next() {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        store.setName(clean)
        withAnimation { step = 1 }
    }

    private func finish() {
        store.save()
        withAnimation { store.isSetUp = true }
    }
}

/// When a shared folder already has people in it: are you one of them (say, on a new phone)?
struct WhoAreYou: View {
    let people: [Person]
    let pick: (Person?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(people) { p in
                        Button { pick(p) } label: {
                            HStack {
                                Avatar(person: p, isMe: false)
                                Text("I'm \(p.name)").foregroundStyle(.primary)
                            }
                        }
                    }
                } footer: {
                    Text("Only pick yourself if you've used Stays before, for example on another phone.")
                }
                Section {
                    Button("No, I'm new here") { pick(nil) }
                }
            }
            .navigationTitle("Found your list")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
