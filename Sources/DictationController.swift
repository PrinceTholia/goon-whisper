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

/// Orchestrates everything: record → transcribe (Groq Whisper) → optional LLM correct → paste
class DictationController: ObservableObject {
    @Published var isRecording = false
    /// True while tap-Fn hands-free session is active (shows X / stop on pill; Esc cancels).
    @Published var handsFreeUI = false
    /// After hands-free Enter: paste then synthesize Return to send.
    private var sendEnterAfterPaste = false
    @Published var status = ""
    @Published var stage: Stage = .idle
    @Published var useCloudSTT = true
    /// Optional Groq LLM polish. Default follows existing UserDefaults (off if unset).
    @Published var useCorrection: Bool {
        didSet { UserDefaults.standard.set(useCorrection, forKey: Self.correctionKey) }
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

    let recorder = AudioRecorder()
    private let whisper = WhisperService()
    private let cloud = CloudTranscriptionService()
    private let correction = TextCorrectionService()
    /// True from stop until paste (or fail/cancel). Blocks a new `start()` so old WAV cannot paste into a new session.
    private(set) var processing = false
    /// Bumped on start / cancel so in-flight STT, correction, and paste no-op.
    private var sessionGeneration: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()
    private var statusItemToken: String? = nil
    private var rateLimitTimer: Timer?

    init() {
        useBacktrack = UserDefaults.standard.bool(forKey: Self.backtrackKey) // default false

        if !UserDefaults.standard.bool(forKey: "qualityDefaults131") {
            UserDefaults.standard.set(false, forKey: Self.correctionKey)
            UserDefaults.standard.set("auto", forKey: Self.languageKey)
            UserDefaults.standard.set(true, forKey: "qualityDefaults131")
        }

        if UserDefaults.standard.object(forKey: Self.correctionKey) == nil {
            useCorrection = false
        } else {
            useCorrection = UserDefaults.standard.bool(forKey: Self.correctionKey)
        }
        language = UserDefaults.standard.string(forKey: Self.languageKey) ?? "auto"
        recorder.$recordedFileURL
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in self?.handleAudio(url) }
            .store(in: &cancellables)
    }

    var isBusy: Bool {
        processing || isRecording || stage == .recording
            || stage == .transcribing || stage == .correcting
    }

    func toggle() { recorder.isRecording || isRecording ? stop() : start() }

    func start() {
        clearRateLimitCountdown()
        guard !processing, !recorder.isRecording, !isRecording else { return }
        sessionGeneration &+= 1
        FocusMemory.capture()

        // Show HUD immediately — engine.start() must not gate the Fn-up classifier.
        isRecording = true
        status = "Listening…"
        stage = .recording
        FeedbackSound.playStart()

        recorder.startRecording { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                if !ok {
                    self.isRecording = false
                    self.status = "❌ Microphone unavailable"
                    self.stage = .error("Microphone unavailable")
                }
            }
        }
    }

    /// Abort recording or in-flight STT/correction without pasting (hands-free ✕ / Esc).
    func cancelRecording() {
        clearRateLimitCountdown()
        sessionGeneration &+= 1
        sendEnterAfterPaste = false
        cloud.cancel()
        correction.cancel()
        HotkeyManager.shared.endHandsFreeSession()
        HotkeyManager.shared.setInFlightEscArmed(false)

        let wasRecording = recorder.isRecording || isRecording || stage == .recording
        if recorder.isRecording {
            recorder.stopRecording(publishFile: false)
        }
        isRecording = false
        processing = false
        handsFreeUI = false
        status = "Cancelled"
        stage = .idle
        if wasRecording {
            FeedbackSound.playStop()
        }
    }

    func stop(sendEnterAfterPaste: Bool = false, recaptureFocus: Bool = true) {
        guard recorder.isRecording || isRecording || stage == .recording else { return }
        // Default: remember caret app at stop. Enter path passes recaptureFocus: false
        // because HotkeyManager already captured the instant Enter was pressed.
        if recaptureFocus {
            FocusMemory.capture()
        }
        self.sendEnterAfterPaste = sendEnterAfterPaste
        // Batch and live: lock out a new start until this generation pastes or fails.
        processing = true
        HotkeyManager.shared.setInFlightEscArmed(true)
        HotkeyManager.shared.endHandsFreeSession()
        handsFreeUI = false
        FeedbackSound.playStop()
        isRecording = false
        status = "⏳ Processing…"
        stage = .transcribing

        recorder.stopRecording(publishFile: true)
    }

    private func handleAudio(_ url: URL) {
        let gen = sessionGeneration
        processing = true
        let lang = language

        DispatchQueue.main.async {
            guard self.sessionGeneration == gen else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            self.status = self.useCloudSTT ? "☁️ Transcribing…" : "📝 Transcribing…"
            self.stage = .transcribing
        }

        if useCloudSTT {
            cloud.transcribe(fileURL: url, language: lang) { [weak self] result in
                try? FileManager.default.removeItem(at: url)
                guard let self, self.sessionGeneration == gen else { return }
                self.afterSTT(result, generation: gen)
            }
        } else {
            whisper.language = lang
            whisper.transcribe(fileURL: url) { [weak self] result in
                guard let self, self.sessionGeneration == gen else { return }
                if let result {
                    self.afterSTT(.success(result), generation: gen)
                } else {
                    self.afterSTT(.failure(.emptyResponse), generation: gen)
                }
            }
        }
    }

    private func afterSTT(_ result: Result<String, DictationAPIError>, generation: UInt64) {
        guard sessionGeneration == generation else { return }
        let lang = language
        switch result {
        case .failure(let err):
            failOnMain(err, generation: generation)
        case .success(let raw):
            let text = stripSoundAnnotations(raw)
            let useful = text.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\t", with: "")
            guard !useful.isEmpty else {
                failOnMain(.emptyResponse, generation: generation)
                return
            }
            if useCorrection {
                DispatchQueue.main.async {
                    guard self.sessionGeneration == generation else { return }
                    self.status = "✨ AI correction…"
                    self.stage = .correcting
                }
                correction.correct(
                    text: text,
                    language: lang,
                    backtrack: UserDefaults.standard.bool(forKey: Self.backtrackKey)
                ) { [weak self] corr in
                    guard let self, self.sessionGeneration == generation else { return }
                    switch corr {
                    case .success(let cleaned):
                        self.finishOnMain(cleaned, generation: generation)
                    case .failure(let err):
                        // Never drop a good transcript on correction 429 / other LLM failure.
                        if case .rateLimited = err {
                            print("⚠️ Correction rate-limited; pasting raw transcript")
                        } else if case .http(let status, _, _) = err, status == 429 {
                            print("⚠️ Correction 429; pasting raw transcript")
                        } else {
                            print("⚠️ Correction failed (\(err.detailMessage)); pasting raw transcript")
                        }
                        self.finishOnMain(text, generation: generation, correctionSkipped: true)
                    }
                }
            } else {
                finishOnMain(text, generation: generation)
            }
        }
    }

    private func finishOnMain(_ text: String, generation: UInt64, correctionSkipped: Bool = false) {
        DispatchQueue.main.async {
            guard self.sessionGeneration == generation else { return }
            self.clearRateLimitCountdown()
            // LLM already handled spoken commands when correction ran.
            // Local rules are only the fallback when Correction is off or failed.
            var final = CorrectionDictionary.shared.apply(to: text)
            if correctionSkipped || !self.useCorrection {
                final = SpokenCommands.apply(final)
            }
            let wantEnter = self.sendEnterAfterPaste
            self.sendEnterAfterPaste = false

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                guard let self, self.sessionGeneration == generation, self.processing else { return }
                self.processing = false
                HotkeyManager.shared.setInFlightEscArmed(false)
            }

            Paster.paste(final) { [weak self] pasted in
                guard let self, self.sessionGeneration == generation else { return }
                self.processing = false
                HotkeyManager.shared.setInFlightEscArmed(false)

                switch pasted {
                case .inserted:
                    if correctionSkipped {
                        self.status = wantEnter ? "✅ Pasted + Enter (correction skipped)" : "✅ Pasted (correction skipped)"
                    } else {
                        self.status = wantEnter ? "✅ Pasted + Enter" : "✅ Pasted"
                    }
                    self.stage = .done("")
                    if wantEnter {
                        Paster.simulateReturnWhenFocused()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (wantEnter ? 0.7 : 0.12)) { [weak self] in
                        if case .done = self?.stage { self?.stage = .idle }
                    }
                case .copiedOnly:
                    self.status = "Copied — press ⌘V to paste"
                    self.stage = .copied
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                        if case .copied = self?.stage { self?.stage = .idle }
                    }
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                DictionaryLearner.watchAfterPaste(final)
            }
        }
    }

    private func failOnMain(_ err: DictationAPIError, generation: UInt64) {
        DispatchQueue.main.async {
            guard self.sessionGeneration == generation else { return }
            self.sendEnterAfterPaste = false
            self.processing = false
            HotkeyManager.shared.setInFlightEscArmed(false)
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
            rateLimitTimer?.invalidate()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                guard let self = self, self.statusItemToken == token else {
                    timer.invalidate(); return
                }
                left -= 1
                if left <= 0 {
                    timer.invalidate()
                    self.rateLimitTimer = nil
                    if self.isRecording || self.processing || self.recorder.isRecording {
                        return
                    }
                    switch self.stage {
                    case .recording, .transcribing, .correcting:
                        return
                    default:
                        self.status = "Ready — try again"
                        self.stage = .idle
                    }
                    return
                }
                if self.isRecording || self.processing || self.recorder.isRecording {
                    return
                }
                switch self.stage {
                case .recording, .transcribing, .correcting:
                    return
                default:
                    self.stage = .error("Rate limit — wait ~\(left)s")
                    self.status = "Rate limit — please wait \(left)s, then dictate again"
                }
            }
            rateLimitTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }

        let hold = err.displaySeconds
        let msg = err.pillMessage
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self = self else { return }
            if case .error(let m) = self.stage, m == msg {
                if self.isRecording || self.processing { return }
                self.stage = .idle
            }
        }
    }

    private func clearRateLimitCountdown() {
        statusItemToken = nil
        rateLimitTimer?.invalidate()
        rateLimitTimer = nil
    }

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
        // Whisper often invents YouTube/Amara credit lines on silence or short clips
        result = Self.stripWhisperHallucinations(result)
        result = result
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([,.!?])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// Known Whisper training-data watermarks (not real speech).
    private static func stripWhisperHallucinations(_ text: String) -> String {
        let watermarks = [
            #"(?i)\bsubtitles?\s+by\s+the\s+amara\.org\s+community\b"#,
            #"(?i)\bsubtitles?\s+by\s+amara\.org\b"#,
            #"(?i)\btranscribed\s+by\s+https?://\S+"#,
            #"(?i)\bthank(s| you)\s+for\s+watching\.?\b"#,
            #"(?i)\bplease\s+subscribe\s+(to\s+)?(my|the)\s+channel\.?\b"#,
            #"(?i)\bmbc\s+news\b"#,  // occasional Korean news hallucination
        ]
        var result = text
        for p in watermarks {
            result = result.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        return result
    }
}
