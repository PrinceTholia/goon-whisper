#!/usr/bin/env bash
# Save GEMINI_API_KEY into ~/.whisperapp for Whisper (STT + LLM).
# Usage:
#   export GEMINI_API_KEY='AIza…'
#   ./scripts/install_gemini_key.sh
# Or:
#   ./scripts/install_gemini_key.sh 'AIza…'
set -euo pipefail

KEY="${1:-${GEMINI_API_KEY:-}}"
if [[ -z "$KEY" && -f "$(dirname "$0")/../.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$(dirname "$0")/../.env"; set +a
  KEY="${GEMINI_API_KEY:-}"
fi
# Also accept goon-whisper/.env next to MyWhisperFlow
if [[ -z "$KEY" && -f "$(dirname "$0")/../../goon-whisper/.env" ]]; then
  set -a; source "$(dirname "$0")/../../goon-whisper/.env"; set +a
  KEY="${GEMINI_API_KEY:-}"
fi

if [[ -z "$KEY" ]]; then
  echo "No key. Pass it as arg, export GEMINI_API_KEY, or put it in .env"
  exit 1
fi

DIR="$HOME/.whisperapp"
mkdir -p "$DIR"
chmod 700 "$DIR"
printf '%s' "$KEY" > "$DIR/stt_gemini.key"
printf '%s' "$KEY" > "$DIR/llm_gemini.key"
chmod 600 "$DIR/stt_gemini.key" "$DIR/llm_gemini.key"
echo "Saved Gemini key → ~/.whisperapp/stt_gemini.key + llm_gemini.key"
echo "Restart Whisper, then hold Fn to dictate."
