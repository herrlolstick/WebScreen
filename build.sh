#!/usr/bin/env bash
# Builds WebScreen.app, signs it and installs it to /Applications.
#
#   ./build.sh            build, install and launch
#   ./build.sh build      build only (the app ends up in ~/Library/Caches/WebScreen-build/out)
#
# Signing: by default an "Apple Development" identity from the keychain is used
# automatically (it is created when you add your Apple ID in Xcode).
# Other identity:  SIGN_IDENTITY="Apple Development: Name (TEAMID)" ./build.sh
set -euo pipefail

cd "$(dirname "$0")"
REPO="$(pwd)"
APP_NAME="WebScreen"

# Keep build artifacts local – faster than on network drives and avoids
# signing problems caused by network file attributes.
SCRATCH="${HOME}/Library/Caches/${APP_NAME}-build"
OUT="${SCRATCH}/out"
APP="${OUT}/${APP_NAME}.app"

echo "▸ Compiling …"
swift build -c release --scratch-path "${SCRATCH}/swiftpm"
BIN_DIR="$(swift build -c release --scratch-path "${SCRATCH}/swiftpm" --show-bin-path)"

echo "▸ Creating app bundle …"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "${REPO}/Support/Info.plist" "${APP}/Contents/Info.plist"
cp "${REPO}/Resources/index.html" "${APP}/Contents/Resources/index.html"

# Generate the app icon from Support/AppIcon.png
ICONSET="${SCRATCH}/AppIcon.iconset"
rm -rf "${ICONSET}" && mkdir -p "${ICONSET}"
for size in 16 32 128 256 512; do
    sips -z ${size} ${size} "${REPO}/Support/AppIcon.png" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z ${double} ${double} "${REPO}/Support/AppIcon.png" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${APP}/Contents/Resources/AppIcon.icns"
xattr -cr "${APP}"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "${IDENTITY}" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi
if [[ -z "${IDENTITY}" ]]; then
    IDENTITY="-"
    echo "⚠︎ No signing identity found – signing ad hoc."
    echo "  macOS will then ask for the Screen Recording permission again after every build."
    echo "  Fix: add your Apple ID in Xcode → Settings → Accounts and let it create an"
    echo "  'Apple Development' certificate."
fi
echo "▸ Signing with: ${IDENTITY}"
codesign --force --sign "${IDENTITY}" "${APP}"

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
