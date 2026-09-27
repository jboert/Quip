#!/usr/bin/env bash
# testflight.sh — archive the iOS app (with its embedded watch app), export an
# App Store IPA, and upload it to TestFlight.
#
#   tools/testflight.sh            archive + export + upload
#   tools/testflight.sh --no-upload   archive + export only (signing dry run)
#
# Needs:
#   QuipiOS/Signing.local.xcconfig   DEVELOPMENT_TEAM + QUIP_APP_BUNDLE_ID
#   QUIP_ASC_KEY_ID, QUIP_ASC_ISSUER_ID   App Store Connect API key; the .p8 at
#                                    ~/private_keys/AuthKey_<id>.p8 (where
#                                    altool and xcodebuild look for it)
#   An App Store Connect app record for QUIP_APP_BUNDLE_ID. Apple only lets
#   you create that on the website; the upload fails without it.
#
# Builds from whatever is checked out. Run it from a clean worktree so an
# uncommitted change cannot ship by accident.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPLOAD=1
[ "${1:-}" = "--no-upload" ] && UPLOAD=0

KEY_ID="${QUIP_ASC_KEY_ID:?set QUIP_ASC_KEY_ID}"
ISSUER="${QUIP_ASC_ISSUER_ID:?set QUIP_ASC_ISSUER_ID}"
KEY_PATH="$HOME/private_keys/AuthKey_${KEY_ID}.p8"
[ -f "$KEY_PATH" ] || { echo "❌ API key not found at $KEY_PATH" >&2; exit 1; }
[ -f "$ROOT/QuipiOS/Signing.local.xcconfig" ] || { echo "❌ QuipiOS/Signing.local.xcconfig missing" >&2; exit 1; }

OUT="$ROOT/QuipiOS/build/testflight"
ARCHIVE="$OUT/Quip.xcarchive"
EXPORT="$OUT/export"
LOG="$OUT/testflight.log"
BUILD_NUM="$(date +%Y%m%d%H%M)"
rm -rf "$OUT" && mkdir -p "$OUT"

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$KEY_ID"
      -authenticationKeyIssuerID "$ISSUER")

echo "→ xcodegen"
(cd "$ROOT/QuipiOS" && xcodegen generate >/dev/null) || { echo "❌ xcodegen failed" >&2; exit 1; }

echo "→ archive (build $BUILD_NUM) — log: $LOG"
xcodebuild archive \
  -project "$ROOT/QuipiOS/QuipiOS.xcodeproj" -scheme QuipiOS -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
  "${AUTH[@]}" CURRENT_PROJECT_VERSION="$BUILD_NUM" >"$LOG" 2>&1
rc=$?
if [ $rc -ne 0 ] || [ ! -d "$ARCHIVE" ]; then
  grep -E "error:|ARCHIVE FAILED" "$LOG" | awk '!s[$0]++' | head -15 >&2
  echo "❌ archive failed (exit $rc)" >&2; exit 1
fi

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST

echo "→ export"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" "${AUTH[@]}" >>"$LOG" 2>&1
rc=$?
IPA="$(find "$EXPORT" -name '*.ipa' 2>/dev/null | head -1)"
if [ $rc -ne 0 ] || [ -z "$IPA" ]; then
  grep -E "error:|EXPORT FAILED|Error Domain" "$LOG" | awk '!s[$0]++' | head -15 >&2
  echo "❌ export failed (exit $rc)" >&2; exit 1
fi
echo "✓ IPA: $IPA"

[ $UPLOAD -eq 1 ] || { echo "✓ --no-upload: stopping before TestFlight"; exit 0; }

echo "→ upload to TestFlight"
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER" >>"$LOG" 2>&1
rc=$?
if [ $rc -ne 0 ] || ! grep -q "UPLOAD SUCCEEDED\|No errors uploading" "$LOG"; then
  grep -iE "error|fail" "$LOG" | tail -10 >&2
  echo "❌ upload failed (exit $rc)" >&2; exit 1
fi
echo "✅ build $BUILD_NUM uploaded — TestFlight processing takes 5-30 min"
