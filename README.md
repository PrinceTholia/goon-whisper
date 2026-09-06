# Goon Whisper

macOS menu-bar dictation (fork of Whisper / MyWhisperFlow) using **Google Gemini** instead of Groq.

**Status (2026-09-06):** Verified working on macOS — Fn → `gemini-3.5-transcribe` (SMART) → paste. After each ad-hoc rebuild, re-grant Accessibility + Automation if paste fails (text still lands on clipboard).

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

## Repo

Private GitHub repo: https://github.com/PrinceTholia/goon-whisper  
Created with `gh repo create goon-whisper --private --source=. --remote=origin --push` from this folder (Gemini fork of MyWhisperFlow). MyWhisperFlow / Groq stays the fallback line.

## Fallback

MyWhisperFlow (`PrinceTholia/my-whisper-flow`) remains the Groq “main” version. This repo is the Gemini experiment.
