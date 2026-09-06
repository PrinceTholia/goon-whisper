import Foundation
import AppKit
import Combine
import Carbon.HIToolbox
import ApplicationServices

/// Visual processing stage — drives the floating status overlay
enum Stage: Equatable {
    case idle
    case recording
    case transcribing
    case correcting
    case done(String)          // auto-pasted at caret
    case copied                // no caret — clipboard only; show ⌘V hint
    case error(String)
}

/// Orchestrates everything: record → transcribe (cloud/local) → correct (LLM) → paste into focused app
class DictationController: ObservableObject {
    @Published var isRecording = false
    @Published var status = ""
    @Published var stage: Stage = .idle
    @Published var useCloudSTT = true
    /// Off by default: Gemini SMART mode already cleans fillers / self-corrections.
    @Published var useCorrection: Bool {
        didSet { UserDefaults.standard.set(useCorrection, forKey: Self.correctionKey) }
    }
    /// Stream to gemini-3.5-transcribe-live while holding Fn (falls back to batch WAV).
    @Published var useLiveSTT: Bool {
        didSet { UserDefaults.standard.set(useLiveSTT, forKey: Self.liveKey) }
    }
    /// Wispr-style Backtrack: drop false starts / “sorry, I meant…” restatements. Default OFF.
    @Published var useBacktrack: Bool {
        didSet { UserDefaults.standard.set(useBacktrack, forKey: Self.backtrackKey) }
    }
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: Self.languageKey) }
    }

    private static let backtrackKey = "backtrackEnabled"
    private static let languageKey = "dictationLanguage"
    private static let correctionKey = "useCorrection"
    private static let liveKey = "useLiveSTT"

    let recorder = AudioRecorder()
    private let whisper = WhisperService()
    private let cloud = CloudTranscriptionService()
    private let correction = TextCorrectionService()
    private var liveSTT: GeminiLiveTranscriptionService?
    private var liveActive = false
    private var processing = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        useBacktrack = UserDefaults.standard.bool(forKey: Self.backtrackKey) // default false

        // One-time quality defaults for Gemini SMART / Live
        if !UserDefaults.standard.bool(forKey: "qualityDefaults130") {
            UserDefaults.standard.set(false, forKey: Self.correctionKey)
            UserDefaults.standard.set(true, forKey: Self.liveKey)
            UserDefaults.standard.set("auto", forKey: Self.languageKey)
            UserDefaults.standard.set(true, forKey: "qualityDefaults130")
        }

        if UserDefaults.standard.object(forKey: Self.correctionKey) == nil {
            useCorrection = false
        } else {
            useCorrection = UserDefaults.standard.bool(forKey: Self.correctionKey)
        }
        if UserDefaults.standard.object(forKey: Self.liveKey) == nil {
            useLiveSTT = true
        } else {
            useLiveSTT = UserDefaults.standard.bool(forKey: Self.liveKey)
        }
        language = UserDefaults.standard.string(forKey: Self.languageKey) ?? "auto"
        recorder.$recordedFileURL
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in self?.handleAudio(url) }
            .store(in: &cancellables)
    }

    func toggle() { recorder.isRecording ? stop() : start() }

    func start() {
        guard !processing, !recorder.isRecording else { return }
        FocusMemory.capture()

        let wantLive = useCloudSTT && useLiveSTT && STTSettings.current.style == .gemini
        if wantLive, let key = STTSettings.key(for: STTSettings.current) {
            var vocab = CorrectionDictionary.shared.vocabularyHints(limit: 80)
            if let app = FocusMemory.lastAppName { vocab.insert(app, at: 0) }
            let live = GeminiLiveTranscriptionService()
            liveSTT = live
            liveActive = false
            live.start(apiKey: key, vocabulary: vocab) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.liveActive = true
                        print("✅ Live STT ready")
                    case .failure(let err):
                        print("⚠️ Live STT setup failed (\(err.detailMessage)); will use batch on stop")
                        self.liveSTT = nil
                        self.liveActive = false
                    }
                }
            }
            recorder.onPCMChunk = { [weak live] data in live?.sendPCM(data) }
        } else {
            liveSTT = nil
            liveActive = false
            recorder.onPCMChunk = nil
        }

        recorder.startRecording()
        isRecording = recorder.isRecording
        if isRecording {
            FeedbackSound.playStart()
            status = wantLive ? "Listening (live)…" : "Listening…"
            stage = .recording
        } else {
            liveSTT?.cancel()
            liveSTT = nil
            status = "❌ Microphone unavailable"
            stage = .error("Microphone unavailable")
        }
    }

    func stop() {
        guard recorder.isRecording else { return }
        FeedbackSound.playStop()
        isRecording = false
        status = "⏳ Processing…"
        stage = .transcribing

        // Always keep WAV for batch fallback; Live runs in parallel when ready.
        let live = liveSTT
        let wasLive = liveActive
        liveSTT = nil
        liveActive = false
        recorder.onPCMChunk = nil

        if let live, wasLive {
            processing = true
            // Publish file URL is suppressed briefly — we handle both paths here
            let url = recorder.consumeRecordingURL()
            live.finish { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    if let url { try? FileManager.default.removeItem(at: url) }
                    self.afterSTT(.success(text))
                case .success, .failure:
                    print("⚠️ Live STT empty/failed — falling back to batch")
                    if let url {
                        self.handleAudio(url)
                    } else {
                        self.afterSTT(.failure(.emptyResponse))
                    }
                }
            }
            return
        }

        live?.cancel()
        recorder.stopRecording(publishFile: true)
    }

    private func handleAudio(_ url: URL) {
        processing = true
        let lang = language

        DispatchQueue.main.async {
            self.status = self.useCloudSTT ? "☁️ Transcribing…" : "📝 Transcribing…"
            self.stage = .transcribing
        }

        if useCloudSTT {
            cloud.transcribe(fileURL: url, language: lang) { result in
                try? FileManager.default.removeItem(at: url)
                self.afterSTT(result)
            }
        } else {
            whisper.language = lang
            whisper.transcribe(fileURL: url) { result in
                if let result {
                    self.afterSTT(.success(result))
                } else {
                    self.afterSTT(.failure(.emptyResponse))
                }
            }
        }
    }

    private func afterSTT(_ result: Result<String, DictationAPIError>) {
        let lang = language
        switch result {
        case .failure(let err):
            failOnMain(err)
        case .success(let raw):
            let text = stripSoundAnnotations(raw)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                failOnMain(.emptyResponse)
                return
            }
            if useCorrection {
                DispatchQueue.main.async {
                    self.status = "✨ AI correction…"
                    self.stage = .correcting
                }
                correction.correct(
                    text: text,
                    language: lang,
                    backtrack: UserDefaults.standard.bool(forKey: Self.backtrackKey)
                ) { [weak self] corr in
                    guard let self else { return }
                    switch corr {
                    case .success(let cleaned):
                        self.finishOnMain(cleaned)
                    case .failure(let err):
                        if case .rateLimited = err {
                            self.failOnMain(err)
                        } else if case .http(let status, _, _) = err, status == 429 {
                            self.failOnMain(err)
                        } else {
                            print("⚠️ Correction failed (\(err.detailMessage)); pasting raw transcript")
                            self.finishOnMain(text)
                        }
                    }
                }
            } else {
                finishOnMain(text)
            }
        }
    }

    private func finishOnMain(_ text: String) {
        DispatchQueue.main.async {
            let final = CorrectionDictionary.shared.apply(to: text)
            let snippet = String(final.prefix(28))
            self.processing = false

            let outcome = Paster.paste(final)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                DictionaryLearner.watchAfterPaste(final)
            }

            switch outcome {
            case .inserted:
                self.status = "✅ Pasted"
                self.stage = .done(snippet.isEmpty ? "Pasted" : snippet)
            case .copiedOnly:
                self.status = "Copied — press ⌘V to paste"
                self.stage = .copied
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + (outcome == .copiedOnly ? 2.8 : 1.0)) { [weak self] in
                guard let self = self else { return }
                if case .done = self.stage { self.stage = .idle }
                if case .copied = self.stage { self.stage = .idle }
            }
        }
    }

    private func failOnMain(_ err: DictationAPIError) {
        DispatchQueue.main.async {
            self.processing = false
            self.showAPIError(err)
        }
    }

    /// Show a clear pill + tooltip; for rate limits, countdown so the user knows to wait.
    private func showAPIError(_ err: DictationAPIError) {
        status = err.detailMessage
        stage = .error(err.pillMessage)
        print("❌ Dictation: \(err.detailMessage)")

        if case .rateLimited(let sec, _) = err {
            var left = Int(ceil(sec))
            let token = UUID().uuidString
            statusItemToken = token
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                guard let self = self, self.statusItemToken == token else {
                    timer.invalidate(); return
                }
                left -= 1
                if left <= 0 {
                    timer.invalidate()
                    self.status = "Ready — try again"
                    self.stage = .idle
                    return
                }
                self.stage = .error("Rate limit — wait ~\(left)s")
                self.status = "Rate limit — please wait \(left)s, then dictate again"
            }
            RunLoop.main.add(timer, forMode: .common)
            return
        }

        let hold = err.displaySeconds
        let msg = err.pillMessage
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self = self else { return }
            if case .error(let m) = self.stage, m == msg {
                self.stage = .idle
            }
        }
    }

    private var statusItemToken: String? = nil

    private func stripSoundAnnotations(_ text: String) -> String {
        var result = text
        let patterns = [
            "\\([^\\)]*\\)",
            "（[^）]*）",
            "\\[[^\\]]*\\]",
            "【[^】]*】",
            "\\*[^*]*\\*",
            "‹[^›]*›",
            "«[^»]*»",
        ]
        for p in patterns {
            result = result.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        result = result
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([,.!?])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
