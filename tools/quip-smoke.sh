#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOPS=1
SKIP_MAC=0
SKIP_IOS=0
ALLOW_LOCKED_LAUNCH=0
DEVICE_ID="${QUIP_DEVICE_ID:-FA951BBB-D706-5FCF-9886-3E57560E9030}"
IOS_DESTINATION="${QUIP_IOS_DESTINATION:-platform=iOS,id=00008150-000248600280401C}"
SIGN_IDENTITY="${QUIP_MAC_SIGN_IDENTITY:-Apple Development: Erick Bzovi (78G9JU394V)}"
MAC_DERIVED_DATA="${ROOT}/build/smoke/DerivedDataMac"
MAC_APP="${MAC_DERIVED_DATA}/Build/Products/Debug/Quip.app"
IOS_DERIVED_DATA="${ROOT}/build/smoke/DerivedDataIOS"
IOS_APP="${ROOT}/QuipiOS/build/Debug-iphoneos/Quip.app"
REPORT_DIR="${ROOT}/build/smoke"
REPORT="${REPORT_DIR}/last-smoke.txt"
IOS_LAUNCH_LOG="${REPORT_DIR}/last-ios-launch.txt"

usage() {
  cat <<USAGE
Usage: tools/quip-smoke.sh [--loops N] [--skip-mac] [--skip-ios] [--allow-locked-launch]

Environment overrides:
  QUIP_DEVICE_ID             CoreDevice identifier for devicectl install/launch
  QUIP_IOS_DESTINATION       xcodebuild destination, e.g. platform=iOS,id=<UDID>
  QUIP_MAC_SIGN_IDENTITY     codesign identity for /Applications/Quip.app
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --loops)
      if [[ $# -lt 2 || "${2:-}" == --* ]]; then
        echo "--loops requires a positive integer" >&2
        usage >&2
        exit 2
      fi
      LOOPS="${2:-}"
      shift 2
      ;;
    --skip-mac)
      SKIP_MAC=1
      shift
      ;;
    --skip-ios)
      SKIP_IOS=1
      shift
      ;;
    --allow-locked-launch)
      ALLOW_LOCKED_LAUNCH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$LOOPS" =~ ^[0-9]+$ ]] || [[ "$LOOPS" -lt 1 ]]; then
  echo "--loops must be a positive integer" >&2
  exit 2
fi

if [[ "$SKIP_MAC" -eq 1 && "$SKIP_IOS" -eq 1 ]]; then
  echo "At least one platform must run; --skip-mac and --skip-ios cannot be used together" >&2
  exit 2
fi

mkdir -p "$REPORT_DIR"
: > "$REPORT"

log() {
  local line
  line="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
  echo "$line"
  echo "$line" >> "$REPORT"
}

run() {
  log "+ $*"
  "$@" 2>&1 | tee -a "$REPORT"
}

ios_launch_failure_is_locked_phone() {
  grep -Eiq '(locked|unlock|passcode)' "$IOS_LAUNCH_LOG"
}

stop_mac_app() {
  /usr/bin/osascript -e 'tell application "Quip" to quit' >/dev/null 2>&1 || true
  sleep 1
  if pgrep -x Quip >/dev/null 2>&1; then
    pkill -x Quip || true
    sleep 1
  fi
}

smoke_mac() {
  log "Mac: building QuipMac"
  run xcodebuild build \
    -project "$ROOT/QuipMac/QuipMac.xcodeproj" \
    -scheme QuipMac \
    -destination "platform=macOS,name=My Mac" \
    -derivedDataPath "$MAC_DERIVED_DATA"

  if [[ ! -d "$MAC_APP" ]]; then
    log "Mac: build output missing at $MAC_APP"
    return 1
  fi

  log "Mac: installing /Applications/Quip.app"
  stop_mac_app
  run /bin/rm -rf /Applications/Quip.app
  run ditto "$MAC_APP" /Applications/Quip.app
  run codesign --force --deep --sign "$SIGN_IDENTITY" /Applications/Quip.app
  run codesign --verify --deep --strict /Applications/Quip.app
  run open /Applications/Quip.app
  sleep 2

  if ! pgrep -x Quip >/dev/null 2>&1; then
    log "Mac: launch failed, Quip process is not running"
    return 1
  fi

  if /usr/bin/log show --last 10s --predicate 'process == "Quip" AND eventMessage CONTAINS "Address already in use"' --style compact | grep -q "Address already in use"; then
    log "Mac: port smoke failed, Quip logged Address already in use"
    return 1
  fi

  log "Mac: smoke passed"
}

smoke_ios() {
  log "iOS: checking device $DEVICE_ID"
  run xcrun devicectl device info details --device "$DEVICE_ID"

  log "iOS: building QuipiOS for $IOS_DESTINATION"
  run xcodebuild build \
    -project "$ROOT/QuipiOS/QuipiOS.xcodeproj" \
    -target QuipiOS \
    -destination "$IOS_DESTINATION"

  if [[ ! -d "$IOS_APP" ]]; then
    log "iOS: build output missing at $IOS_APP"
    return 1
  fi

  log "iOS: installing Quip.app"
  run xcrun devicectl device install app --device "$DEVICE_ID" "$IOS_APP"

  log "iOS: launching com.quip.QuipiOS"
  log "+ xcrun devicectl device process launch --device $DEVICE_ID com.quip.QuipiOS"
  : > "$IOS_LAUNCH_LOG"
  if xcrun devicectl device process launch --device "$DEVICE_ID" com.quip.QuipiOS 2>&1 | tee "$IOS_LAUNCH_LOG" | tee -a "$REPORT"; then
    log "iOS: launch passed"
  elif [[ "$ALLOW_LOCKED_LAUNCH" -eq 1 ]] && ios_launch_failure_is_locked_phone; then
    log "iOS: install passed, launch failed because the phone appears locked; unlock phone and rerun --skip-mac"
  else
    log "iOS: launch failed after install"
    return 1
  fi
}

for ((i = 1; i <= LOOPS; i++)); do
  log "Smoke loop $i/$LOOPS started"
  if [[ "$SKIP_MAC" -eq 0 ]]; then
    smoke_mac
  else
    log "Mac: skipped"
  fi
  if [[ "$SKIP_IOS" -eq 0 ]]; then
    smoke_ios
  else
    log "iOS: skipped"
  fi
  log "Smoke loop $i/$LOOPS finished"
done

log "Smoke report: $REPORT"
