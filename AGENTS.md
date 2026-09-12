<!-- bmad:context -->
<!-- Verified 2026-08-20 against 9a055969ffa79ad091eaa1aa168be77dc36ccf3d. Managed by bmad-project-context; edits inside this block are replaced on refresh. Keep anything you want preserved outside the markers. -->

## Whisper (this fork)

macOS menu-bar dictation: hold Fn, record locally, Groq Whisper STT (`whisper-large-v3`), optional Groq LLM cleanup, paste into the focused app. Swift SPM target `WhisperApp`, bundle ID `com.game.whisperapp`. Upstream notes live in `CLAUDE.md`; do not treat `README.md` clone URLs as this fork.

## Policy

- Never rename the SPM target `WhisperApp`, bundle ID `com.game.whisperapp`, or the GitHub repo identity — TCC and history bind to those. Bundle folder `Whisper.app` may stay.
- Never merge `feat/apple-live-dictation` — user rolled it back; Apple live caret insert did not work. Keep batch paste until a new proven path exists.
- Never push this fork to `upstream` (`Gamezxz/WhisperApp`) or to MyWhisperFlow remotes unless the user explicitly asks. Ship to `origin` (`PrinceTholia/goon-whisper`).
- Never put API keys in git. Keys live in `~/.whisperapp/` or `GROQ_API_KEY`. Provider is Groq only (console.groq.com). Do not add Gemini (or Gemini Live) back to the product path.

## Where things are

- Pipeline: `Sources/DictationController.swift` (record → STT → correction → paste)
- Paste: `Sources/Paster.swift` — WhatsApp is a special path; do not “simplify” it back to AX insert
- Hotkey / Fn vs macOS Dictation: `Sources/HotkeyManager.swift`, `Sources/SystemConflictGuard.swift`
- Groq STT: `Sources/CloudTranscriptionService.swift` (WAV multipart → `whisper-large-v3`)

## Running and verifying

- Dev loop is `./run.sh` (calls `./make_app.sh` then opens the bundle). After an ad-hoc rebuild, re-add `/Applications/Whisper.app` in Accessibility — signature change drops TCC.
- This fork has no public DMG; share `https://github.com/PrinceTholia/my-whisper-flow` and `./run.sh`, not the Gamezxz Releases page, unless they want stock 1.2.5.

## Conventions that differ from defaults

- Settings is Groq-only (API key + Test/Save). Correction is an explicit menu/Settings toggle — do not force-enable it when the Groq key is saved.
- Dictation is batch: WAV is local until stop, then one Groq Whisper upload. Tap-Fn is hands-free recording, not live captions in the caret.

## Known pitfalls

- Perceived slowness is often the LLM correction pass. If the pill sits on “AI correction…”, do not rewrite STT or the recorder first; leave Backtrack off unless the user wants “sorry, I meant…” stripped.
- Live words appearing at the caret while speaking are macOS Dictation (Fn twice), not this app. `SystemConflictGuard` turns that shortcut off — do not re-enable it to “get live text.”
- WhatsApp’s composer reports AX insert success and writes nothing, which used to skip ⌘V. Keep `pasteIntoWhatsApp` as delayed ⌘V only; do not `activateIgnoringOtherApps` (steals the chat box).
- Never open System Settings during paste — focus steal, ⌘V lands nowhere.
- The app does not auto-open the Groq keys page; tell people to visit https://console.groq.com/keys then paste into Settings.

<!-- /bmad:context -->

## Agent habit

Always discuss trade-offs before changing behavior (lag, accuracy, battery, extra APIs). See `.cursor/rules/discuss-tradeoffs.mdc`.
