import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(StaysStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var name = ""
    @State private var choosing = false
    @State private var matches: [Person] = []
    @State private var confirmStop = false
    @State private var problem: String?
    @State private var sharing = false

    var body: some View {
        Form {
            Section("You") {
                TextField("Your name", text: $name)
                    .onSubmit { store.setName(name) }
                    .submitLabel(.done)
            }

            Section {
                LabeledContent("Kept in", value: store.folderName)
                ForEach(store.everyone) { p in
                    HStack {
                        Avatar(person: p, isMe: p.id == store.me.id)
                        Text(p.name)
                        Spacer()
                        let count = store.hotels.filter { store.review($0.id, by: p.id) != nil }.count
                        Text("\(count) rated").foregroundStyle(.secondary)
                    }
                }
                if store.library.isShared {
                    Button { sharing = true } label: { Label("Invite someone", systemImage: "person.badge.plus") }
                    Button { choosing = true } label: { Label("Use a different folder", systemImage: "folder") }
                    Button(role: .destructive) { confirmStop = true } label: { Label("Stop sharing on this phone", systemImage: "icloud.slash") }
                } else {
                    Button { choosing = true } label: { Label("Share with your partner", systemImage: "person.2") }
                }
                if let problem { Text(problem).foregroundStyle(.red).font(.footnote) }
            } header: {
                Text("Sharing")
            } footer: {
                Text(store.library.isShared
                     ? "You both see the same hotels. Each of you gives your own scores."
                     : "Pick a folder in iCloud Drive and share it with your partner, and you'll both see the same list.")
            }

            Section("Rated on") {
                ForEach(Dimension.allCases) { d in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name)
                            Text(d.hint).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: d.symbol).foregroundStyle(Color.accentColor)
                    }
                }
            }

            Section {
                LabeledContent("Hotels", value: "\(store.hotels.count)")
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
            }
        }
        .navigationTitle("Settings")
        .onAppear { name = store.mine.name }
        .onDisappear { if name != store.mine.name { store.setName(name) } }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do {
                matches = try store.useSharedFolder(url)
                problem = nil
                if matches.isEmpty { sharing = true }
            } catch {
                problem = "Couldn't use that folder. Try another one."
            }
        }
        .sheet(isPresented: Binding(get: { !matches.isEmpty }, set: { if !$0 { matches = [] } })) {
            WhoAreYou(people: matches) { person in
                if let person { store.becomeExisting(person) }
                matches = []
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $sharing) { SharingGuide() }
        .confirmationDialog("Stop sharing on this phone?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) { store.stopSharing() }
        } message: {
            Text("A copy of everything stays on this phone. The shared folder isn't touched.")
        }
    }
}

/// How to invite your partner: share the folder from the Files app.
struct SharingGuide: View {
    @Environment(StaysStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Invite your partner")
                        .font(.title.weight(.bold))
                    step(1, "Tap **Open in Files** below. You'll see your “\(store.folderName)” folder.")
                    step(2, "Press and hold the folder, tap **Share**, then make sure it says **Only invited people can make changes**.")
                    step(3, "Pick **Messages** and send it to them. They tap the link to accept.")
                    step(4, "On their phone, they open Stays, tap **Join my partner's list**, and pick the “\(store.folderName)” folder.")

                    Button {
                        if let url = filesURL { openURL(url) }
                    } label: {
                        Label("Open in Files", systemImage: "folder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .padding(.top, 8)

                    ShareLink(item: store.library.root) {
                        Label("Or share from here", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 2)
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    /// The Files app, opened at the folder's parent so the folder is easy to press and hold.
    private var filesURL: URL? {
        let parent = store.library.root.deletingLastPathComponent().path
        let encoded = parent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parent
        return URL(string: "shareddocuments://\(encoded)")
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: .circle)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
