#!/usr/bin/env bash
# One-time: let /usr/bin/codesign use "Goon Whisper Dev" without a password every build.
# Accessibility survival ≠ Keychain ACL. Trusting the cert (password once) is separate from
# allowing codesign to *use the private key* on each rebuild (this script).
set -euo pipefail

CERT_CN="Goon Whisper Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
MARKER="${HOME}/.whisperapp/codesign_acl_ok"
PARTITION="apple-tool:,apple:,codesign:"

mkdir -p "${HOME}/.whisperapp"

if [[ -f "$MARKER" ]]; then
  # Still refresh partition list quietly when possible (unlocked keychain, no -k)
  security set-key-partition-list -S "$PARTITION" -s "$KEYCHAIN" >/dev/null 2>&1 || true
  exit 0
fi

# Prefer no password arg: works when login keychain is already unlocked (normal desktop session).
if security set-key-partition-list -S "$PARTITION" -s "$KEYCHAIN" >/dev/null 2>&1; then
  date >"$MARKER"
  echo "✅ codesign can use '$CERT_CN' without prompts." >&2
  exit 0
fi

# Ask once via GUI (Touch ID / password) — not stored, only used for this ACL update.
PASS=$(osascript <<'APPLESCRIPT' 2>/dev/null || true
display dialog "Allow Whisper rebuilds to sign without asking every time?

macOS needs your login password once so codesign can use the local “Goon Whisper Dev” key. This is Keychain access for signing — not Accessibility, and not sent anywhere.

(You can also: Keychain Access → login → Keys → Goon Whisper Dev → Access Control → Allow all applications.)" buttons {"Skip", "Allow"} default button "Allow" with title "Whisper signing" with icon caution
if button returned of result is "Skip" then
  return ""
end if
display dialog "Login Keychain password:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK"
text returned of result
APPLESCRIPT
)

if [[ -z "${PASS}" ]]; then
  echo "⚠️  Skipped Keychain ACL — codesign may ask for a password each rebuild." >&2
  exit 0
fi

if security set-key-partition-list -S "$PARTITION" -s -k "$PASS" "$KEYCHAIN" >/dev/null 2>&1; then
  date >"$MARKER"
  echo "✅ codesign ACL saved — later rebuilds should not ask for Keychain password." >&2
else
  echo "⚠️  Could not update Keychain ACL. Open Keychain Access → Goon Whisper Dev private key → Access Control → Allow all applications." >&2
fi

# Do not leave password in env
unset PASS
