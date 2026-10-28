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
    /// What Agenda has made of the words so far, shown live as Ian talks or types.
    private var readings: [QuickParse.Reading] {
        QuickParse.pieces(of: text).compactMap { QuickParse.read($0, categories: AgendaStore.shared.categories) }
    }
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
        let readings = self.readings
        return VStack(spacing: 18) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if text.isEmpty {
                            Text("Go ahead: anything you're trying to remember. Say \"tonight\" or \"next Monday at 5\" for a time, and \"work list\" or \"hashtag home\" to file it.")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(LivePreview.highlighted(text, readings: readings))
                                .font(.title3)
                                .contentTransition(.interpolate)
                            LivePreview(readings: readings)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.snappy(duration: 0.25), value: readings.count)
                    Color.clear.frame(height: 1).id("end")
                }
                .defaultScrollAnchor(.bottom)
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
        transcriber.vocabulary = Sorter.vocabulary()
        if KeyStore.hasClaudeKey { Claude.warmUp() }
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
        let final = (words.isEmpty ? text : words).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { return }
        // One short thing ("respond to John tonight") is added straight away; a ramble gets sorted.
        let sentences = QuickParse.expandShorthand(final).split(whereSeparator: { ".!?\n".contains($0) }).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !Demo.isOn, final.split(whereSeparator: \.isWhitespace).count <= 14, sentences.count <= 1,
           !final.lowercased().contains(" and also "), let item = Sorter.quickAdd(final, source: .voice) {
            Router.shared.showAdded(item)
            dismiss()
            return
        }
        Router.shared.sort(final, source: .voice)
    }

    // MARK: - Typing

    private var typingView: some View {
        let readings = self.readings
        return VStack(spacing: 14) {
            TextField("Type a to-do, or everything on your mind…", text: $text, axis: .vertical)
                .font(.title3)
                .lineLimit(3...12)
                .focused($typing)
                .padding(14)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                .submitLabel(.return)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Try \"Respond to John TN\" or \"Call the bank next Mon at 5pm #money\". Name a list (#work, \"home list\") to file it; otherwise it goes in Unsorted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LivePreview(readings: readings)
                        .animation(.snappy(duration: 0.25), value: readings.count)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity, alignment: .top)
            }

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
        if isQuickAdd, let item = Sorter.quickAdd(trimmed) {
            Router.shared.showAdded(item)
            text = ""
            dismiss()
        } else {
            Router.shared.sort(trimmed, source: .typed)
        }
    }
}

/// The to-dos Agenda can see in what Ian is saying or typing, with the day, list and tags it picked up.
struct LivePreview: View {
    let readings: [QuickParse.Reading]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                row(reading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func row(_ reading: QuickParse.Reading) -> some View {
        let item = reading.item
        let list = AgendaStore.shared.category(item.categoryID)
        return VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 6) {
                if let due = item.due {
                    Chip(text: DateWords.short(due, hasTime: item.hasTime), symbol: item.hasTime ? "clock" : "calendar", tint: .red)
                }
                Chip(text: list.name, symbol: list.symbol, tint: list.isInbox ? .secondary : list.tint)
                ForEach(item.tagList, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.purple)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// The words as heard, with days and times, lists and tags picked out in colour.
    static func highlighted(_ text: String, readings: [QuickParse.Reading]) -> AttributedString {
        var result = AttributedString(text)
        var searchFrom = result.startIndex
        func mark(_ phrase: String, _ colour: Color) {
            let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { return }
            let range = result[searchFrom...].range(of: phrase, options: .caseInsensitive)
                ?? result.range(of: phrase, options: .caseInsensitive)
            guard let range else { return }
            result[range].foregroundColor = colour
            result[range].backgroundColor = colour.opacity(0.14)
        }
        let store = AgendaStore.shared
        for reading in readings {
            let list = store.category(reading.item.categoryID)
            reading.whenPhrases.forEach { mark($0, .red) }
            reading.listPhrases.forEach { mark($0, list.tint) }
            reading.tagPhrases.forEach { mark($0, .purple) }
            // Later pieces are further along, so keep searching forward.
            if let first = reading.item.title.split(separator: " ").first,
               let range = result[searchFrom...].range(of: String(first), options: .caseInsensitive) {
                searchFrom = range.upperBound
            }
        }
        return result
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
