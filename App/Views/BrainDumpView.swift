import SwiftUI

/// Talk (or type) through everything on your mind; Agenda splits it into to-dos and sorts them.
struct BrainDumpView: View {
    let startListening: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var listening = false
    @State private var text = ""
    @State private var level: Float = 0
    @State private var problem: String?
    @State private var transcriber = LiveTranscriber()
    @State private var levels: [Float] = Array(repeating: 0, count: 28)
    @FocusState private var typing: Bool

    private var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
    /// A short single line is added straight away; anything longer goes through the sorter.
    private var isQuickAdd: Bool { !listening && wordCount <= 12 && !text.contains("\n") }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if listening {
                    listeningView
                } else {
                    typingView
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .navigationTitle(listening ? "Listening" : "Brain dump")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        Task { await transcriber.cancel() }
                        dismiss()
                    }
                }
            }
        }
        .task {
            transcriber.onUpdate = { words in text = words }
            transcriber.onLevel = { value in
                Task { @MainActor in
                    level = value
                    levels.removeFirst()
                    levels.append(value)
                }
            }
            if startListening && !Demo.isOn { await startListeningNow() }
            else if Demo.isOn && startListening {
                listening = true
                text = Demo.dumpText
                levels = (0..<28).map { i in Float(0.25 + 0.6 * abs(sin(Double(i) * 0.7))) }
            } else {
                typing = true
            }
        }
    }

    // MARK: - Listening

    private var listeningView: some View {
        VStack(spacing: 18) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "Go ahead: work, plans, chores, bookings, anything you're trying to remember…" : text)
                        .font(.title3)
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("end")
                }
                .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)

            Waveform(levels: levels)
                .frame(height: 36)

            HStack(spacing: 14) {
                Button {
                    Task {
                        _ = await transcriber.stop()
                        listening = false
                        typing = true
                    }
                } label: {
                    Image(systemName: "keyboard")
                        .font(.title3)
                        .frame(width: 54, height: 54)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Stop and edit the words")

                Button {
                    Task { await finishListening() }
                } label: {
                    Label("Sort it", systemImage: "wand.and.stars")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.glassProminent)
                .disabled(text.isEmpty && !Demo.isOn)
            }
            .padding(.bottom, 8)
        }
    }

    private func startListeningNow() async {
        problem = nil
        listening = true
        do {
            try await transcriber.start()
        } catch {
            listening = false
            typing = true
            problem = (error as? LocalizedError)?.errorDescription ?? "The microphone couldn't start."
        }
    }

    private func finishListening() async {
        let words = Demo.isOn ? text : await transcriber.stop()
        listening = false
        let final = words.isEmpty ? text : words
        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Router.shared.sort(final, source: .voice)
    }

    // MARK: - Typing

    private var typingView: some View {
        VStack(spacing: 14) {
            TextField("Type a to-do, or everything on your mind…", text: $text, axis: .vertical)
                .font(.title3)
                .lineLimit(3...12)
                .focused($typing)
                .padding(14)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                .submitLabel(.return)

            Text(isQuickAdd ? "Tip: \"Call Sam tomorrow at 3pm\" works. Longer lists get sorted for you."
                 : "Agenda will split this into separate to-dos and put each in the right list.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                Button {
                    Task { await startListeningNow() }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.title3)
                        .frame(width: 54, height: 54)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Talk instead")

                Button {
                    submitTyped()
                } label: {
                    Label(isQuickAdd ? "Add" : "Sort it", systemImage: isQuickAdd ? "plus" : "wand.and.stars")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.glassProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.bottom, 8)
        }
    }

    private func submitTyped() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isQuickAdd, let item = QuickParse.item(from: trimmed, categories: AgendaStore.shared.categories) {
            AgendaStore.shared.add([item])
            text = ""
            dismiss()
        } else {
            Router.shared.sort(trimmed, source: .typed)
        }
    }
}

struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 4, height: max(4, CGFloat(levels[index]) * 36))
            }
        }
        .animation(.easeOut(duration: 0.12), value: levels)
        .frame(maxWidth: .infinity)
    }
}
