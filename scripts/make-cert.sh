#!/usr/bin/env bash
# One-time: create a self-signed "OpenFlow Dev" code-signing identity.
#
# macOS ties Microphone/Accessibility/Input Monitoring grants to the app's code signature. Ad-hoc
# signatures change with every build, so every rebuild re-prompts. With this identity the signature
# is "bundle id + this certificate", which stays the same across rebuilds.
#
# The identity lives in its own keychain (openflow-signing.keychain-db, appended to your keychain
# search list) with a fixed password, so builds never show keychain prompts. The certificate does
# not need to be trusted. Remove it with: scripts/make-cert.sh --remove
set -euo pipefail
NAME="OpenFlow Dev"
KC="$HOME/Library/Keychains/openflow-signing.keychain-db"
KC_PASS="openflow"  # protects only this throwaway signing key

search_list() { security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//'; }

if [[ "${1:-}" == "--remove" ]]; then
  security delete-keychain "$KC" 2>/dev/null && echo "Removed $KC" || echo "Nothing to remove"
  exit 0
fi

if [[ -f "$KC" ]] && security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  echo "$NAME identity already exists in $KC"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/openflow.p12" -passout pass:openflow

[[ -f "$KC" ]] || security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"  # no auto-lock
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$TMP/openflow.p12" -k "$KC" -P openflow -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null

if ! search_list | grep -qx "$KC"; then
  # shellcheck disable=SC2046
  security list-keychains -d user -s $(search_list) "$KC"
fi
echo "Created $NAME signing identity in $KC"
