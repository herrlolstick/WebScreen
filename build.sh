#!/usr/bin/env bash
# Builds WebScreen.app with Xcode, installs it to /Applications and launches it.
#
#   ./build.sh            build (Release), install and launch
#   ./build.sh build      build only (the app ends up in ~/Library/Caches/WebScreen-build/out)
#
# Signing uses the team configured in the Xcode project (Signing & Capabilities).
# You can also simply open WebScreen.xcodeproj in Xcode and press ⌘R.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="WebScreen"

# Keep build artifacts local – faster than on network drives and avoids
# signing problems caused by network file attributes.
SCRATCH="${HOME}/Library/Caches/${APP_NAME}-build"
OUT="${SCRATCH}/out"
APP="${OUT}/${APP_NAME}.app"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "▸ Building with Xcode …"
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" -configuration Release \
    -derivedDataPath "${SCRATCH}/xcode" -allowProvisioningUpdates -quiet build

rm -rf "${OUT}" && mkdir -p "${OUT}"
ditto "${SCRATCH}/xcode/Build/Products/Release/${APP_NAME}.app" "${APP}"
codesign --verify --deep --strict "${APP}"
echo "▸ Signed by: $(codesign -dvv "${APP}" 2>&1 | awk -F= '/^Authority/ { print $2; exit }')"

if [[ "${1:-}" == "build" ]]; then
    echo "✓ Done: ${APP}"
    exit 0
fi

echo "▸ Installing to /Applications …"
osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
rm -rf "/Applications/${APP_NAME}.app"
ditto "${APP}" "/Applications/${APP_NAME}.app"
open "/Applications/${APP_NAME}.app"
echo "✓ WebScreen is installed and running."
