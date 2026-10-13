#!/usr/bin/env bash
# One-time: create a self-signed "Flow Dev" code-signing certificate in the login keychain.
# A stable signature lets macOS remember the permissions you grant Flow across rebuilds.
set -euo pipefail
if security find-certificate -c "Flow Dev" >/dev/null 2>&1; then
  echo "Flow Dev certificate already exists"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Flow Dev
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "Flow Dev" -out "$TMP/flow.p12" -passout pass:flowdev
security import "$TMP/flow.p12" -k ~/Library/Keychains/login.keychain-db -P flowdev -T /usr/bin/codesign
# Trust it for code signing (macOS asks for your password).
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"
echo "Created Flow Dev signing identity"
