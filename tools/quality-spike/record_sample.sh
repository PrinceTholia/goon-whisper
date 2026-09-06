#!/usr/bin/env bash
# Record a short mic clip at 16 kHz mono WAV (same shape as MyWhisperFlow).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/samples/dictation-$(date +%Y%m%d-%H%M%S).wav}"
SECS="${2:-20}"

mkdir -p "$(dirname "$OUT")"
echo "Recording ${SECS}s → $OUT"
echo "Speak like you would dictate (names, filler words, a tech term)…"
echo "Starting in 1s…"
sleep 1

# Audio-only: empty video device + mic index (0 = MacBook Air Microphone here).
# List: ffmpeg -f avfoundation -list_devices true -i ""
MIC_INDEX="${MIC_INDEX:-0}"
ffmpeg -y -hide_banner -loglevel error \
  -f avfoundation -i ":${MIC_INDEX}" \
  -t "$SECS" -ac 1 -ar 16000 -c:a pcm_s16le \
  "$OUT"

echo "Saved: $OUT ($(du -h "$OUT" | awk '{print $1}'))"
echo "Play:  afplay \"$OUT\""
echo "Transcribe:  ./scripts/test_gemini_stt.py \"$OUT\""
