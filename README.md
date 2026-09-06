# Goon Whisper

macOS menu-bar dictation (fork of Whisper / MyWhisperFlow) using **Google Gemini** instead of Groq.

- Hold **Fn** → speak → `gemini-3.5-transcribe` → optional Gemini cleanup → paste
- Bundle ID stays `com.game.whisperapp` so Accessibility grants still apply when testing

## Setup

1. Get a key: [aistudio.google.com/apikey](https://aistudio.google.com/apikey)
2. Build & run:

```bash
./run.sh
```

3. Menu bar mic → **Settings…** → paste **Google Gemini API Key** → Save → Test

Or:

```bash
export GEMINI_API_KEY='AIza…'
./scripts/install_gemini_key.sh
```

## Dev

```bash
./make_app.sh          # build Whisper.app
open Whisper.app
# After ad-hoc rebuild: re-add /Applications/Whisper.app in Accessibility if paste breaks
```

Quality spike (optional): `tools/quality-spike/`

## Fallback

MyWhisperFlow (`PrinceTholia/my-whisper-flow`) remains the Groq “main” version. This repo is the Gemini experiment.
