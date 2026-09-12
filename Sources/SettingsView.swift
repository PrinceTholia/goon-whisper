import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: DictationController

    // Hotkey
    @State private var hotkeyConfig = HotkeyManager.shared.currentConfig
    @State private var isRecordingHotkey = false

    @State private var groqKey = ""
    @State private var keyMsg = ""

    // Features
    @State private var correctionOn = false
    @State private var backtrackOn = false
    @State private var soundOn = true
    @State private var autoDictOn = true

    private var groqSTT: STTProvider { STTRegistry.provider(id: "groq") }
    private var groqLLM: LLMProvider { LLMRegistry.provider(id: "groq") }

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

                    Text("Hold Fn to talk · Tap Fn for hands-free (Esc cancels · Enter sends)")
                        .font(.caption2).foregroundColor(.secondary)

                    Text("Whisper turns off macOS “Press Fn twice for Dictation” so it doesn’t steal live text or pause music. If it comes back: System Settings → Keyboard → Dictation → Shortcut → Off.")
                        .font(.caption2).foregroundColor(.secondary)

                    Toggle("Hold to talk (press & hold to record, release to stop)", isOn: $hotkeyConfig.isHoldMode)
                        .font(.caption)
                        .onChange(of: hotkeyConfig.isHoldMode) { _ in
                            HotkeyManager.shared.updateConfig(hotkeyConfig)
                        }

                    Picker("Language", selection: $controller.language) {
                        Text(Languages.auto.name).tag(Languages.auto.code)
                        ForEach(Languages.all, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .font(.caption)

                    Text("Say “next line” for a newline, “comma” for ,")
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

                    Toggle("AI Correction (Groq LLM polish after Whisper)", isOn: $correctionOn)
                        .font(.caption)
                        .onChange(of: correctionOn) { v in
                            UserDefaults.standard.set(v, forKey: "useCorrection")
                        }

                    Text("Optional. When on, Groq Llama cleans fillers / mishears after Whisper. Off keeps the raw transcript.")
                        .font(.caption2).foregroundColor(.secondary)

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

                // ── Groq key ──
                VStack(alignment: .leading, spacing: 8) {
                    Label("Groq API key", systemImage: "key")
                        .font(.subheadline).bold()

                    Text("STT: whisper-large-v3 · optional AI Correction: \(groqLLM.defaultModel). Paste your Groq key below.")
                        .font(.caption).foregroundColor(.secondary)

                    SecureField("gsk_…", text: $groqKey)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Save") { saveKey() }.buttonStyle(.borderedProminent)
                        Button("Test") { testKey() }
                        if !keyMsg.isEmpty { Text(keyMsg).font(.caption) }
                    }

                    Text("Get a free key at console.groq.com · Or set GROQ_API_KEY in ~/.zshrc")
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
            loadKey()
            correctionOn = UserDefaults.standard.bool(forKey: "useCorrection")
            backtrackOn = UserDefaults.standard.bool(forKey: "backtrackEnabled")
            soundOn = FeedbackSound.isEnabled
            autoDictOn = DictionaryLearner.isEnabled
        }
    }

    // MARK: - Groq key

    private func loadKey() {
        STTSettings.providerID = "groq"
        LLMSettings.providerID = "groq"
        groqKey = loadSavedKey()
    }

    private func loadSavedKey() -> String {
        var k = STTSettings.savedKeyFile(for: groqSTT)
        if k.isEmpty {
            k = (try? String(contentsOfFile: KeyStore.dir + "/llm_groq.key", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return k
    }

    private func applyKey() {
        STTSettings.providerID = "groq"
        LLMSettings.providerID = "groq"
        let groq = STTRegistry.provider(id: "groq")
        let saved = STTSettings.savedModel(for: groq)
        if saved.isEmpty || saved.contains("turbo") {
            STTSettings.saveModel("whisper-large-v3", for: groq)
        }
        let t = groqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            STTSettings.saveKey(t, for: groqSTT)
            LLMSettings.saveKey(t, for: groqLLM)
        }
    }

    private func saveKey() {
        applyKey()
        keyMsg = "✅ Saved Groq"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { keyMsg = "" }
    }

    private func testKey() {
        applyKey()
        guard let key = STTSettings.key(for: groqSTT) else {
            keyMsg = "⚠️ Enter API key first"; return
        }
        keyMsg = "⏳ Testing…"

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
