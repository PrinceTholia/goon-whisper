# Goon Whisper

macOS menu-bar dictation app — speak with **Fn**, cleaned text pastes into the focused app.

**Groq-only:** speech is transcribed with Groq Whisper (`whisper-large-v3`). Optional Groq LLM correction is a toggle (menu / Settings), not required.

**Requirements:** macOS 13+, [Xcode Command Line Tools](https://developer.apple.com/xcode/) (`xcode-select --install`).

---

## Features (how it works)

Use this section when setting the app up for someone or explaining controls to an LLM.

### Recording controls

There are **two ways** to dictate. Both use the **Fn** key.

#### 1. Hold Fn (short phrases)

1. Press and **keep holding** Fn.
2. Speak.
3. **Let go** of Fn when you’re done.

Whisper turns your speech into text and pastes it where your cursor is. That’s it.

#### 2. Tap Fn (longer / hands-free)

1. **Tap** Fn once (press and release quickly — don’t hold).
2. Keep talking as long as you want. A small black pill appears on screen.
3. When you’re finished, pick **one** of these:

| What you want | What to do |
|---------------|------------|
| Paste the text | Press **Fn** again, **or** click **■** on the pill |
| Paste the text **and** press Enter (e.g. send a chat message) | Press **Enter** |
| Throw it away — don’t paste anything | Press **Esc**, **or** click **✕** on the pill |

**Esc / ✕** means cancel: the recording is deleted. Nothing is transcribed. Nothing is pasted. Esc during “Cleaning up…” also aborts the in-flight transcript.

#### How Whisper tells hold vs tap apart

- Finger down for less than **0.45 seconds** → continuous (mode 2).
- Finger down for **0.45 seconds or longer** → hold-to-talk (mode 1: pastes when you release).
- Hold vs tap is measured from the key event timestamps (not after the microphone engine starts).

#### Optional setting

In Settings, you can turn **Hold to talk** off. Then Fn only toggles recording on/off — no separate hands-free mode.

### Floating status pill (HUD)

- Black pill near the **bottom center of the display under the cursor** (multi-monitor aware).
- Hold mode: live waveform while recording.
- Hands-free: wider pill with **✕** (cancel) \| waveform \| **■** (stop & paste).
- After stop: shows **Cleaning up…** while transcribing / polishing, then vanishes when text is pasted.
- If paste can’t reach a caret: clipboard copy + short **Copied — ⌘V** hint.

### Speech → text

- **Provider:** Groq Whisper (`whisper-large-v3`), batch WAV upload on stop. Settings only needs a Groq API key (Save / Test).
- Optional **AI Correction** (menu or Settings): Groq LLM polish for fillers / mishears. Off keeps the raw transcript. Default follows whatever you already had saved.
- **Language** submenu: Auto-detect or a fixed language (en, th, zh, ja, ko, …).
- **Backtrack** (optional): drops “sorry, I meant…” style restarts when Correction is on.
- Strips common STT junk (subtitle watermarks, “thanks for watching”, bracketed sound tags, etc.) before paste.

### Paste behavior

- Remembers the focused app the moment you **stop** (second **Fn**, **Enter**, or **■**).
- After transcription, brings that app back and pastes there — even if you switched windows while waiting.
- Same rule for **Enter**: paste + simulated Enter go to the app that was focused when you pressed Enter. Enter waits until that app is frontmost; it is not claimed if paste only copied to the clipboard.
- Uses one paste strategy at a time (avoids double-paste in browsers / Electron).
- If Accessibility can’t paste: text stays on the clipboard for ⌘V.

### Dictionary

- Menu → **Dictionary…** (file: `~/.whisperapp/dictionary.txt`).
- Hard fixes: `wrong -> right`
- Sound-alikes (when Correction is on): `~ think | thing | theme` — AI picks by context.
- Optional **Auto-add edits to Dictionary**: learns from quick post-paste edits.

### Menu bar

Mic icon → Start/Stop, Settings, Dictionary, STT Cloud / Correction / Backtrack / Language toggles, Fix Accessibility, Test Auto-Paste, Restart, Quit.

---

## Quick start

### 1. Get a Groq API key

1. Open [console.groq.com](https://console.groq.com/) and sign in  
2. Create an API key  
3. Keep it handy for Settings (below)

### 2. Clone & build

```bash
git clone https://github.com/PrinceTholia/goon-whisper.git
cd goon-whisper
./make_app.sh
```

That builds and signs `Whisper.app` (prefers a stable local **Goon Whisper Dev** identity so Accessibility survives rebuilds; falls back to ad-hoc if needed).

Install to Applications (optional but recommended):

```bash
rm -rf /Applications/Whisper.app
cp -R Whisper.app /Applications/Whisper.app
open /Applications/Whisper.app
```

Or run from the repo: `open Whisper.app`

### 3. macOS permissions (one-time)

Grant these for **Whisper** / `/Applications/Whisper.app`:

| Permission | Why |
|------------|-----|
| **Microphone** | Record your voice |
| **Accessibility** | Auto-paste into other apps; hands-free Enter / Esc |
| **Automation → System Events** | Backup paste path (Terminal, etc.) |

**Path:** System Settings → Privacy & Security → Microphone / Accessibility / Automation.

If paste fails after a rebuild: remove Whisper from Accessibility, add `/Applications/Whisper.app` again, turn it **ON**. With the stable signing identity, you usually only need this once.

Also turn **off** macOS built-in Dictation’s Fn shortcut if it fights Whisper:  
Keyboard → Dictation → Shortcut → **Off**.

### 4. Add your Groq key in the app

1. Click the mic icon in the menu bar → **Settings…**  
2. Paste your Groq API key → **Save** → **Test**  
3. Turn **AI Correction** on in Settings or the menu if you want Groq LLM cleanup after Whisper  

Keys are stored locally under `~/.whisperapp/` (not in the repo). You can also set `GROQ_API_KEY` in `~/.zshrc`.

### 5. Use it

- **Hold Fn**, speak, release → text pastes.
- **Tap Fn**, speak as long as you want → **Enter** to paste & send, **Fn** or **■** to paste only, **Esc** or **✕** to cancel.

Full detail: **Features** above.

---

## Dev commands

```bash
./make_app.sh          # release Whisper.app + codesign
./run.sh               # quick run helper (if present)
swift build -c release # binary only → .build/release/WhisperApp
```

Signing helper (one-time Keychain ACL so rebuilds don’t ask for password every time):

```bash
./scripts/allow_codesign_access.sh
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| No paste / text only on clipboard | Re-add app in **Accessibility**; enable **Automation → System Events** |
| Fn opens system Dictation / pauses music | Dictation shortcut → **Off** |
| “No API key” | Settings → paste Groq key → Save |
| Double paste in browser | Update to latest `main` (paste paths are exclusive) |
| Accessibility resets every rebuild | Sign with **Goon Whisper Dev** via `./make_app.sh` (not ad-hoc `-`) |
| Esc / Enter ignored in other apps while hands-free | Grant **Accessibility** to `/Applications/Whisper.app` |

---

## Repo

https://github.com/PrinceTholia/goon-whisper  

Fork lineage / notes: `FORK-NOTES.md`. Agent context: `AGENTS.md`.
