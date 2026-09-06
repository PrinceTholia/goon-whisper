#!/bin/bash
# Build Whisper.app with a *stable* code signature when possible.
# Ad-hoc (-) signatures change every rebuild → Accessibility must be re-granted.
# A stable local or Developer ID identity keeps TCC across updates (like Wispr Flow).
set -e
cd "$(dirname "$0")"

APP_NAME="WhisperApp"
APP_BUNDLE="Whisper.app"

echo "🔨 Building release..."
swift build -c release

echo "📦 Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Info.plist" "$APP_BUNDLE/Contents/Info.plist"

if [ -f "assets/Icon.icns" ]; then
    cp "assets/Icon.icns" "$APP_BUNDLE/Contents/Resources/Icon.icns"
fi
if [ -f "assets/logo.png" ]; then
    cp "assets/logo.png" "$APP_BUNDLE/Contents/Resources/logo.png"
fi

IDENTITY=$("./scripts/resolve_sign_identity.sh")
echo "✍️  Signing with: $IDENTITY"

if [[ "$IDENTITY" != "-" ]]; then
  # One-time (or quiet refresh): stop Keychain password prompts on every codesign
  "./scripts/allow_codesign_access.sh" || true
fi

SIGN_ARGS=(--force --sign "$IDENTITY" --entitlements WhisperApp.entitlements --timestamp=none)
# Skip hardened runtime for local self-signed — less Keychain friction; TCC still keys off cert.
if [[ "$IDENTITY" == "-" ]]; then
  echo "⚠️  Ad-hoc signature — Accessibility will reset after each rebuild."
  echo "   Fix: Apple Developer ID, or keep the auto-created 'Goon Whisper Dev' cert."
fi

codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"

echo "✅ Done: $APP_BUNDLE  (identity: $IDENTITY)"
echo "   open $APP_BUNDLE"
if [[ "$IDENTITY" != "-" ]]; then
  echo "   Tip: Accessibility should stick across rebuilds with this identity."
  echo "   If Keychain still asks: run scripts/allow_codesign_access.sh once (or Allow all apps on the key)."
fi
