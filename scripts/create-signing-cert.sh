#!/bin/bash
# Create the stable local code-signing identity "NIO Play Local".
#
# Why: the macOS Application Firewall (socketfilterfw) and keychain ACLs key
# their authorizations on the app's code signature. An ad-hoc signature
# ("codesign --sign -") changes on EVERY rebuild, so the firewall allow rule
# and the keychain "Always Allow" grant are silently invalidated after each
# app update — the admin password gets asked again and again. A self-signed
# code-signing certificate has a stable Designated Requirement, so grants
# persist across rebuilds. Run this ONCE; afterwards:
#   - 防火墙「一键放行」只需授权一次，之后重建/更新不再弹管理员密码
#   - WiFi 密码钥匙串「始终允许」授权终身有效
#
# One-time GUI confirmation may appear when trusting the certificate.
set -euo pipefail

IDENTITY="NIO Play Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "Identity '$IDENTITY' already exists — nothing to do."
  security find-identity -v -p codesigning | grep "$IDENTITY"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Generating self-signed code-signing certificate (10 years)…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=$IDENTITY/O=NIO Play/C=CN" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# Legacy PBE algorithms: macOS `security import` cannot read OpenSSL 3's
# default AES-256/CBC+SHA256 MAC packaging (MAC verification failed).
openssl pkcs12 -export -out "$WORK/identity.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -passout pass:nio-play-local-import 2>/dev/null

echo "Importing into the login keychain…"
security import "$WORK/identity.p12" -k "$KEYCHAIN" \
  -P nio-play-local-import -T /usr/bin/codesign

echo "Trusting the certificate for code signing…"
# User-domain trust: may show one confirmation dialog, no admin password.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo ""
  echo "Done. Code-signing identity ready:"
  security find-identity -v -p codesigning | grep "$IDENTITY"
  echo ""
  echo "Next: rebuild the app (bash scripts/build-macplay.sh --arch=arm64) and"
  echo "click 防火墙「一键放行」 once — the grant now survives future updates."
else
  echo "ERROR: identity not visible to codesign." >&2
  echo "Open Keychain Access → login keychain → certificates → '$IDENTITY'" >&2
  echo "→ Get Info → Trust → set 'Code Signing' to 'Always Trust', then retry." >&2
  exit 1
fi
