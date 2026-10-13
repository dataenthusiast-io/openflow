#!/usr/bin/env bash
# Build OpenFlow.app into build/ and sign it.
# Signs with the "OpenFlow Dev" identity if present (run scripts/make-cert.sh once) so macOS keeps
# Microphone/Accessibility/Input Monitoring grants across rebuilds; otherwise falls back to ad-hoc.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/OpenFlow.app"

swift build -c release --package-path "$ROOT/app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/app/.build/release/OpenFlow" "$APP/Contents/MacOS/OpenFlow"
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sed "s|__ASR_DIR__|$ROOT/asr|" "$ROOT/app/Resources/Info.plist" > "$APP/Contents/Info.plist"

KC="$HOME/Library/Keychains/openflow-signing.keychain-db"
if [[ -f "$KC" ]] && security find-certificate -c "OpenFlow Dev" "$KC" >/dev/null 2>&1; then
  security unlock-keychain -p openflow "$KC"
  codesign --force --keychain "$KC" --sign "OpenFlow Dev" "$APP"
  echo "Signed with OpenFlow Dev"
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed (permissions reset on every rebuild; run scripts/make-cert.sh to fix)"
fi
echo "Built $APP"
