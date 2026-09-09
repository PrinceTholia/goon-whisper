# Goon Whisper

macOS menu-bar dictation app — hold **Fn**, speak, text pastes into the focused app.

Supports **Groq** (Whisper) and **Google Gemini**. Groq is the recommended free-tier path.

**Requirements:** macOS 13+, [Xcode Command Line Tools](https://developer.apple.com/xcode/) (`xcode-select --install`).

---

## Quick start (Groq)

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
| **Accessibility** | Auto-paste into other apps |
| **Automation → System Events** | Backup paste path (Terminal, etc.) |

**Path:** System Settings → Privacy & Security → Microphone / Accessibility / Automation.

If paste fails after a rebuild: remove Whisper from Accessibility, add `/Applications/Whisper.app` again, turn it **ON**. With the stable signing identity, you usually only need this once.

Also turn **off** macOS built-in Dictation’s Fn shortcut if it fights Whisper:  
Keyboard → Dictation → Shortcut → **Off**.

### 4. Add your Groq key in the app

1. Click the mic icon in the menu bar → **Settings…**  
2. Choose **Groq**  
3. Paste your API key → **Save** → **Test**  
4. Leave **AI Correction** on if you want Groq LLM cleanup after Whisper  

Keys are stored locally under `~/.whisperapp/` (not in the repo).

### 5. Use it

| Action | Result |
|--------|--------|
| **Hold Fn** | Record → release → transcribe → paste |
| **Tap Fn** | Hands-free continuous; **Esc** / **✕** cancel, **■** / **Enter** / tap Fn again to send |

Dictionary (menu → Dictionary…): hard fixes `wrong -> right`, or sound-alikes  
`~ think | thing | theme` (AI picks by context when Correction is on).

---

## Gemini (optional)

1. Key: [aistudio.google.com/apikey](https://aistudio.google.com/apikey)  
2. Settings → **Google Gemini** → paste key → Save  
3. Same Fn workflow  

Or: `export GEMINI_API_KEY='…'` then `./scripts/install_gemini_key.sh`

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
| “No API key” | Settings → pick Groq or Gemini → paste key → Save |
| Double paste in browser | Update to latest `main` (paste paths are exclusive) |
| Accessibility resets every rebuild | Sign with **Goon Whisper Dev** via `./make_app.sh` (not ad-hoc `-`) |

---

## Repo

https://github.com/PrinceTholia/goon-whisper  

Fork lineage / notes: `FORK-NOTES.md`. Agent context: `AGENTS.md`.
