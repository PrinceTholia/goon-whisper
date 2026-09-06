#!/usr/bin/env python3
"""Quick quality spike: Gemini 3.5 Transcribe on a local audio file.

Usage:
  export GEMINI_API_KEY='…'   # from https://aistudio.google.com/apikey
  ./scripts/test_gemini_stt.py samples/your.wav
  ./scripts/test_gemini_stt.py samples/your.wav --mode smart
  ./scripts/test_gemini_stt.py samples/your.wav --mode verbatim --vocab WhisperApp Groq
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path


def load_dotenv(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k, v = k.strip(), v.strip().strip("'").strip('"')
        if k and k not in os.environ:
            os.environ[k] = v


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    load_dotenv(root / ".env")

    parser = argparse.ArgumentParser(description="Test Gemini 3.5 Transcribe quality")
    parser.add_argument("audio", type=Path, help="Path to wav/mp3/m4a/flac")
    parser.add_argument(
        "--mode",
        choices=("default", "smart", "verbatim"),
        default="default",
        help="default = model defaults; smart = cleaned dictation; verbatim = as spoken",
    )
    parser.add_argument(
        "--vocab",
        nargs="*",
        default=[],
        help="Optional custom vocabulary hints (names, product terms)",
    )
    parser.add_argument(
        "--model",
        default="gemini-3.5-transcribe",
        help="Model id (default: gemini-3.5-transcribe)",
    )
    args = parser.parse_args()

    audio = args.audio.expanduser().resolve()
    if not audio.is_file():
        print(f"File not found: {audio}", file=sys.stderr)
        return 1

    key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if not key:
        print(
            "No API key. Create one at https://aistudio.google.com/apikey\n"
            "Then:  export GEMINI_API_KEY='…'\n"
            "Or put GEMINI_API_KEY=… in goon-whisper/.env",
            file=sys.stderr,
        )
        return 1

    from google import genai
    from google.genai import types

    client = genai.Client(api_key=key)

    print(f"Uploading {audio.name} ({audio.stat().st_size} bytes)…")
    t0 = time.perf_counter()
    uploaded = client.files.upload(file=str(audio))
    print(f"  file uri ready in {time.perf_counter() - t0:.2f}s → {uploaded.uri}")

    config = None
    if args.mode != "default" or args.vocab:
        mode_cfg = None
        if args.mode == "smart":
            mode_cfg = types.AudioTranscriptionConfigMode.SMART
        elif args.mode == "verbatim":
            mode_cfg = types.AudioTranscriptionConfigMode.VERBATIM

        tx = types.AudioTranscriptionConfig(
            language_codes=[],
            custom_vocabulary=list(args.vocab) or None,
            mode=mode_cfg,
        )
        config = types.GenerateContentConfig(audio_transcription_config=tx)

    print(f"Transcribing with {args.model} (mode={args.mode})…")
    t1 = time.perf_counter()
    try:
        response = client.models.generate_content(
            model=args.model,
            contents=[uploaded],
            config=config,
        )
    except Exception as e:
        print(f"API error: {e}", file=sys.stderr)
        print(
            "\nTip: if mode/vocab config fails, retry with just:\n"
            f"  {sys.argv[0]} {audio}",
            file=sys.stderr,
        )
        return 2

    elapsed = time.perf_counter() - t1
    text = (response.text or "").strip()
    print(f"Done in {elapsed:.2f}s\n")
    print("─" * 60)
    print(text if text else "(empty transcript)")
    print("─" * 60)

    out = audio.with_suffix(audio.suffix + f".{args.mode}.txt")
    out.write_text(text + "\n", encoding="utf-8")
    print(f"Saved transcript → {out}")
    return 0 if text else 3


if __name__ == "__main__":
    raise SystemExit(main())
