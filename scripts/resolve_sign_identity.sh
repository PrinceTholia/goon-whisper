#!/usr/bin/env bash
# Ensure a stable local code-signing identity so Accessibility TCC survives rebuilds.
# Prefer Developer ID if present; otherwise create/reuse "Goon Whisper Dev".
#
# Critical on modern macOS:
# 1) PKCS#12 must use legacy PBE (OpenSSL 3 defaults break `security import`)
# 2) Self-signed cert must be trusted for codeSign or find-identity -v stays empty
set -euo pipefail

CERT_CN="Goon Whisper Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
TMPDIR_CERT="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_CERT"; }
trap cleanup EXIT

# Prefer system LibreSSL — Homebrew OpenSSL 3 often needs -legacy for PKCS#12
OPENSSL_BIN="/usr/bin/openssl"
if [[ ! -x "$OPENSSL_BIN" ]]; then
  OPENSSL_BIN="$(command -v openssl)"
fi

have_identity() {
  security find-identity -v -p codesigning 2>/dev/null | grep -F "$1" >/dev/null
}

trust_cert() {
  local pem="$1"
  # May prompt once for login keychain password / admin — needed for codesign policy
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$pem" >/dev/null 2>&1 || true
}

# 1) Apple Developer ID (best — same as commercial apps)
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 \
  | sed -n 's/.*"\(.*\)".*/\1/p' || true)
if [[ -n "${DEV_ID}" ]]; then
  echo "$DEV_ID"
  exit 0
fi

# 2) Existing local cert (already trusted + key present)
if have_identity "$CERT_CN"; then
  echo "$CERT_CN"
  exit 0
fi

# 2b) Cert may exist but lack codeSign trust — export and trust if we can find it
EXISTING_PEM="$TMPDIR_CERT/existing.pem"
if security find-certificate -c "$CERT_CN" -p "$KEYCHAIN" >"$EXISTING_PEM" 2>/dev/null; then
  echo "Trusting existing '$CERT_CN' for code signing…" >&2
  trust_cert "$EXISTING_PEM"
  if have_identity "$CERT_CN"; then
    echo "$CERT_CN"
    exit 0
  fi
fi

# 3) Create a 10-year self-signed code-signing cert (once)
echo "Creating local signing identity '$CERT_CN' (one-time; may ask for Keychain password)…" >&2

cat >"$TMPDIR_CERT/ext.cnf" <<EOF
[req]
distinguished_name = req_dn
x509_extensions = v3
prompt = no
[req_dn]
CN = ${CERT_CN}
O = Goon Whisper
C = US
[v3]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = critical,codeSigning
EOF

"$OPENSSL_BIN" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMPDIR_CERT/key.pem" \
  -out "$TMPDIR_CERT/cert.pem" \
  -config "$TMPDIR_CERT/ext.cnf" \
  >/dev/null 2>&1

export_p12() {
  local extra=("$@")
  "$OPENSSL_BIN" pkcs12 -export \
    -out "$TMPDIR_CERT/cert.p12" \
    -inkey "$TMPDIR_CERT/key.pem" \
    -in "$TMPDIR_CERT/cert.pem" \
    -passout pass:goon-whisper-temp \
    "${extra[@]}" \
    >/dev/null 2>&1
}

# macOS Security.framework rejects OpenSSL 3 default PBES2/AES PKCS#12
if ! export_p12 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1; then
  export_p12 -legacy || export_p12
fi

security import "$TMPDIR_CERT/cert.p12" \
  -k "$KEYCHAIN" \
  -P goon-whisper-temp \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -A \
  >/dev/null 2>&1 || true

trust_cert "$TMPDIR_CERT/cert.pem"

# Allow codesign to use the key without GUI prompt every rebuild.
# Empty -k "" fails silently when the login keychain has a password — use the helper instead.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/allow_codesign_access.sh" >/dev/null 2>&1 || true

if have_identity "$CERT_CN"; then
  echo "$CERT_CN"
  exit 0
fi

echo "WARN: could not create '$CERT_CN'; falling back to ad-hoc (-)" >&2
echo "WARN: Fix: Keychain Access → trust 'Goon Whisper Dev' for Code Signing, or get a Developer ID." >&2
echo "-"
