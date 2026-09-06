import SwiftUI

private enum CloudProviderChoice: String, CaseIterable, Identifiable {
    case gemini
    case groq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        }
    }

    var sttID: String { rawValue }
    var llmID: String { rawValue }
}

struct SettingsView: View {
    // Hotkey
    @State private var hotkeyConfig = HotkeyManager.shared.currentConfig
    @State private var isRecordingHotkey = false

    // Provider + keys (STT + correction share one key per provider)
    @State private var provider: CloudProviderChoice = .gemini
    @State private var geminiKey = ""
    @State private var groqKey = ""
    @State private var keyMsg = ""

    // Features
    @State private var backtrackOn = false
    @State private var soundOn = true
    @State private var autoDictOn = true

    private var activeSTT: STTProvider { STTRegistry.provider(id: provider.sttID) }
    private var activeLLM: LLMProvider { LLMRegistry.provider(id: provider.llmID) }

    private var activeKeyBinding: Binding<String> {
        switch provider {
        case .gemini: return $geminiKey
        case .groq: return $groqKey
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Whisper Settings")
                    .font(.title3).bold()

                // ── Hotkey ──
                VStack(alignment: .leading, spacing: 8) {
                    Label("Global Hotkey", systemImage: "keyboard")
                        .font(.subheadline).bold()

                    HStack(spacing: 12) {
                        Text("Shortcut:").font(.caption)
                        HotkeyRecorderView(hotkey: $hotkeyConfig, isRecording: $isRecordingHotkey)
                            .frame(width: 180, height: 30)
                        Button(isRecordingHotkey ? "Listening…" : "Change") {
                            isRecordingHotkey.toggle()
                        }
                        .disabled(isRecordingHotkey)
                        Button("Reset") {
                            hotkeyConfig = .default
                            HotkeyManager.shared.updateConfig(hotkeyConfig)
                        }
                    }

                    Text("Hold Fn to talk · Double-tap Fn for hands-free (tap Fn again to stop)")
                        .font(.caption2).foregroundColor(.secondary)

                    Text("Whisper turns off macOS “Press Fn twice for Dictation” so it doesn’t steal live text or pause music. If it comes back: System Settings → Keyboard → Dictation → Shortcut → Off.")
                        .font(.caption2).foregroundColor(.secondary)

                    Toggle("Hold to talk (press & hold to record, release to stop)", isOn: $hotkeyConfig.isHoldMode)
                        .font(.caption)
                        .onChange(of: hotkeyConfig.isHoldMode) { _ in
                            HotkeyManager.shared.updateConfig(hotkeyConfig)
                        }

                    Text("When hold is on: hold = push-to-talk, double-tap = hands-free. When off: double-tap starts, tap stops.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .onChange(of: hotkeyConfig.keyCode) { _ in HotkeyManager.shared.updateConfig(hotkeyConfig) }
                .onChange(of: hotkeyConfig.modifiers) { _ in HotkeyManager.shared.updateConfig(hotkeyConfig) }

                Divider()

                // ── Troubleshooting ──
                VStack(alignment: .leading, spacing: 8) {
                    Label("If paste / Fn acts weird", systemImage: "wrench.and.screwdriver")
                        .font(.subheadline).bold()

                    Text("1. Keyboard → Dictation → Shortcut → Off (macOS Dictation steals Fn twice, pauses music, shows fake live text).")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("2. Privacy → Accessibility → add /Applications/Whisper.app → ON (only needed again if the signing identity changes; ad-hoc rebuilds always reset it).")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("3. Privacy → Automation → Whisper → System Events ON (needed for auto-paste).")
                        .font(.caption2).foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Button("Fix Dictation conflict") {
                            _ = SystemConflictGuard.disableSystemFnDictationIfNeeded(showAlertIfChanged: true)
                            SystemConflictGuard.openDictationSettings()
                        }
                        Button("Open Accessibility") { Paster.openAccessibilitySettings() }
                        Button("Open Automation") { Paster.openAutomationSettings() }
                    }
                    .font(.caption)
                }

                Divider()

                // ── Cleanup / feedback ──
                VStack(alignment: .leading, spacing: 8) {
                    Label("Dictation polish", systemImage: "wand.and.stars")
                        .font(.subheadline).bold()

                    Toggle("Backtrack (drop “sorry / actually…” self-corrections)", isOn: $backtrackOn)
                        .font(.caption)
                        .onChange(of: backtrackOn) { v in
                            UserDefaults.standard.set(v, forKey: "backtrackEnabled")
                        }

                    Text("Off by default. When on: “I want X, sorry, I want Y” pastes as “I want Y”. Needs AI Correction.")
                        .font(.caption2).foregroundColor(.secondary)

                    Toggle("Soft sound when recording starts/stops", isOn: $soundOn)
                        .font(.caption)
                        .onChange(of: soundOn) { v in FeedbackSound.isEnabled = v }

                    Text("Custom soft pips (not Wispr’s sounds). Toggle off if you prefer silence.")
                        .font(.caption2).foregroundColor(.secondary)

                    Toggle("Auto-add edits to Dictionary", isOn: $autoDictOn)
                        .font(.caption)
                        .onChange(of: autoDictOn) { v in DictionaryLearner.isEnabled = v }

                    Text("Off by default. When on, post-paste edits can auto-add rules — leave off unless you trust it (bad rules rewrite good transcripts).")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Divider()

                // ── Provider switch ──
                VStack(alignment: .leading, spacing: 8) {
                    Label("Cloud provider", systemImage: "cloud")
                        .font(.subheadline).bold()

                    Picker("Provider", selection: $provider) {
                        ForEach(CloudProviderChoice.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: provider) { _ in
                        applyProviderSelection()
                        keyMsg = ""
                    }

                    Text(providerBlurb)
                        .font(.caption).foregroundColor(.secondary)

                    SecureField(keyPlaceholder, text: activeKeyBinding)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Save") { saveKey() }.buttonStyle(.borderedProminent)
                        Button("Test") { testKey() }
                        if !keyMsg.isEmpty { Text(keyMsg).font(.caption) }
                    }

                    Text(keyHelp)
                        .font(.caption2).foregroundColor(.secondary)
                }

                Text("💡 Fix words the STT keeps mis-transcribing via menu → Dictionary…")
                    .font(.caption2).foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(width: 480, height: 560)
        .onAppear {
            loadProviderAndKeys()
            backtrackOn = UserDefaults.standard.bool(forKey: "backtrackEnabled")
            soundOn = FeedbackSound.isEnabled
            autoDictOn = DictionaryLearner.isEnabled
        }
    }

    private var providerBlurb: String {
        switch provider {
        case .gemini:
            return "STT: \(activeSTT.defaultModel) (SMART) · optional AI Correction: \(activeLLM.defaultModel). Live streaming is Gemini-only (menu)."
        case .groq:
            return "STT: whisper-large-v3 (more accurate than turbo) · AI Correction on by default to fix mishears. Paste your Groq key below."
        }
    }

    private var keyPlaceholder: String {
        switch provider {
        case .gemini: return "AIza…"
        case .groq: return "gsk_…"
        }
    }

    private var keyHelp: String {
        switch provider {
        case .gemini:
            return "Get a free key at aistudio.google.com/apikey · Or set GEMINI_API_KEY in ~/.zshrc"
        case .groq:
            return "Get a free key at console.groq.com · Or set GROQ_API_KEY in ~/.zshrc"
        }
    }

    // MARK: - Provider + keys

    private func loadProviderAndKeys() {
        let id = STTSettings.providerID
        provider = (id == "groq") ? .groq : .gemini
        // Keep STT/LLM in sync with picker
        applyProviderSelection()

        geminiKey = loadSavedKey(sttID: "gemini", llmID: "gemini")
        groqKey = loadSavedKey(sttID: "groq", llmID: "groq")
    }

    private func loadSavedKey(sttID: String, llmID: String) -> String {
        let stt = STTRegistry.provider(id: sttID)
        var k = STTSettings.savedKeyFile(for: stt)
        if k.isEmpty {
            k = (try? String(contentsOfFile: KeyStore.dir + "/llm_\(llmID).key", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return k
    }

    private func applyProviderSelection() {
        STTSettings.providerID = provider.sttID
        LLMSettings.providerID = provider.llmID
        switch provider {
        case .groq:
            // Accuracy: full Whisper large-v3 + Llama cleanup (turbo hallucinates more)
            let groqSTT = STTRegistry.provider(id: "groq")
            let saved = STTSettings.savedModel(for: groqSTT)
            if saved.isEmpty || saved.contains("turbo") {
                STTSettings.saveModel("whisper-large-v3", for: groqSTT)
            }
            UserDefaults.standard.set(false, forKey: "useLiveSTT")
            UserDefaults.standard.set(true, forKey: "useCorrection")
        case .gemini:
            // SMART mode usually enough; leave correction as user left it
            break
        }
    }

    private func applyKey() {
        applyProviderSelection()
        let t = activeKeyBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            STTSettings.saveKey(t, for: activeSTT)
            LLMSettings.saveKey(t, for: activeLLM)
        }
    }

    private func saveKey() {
        applyKey()
        keyMsg = "✅ Saved \(provider.title)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { keyMsg = "" }
    }

    private func testKey() {
        applyKey()
        guard let key = STTSettings.key(for: activeSTT) else {
            keyMsg = "⚠️ Enter API key first"; return
        }
        keyMsg = "⏳ Testing…"

        switch provider {
        case .gemini:
            guard var comps = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models") else { return }
            comps.queryItems = [URLQueryItem(name: "key", value: key)]
            guard let url = comps.url else { return }
            var req = URLRequest(url: url)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async {
                    keyMsg = code == 200 ? "✅ Gemini key valid" : "❌ Invalid key (code \(code))"
                }
            }.resume()

        case .groq:
            guard let url = URL(string: "https://api.groq.com/openai/v1/models") else { return }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async {
                    keyMsg = code == 200 ? "✅ Groq key valid" : "❌ Invalid key (code \(code))"
                }
            }.resume()
        }
    }
}
