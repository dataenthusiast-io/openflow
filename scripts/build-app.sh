#!/usr/bin/env bash
# Build Flow.app into build/ and sign it.
# Signs with the "Flow Dev" identity if present (run scripts/make-cert.sh once) so macOS keeps
# Microphone/Accessibility/Input Monitoring grants across rebuilds; otherwise falls back to ad-hoc.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Flow.app"

swift build -c release --package-path "$ROOT/app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/app/.build/release/Flow" "$APP/Contents/MacOS/Flow"
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sed "s|__ASR_DIR__|$ROOT/asr|" "$ROOT/app/Resources/Info.plist" > "$APP/Contents/Info.plist"

if security find-certificate -c "Flow Dev" >/dev/null 2>&1; then
  codesign --force --sign "Flow Dev" "$APP"
  echo "Signed with Flow Dev"
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed (permissions reset on every rebuild; run scripts/make-cert.sh to fix)"
fi
echo "Built $APP"
