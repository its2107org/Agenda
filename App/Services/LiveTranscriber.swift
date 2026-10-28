@preconcurrency import AVFoundation
import Foundation
import Speech

/// Listens to the microphone and turns speech into text with Apple's on-device speech engine.
/// Audio never leaves the phone and is never saved.
@MainActor
final class LiveTranscriber {
    enum Problem: LocalizedError {
        case microphoneDenied
        case microphoneUnavailable(String)
        case languageUnsupported
        case speechUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Agenda isn't allowed to use the microphone. Open Settings, tap Agenda and switch on Microphone."
            case .microphoneUnavailable(let detail):
                "The microphone couldn't start (\(detail))."
            case .languageUnsupported:
                "This iPhone's speech engine doesn't support English (UK) yet."
            case .speechUnavailable(let detail):
                "The speech engine couldn't start (\(detail))."
            }
        }
    }

    /// Called with the words heard so far, as they arrive.
    var onUpdate: ((String) -> Void)?
    /// Called on the audio thread with how loud Ian is speaking (0 to 1), for the little level meter.
    var onLevel: (@Sendable (Float) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""

    var currentText: String { (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }

    static var microphonePermission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Words the speech engine should expect: names, tags, list names, medicines.
    var vocabulary: [String] = []

    /// Which engine and language to use, worked out once.
    private static var chosenLocale: Locale?
    private static var useDictation = false
    /// Set once Apple's speech files are known to be on the phone, so later starts skip the check.
    private static var speechFilesReady = false

    /// The speech engine for British English, downloaded once by iOS if it isn't on the phone yet.
    static func makeModule() async throws -> any SpeechModule {
        if chosenLocale == nil {
            let wanted = Locale(identifier: "en-GB")
            if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
                chosenLocale = locale
                useDictation = false
            } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
                chosenLocale = locale
                useDictation = true
            } else {
                throw Problem.languageUnsupported
            }
        }
        let locale = chosenLocale!
        if useDictation {
            return DictationTranscriber(locale: locale,
                                        contentHints: [],
                                        transcriptionOptions: [.punctuation],
                                        reportingOptions: [.volatileResults],
                                        attributeOptions: [])
        }
        return SpeechTranscriber(locale: locale,
                                 transcriptionOptions: [],
                                 reportingOptions: [.volatileResults],
                                 attributeOptions: [])
    }

    /// Makes sure Apple's speech files for English are on the phone. Returns quickly if they are.
    /// Run when Agenda opens, so the microphone button starts straight away later.
    static func prepareSpeechFiles() async throws {
        guard !speechFilesReady else { return }
        let module = try await makeModule()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        speechFilesReady = true
    }

    func start() async throws {
        switch Self.microphonePermission {
        case .denied: throw Problem.microphoneDenied
        case .undetermined:
            guard await Self.requestMicrophone() else { throw Problem.microphoneDenied }
        default: break
        }

        finalized = ""
        volatile = ""

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            throw Problem.microphoneUnavailable(error.localizedDescription)
        }

        let module = try await Self.makeModule()
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw Problem.speechUnavailable("no audio format")
        }

        // Start the microphone first. What Ian says waits in the stream while the speech engine gets
        // ready, so the first words aren't lost.
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = builder
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw Problem.microphoneUnavailable("no microphone input")
        }
        let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        input.removeTap(onBus: 0)
        Self.installTap(on: input, format: inputFormat, converter: converter, analyzerFormat: analyzerFormat,
                        builder: builder, level: onLevel)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Problem.microphoneUnavailable(error.localizedDescription)
        }

        do {
            if !Self.speechFilesReady {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
                Self.speechFilesReady = true
            }

            let analyzer = SpeechAnalyzer(modules: [module])
            self.analyzer = analyzer
            if !vocabulary.isEmpty {
                // Helps it spell names and unusual words the way Ian uses them.
                let context = AnalysisContext()
                context.contextualStrings[.general] = Array(vocabulary.prefix(100))
                try? await analyzer.setContext(context)
            }

            resultsTask = Task { [weak self] in
                do {
                    if let transcriber = module as? SpeechTranscriber {
                        for try await result in transcriber.results {
                            self?.receive(String(result.text.characters), isFinal: result.isFinal)
                        }
                    } else if let dictation = module as? DictationTranscriber {
                        for try await result in dictation.results {
                            self?.receive(String(result.text.characters), isFinal: result.isFinal)
                        }
                    }
                } catch {
                    // The stream ends with an error if the engine is torn down early; what was heard is kept.
                }
            }

            try await analyzer.start(inputSequence: stream)
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            builder.finish()
            inputBuilder = nil
            throw Problem.speechUnavailable(error.localizedDescription)
        }
    }

    /// Stops listening and returns everything that was said.
    func stop() async -> String {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputBuilder?.finish()
        inputBuilder = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        return currentText
    }

    func cancel() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputBuilder?.finish()
        inputBuilder = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        onUpdate?(currentText)
    }

    // MARK: - Audio helpers (run on the audio thread)

    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               converter: AVAudioConverter?, analyzerFormat: AVAudioFormat,
                                               builder: AsyncStream<AnalyzerInput>.Continuation,
                                               level: (@Sendable (Float) -> Void)?) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let level { level(Self.level(of: buffer)) }
            guard let converted = convert(buffer, with: converter, to: analyzerFormat) else { return }
            builder.yield(AnalyzerInput(buffer: converted))
        }
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in stride(from: 0, to: count, by: 4) { sum += data[i] * data[i] }
        let rms = (sum / Float(max(count / 4, 1))).squareRoot()
        return min(1, max(0, (20 * log10(max(rms, 0.000_01)) + 50) / 50))
    }
}
