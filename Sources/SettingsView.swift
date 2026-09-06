import SwiftUI

struct SettingsView: View {
    // Hotkey
    @State private var hotkeyConfig = HotkeyManager.shared.currentConfig
    @State private var isRecordingHotkey = false

    // Gemini — single key for STT + AI correction
    @State private var geminiKey = ""
    @State private var geminiMsg = ""

    // Features
    @State private var backtrackOn = false
    @State private var soundOn = true
    @State private var autoDictOn = true

    private var sttProvider: STTProvider { STTRegistry.provider(id: "gemini") }
    private var llmProvider: LLMProvider { LLMRegistry.provider(id: "gemini") }

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
                    Text("2. Privacy → Accessibility → remove old Whisper → add /Applications/Whisper.app → ON → use Restart Whisper (menu).")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("3. Privacy → Automation → Whisper → System Events ON (needed for auto-paste).")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("Whisper no longer skips paste when caret detection fails (that forced manual ⌘V in Cursor/Chrome).")
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

                    Text("After paste, if you fix a word in the text field, that correction is learned automatically (needs Accessibility).")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Divider()

                // ── Gemini (STT + AI correction) ──
                VStack(alignment: .leading, spacing: 8) {
                    Label("Google Gemini API Key", systemImage: "key.fill")
                        .font(.subheadline).bold()

                    Text("Used for transcription (Live + SMART `gemini-3.5-transcribe`) · AI Correction is optional (menu) since SMART already cleans speech")
                        .font(.caption).foregroundColor(.secondary)

                    SecureField("AIza…", text: $geminiKey)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Save") { saveKey() }.buttonStyle(.borderedProminent)
                        Button("Test") { testKey() }
                        if !geminiMsg.isEmpty { Text(geminiMsg).font(.caption) }
                    }

                    Text("Get a free key at aistudio.google.com/apikey · Or set GEMINI_API_KEY in ~/.zshrc")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Text("💡 Fix words the STT keeps mis-transcribing via menu → Dictionary…")
                    .font(.caption2).foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(width: 460, height: 520)
        .onAppear {
            loadKey()
            backtrackOn = UserDefaults.standard.bool(forKey: "backtrackEnabled")
            soundOn = FeedbackSound.isEnabled
            autoDictOn = DictionaryLearner.isEnabled
        }
    }

    // MARK: Gemini key (shared by STT + LLM)
    private func loadKey() {
        geminiKey = STTSettings.savedKeyFile(for: sttProvider)
        if geminiKey.isEmpty {
            geminiKey = (try? String(contentsOfFile: KeyStore.dir + "/llm_gemini.key", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private func applyKey() {
        STTSettings.providerID = "gemini"
        LLMSettings.providerID = "gemini"
        let t = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            STTSettings.saveKey(t, for: sttProvider)
            LLMSettings.saveKey(t, for: llmProvider)
        }
    }

    private func saveKey() {
        applyKey()
        geminiMsg = "✅ Saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { geminiMsg = "" }
    }

    private func testKey() {
        applyKey()
        guard let key = STTSettings.key(for: sttProvider) else {
            geminiMsg = "⚠️ Enter API key first"; return
        }

        geminiMsg = "⏳ Testing…"
        guard var comps = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models") else { return }
        comps.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                geminiMsg = code == 200 ? "✅ Key is valid" : "❌ Invalid key (code \(code))"
            }
        }.resume()
    }
}
