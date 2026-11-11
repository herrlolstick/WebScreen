#!/usr/bin/env bash
# Builds a notarized, stapled WebScreen release that anyone can download and open –
# no Xcode, no "unidentified developer" warning.
#
#   ./release.sh          archive → export (Developer ID) → notarize → staple → DMG + ZIP
#
# Output: ~/Library/Caches/WebScreen-build/release/WebScreen-<version>.dmg (and .zip)
#
# One-time setup (see README → "Publishing a release"):
#   1. A "Developer ID Application" certificate for team 566V5MVR96 in your keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
#   2. A notarytool keychain profile – you type the app-specific password yourself:
#        xcrun notarytool store-credentials WebScreen-notary \
#            --apple-id <your Apple ID> --team-id 566V5MVR96
#      Use another profile name via NOTARY_PROFILE=... ./release.sh
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="WebScreen"
TEAM_ID="566V5MVR96"
NOTARY_PROFILE="${NOTARY_PROFILE:-WebScreen-notary}"

# Build locally (not on network drives) – faster and avoids signing problems.
SCRATCH="${HOME}/Library/Caches/${APP_NAME}-build"
ARCHIVE="${SCRATCH}/${APP_NAME}.xcarchive"
EXPORT="${SCRATCH}/export"
RELEASE="${SCRATCH}/release"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

fail() { echo "✗ $*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────
# The app is signed by Xcode during export – a local Developer ID certificate is optional,
# Xcode falls back to the cloud-managed one of the team. A local one is only used to sign the DMG.
SIGN_ID=$(security find-identity -v -p codesigning \
    | awk -F'"' -v team="(${TEAM_ID})" '/Developer ID Application/ && index($2, team) { print $2; exit }')

xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1 \
    || fail "Notary profile \"${NOTARY_PROFILE}\" not found or not working. Create it once with:
  xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <your Apple ID> --team-id ${TEAM_ID}"

if [[ -n "${SIGN_ID}" ]]; then
    echo "▸ Local signing identity (DMG): ${SIGN_ID}"
else
    echo "▸ No local Developer ID certificate – app is signed via Xcode's cloud signing, DMG stays unsigned."
fi

# ── Archive & export ─────────────────────────────────────────────────────────
rm -rf "${ARCHIVE}" "${EXPORT}" "${RELEASE}"
mkdir -p "${RELEASE}"

echo "▸ Archiving …"
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "${SCRATCH}/xcode" -archivePath "${ARCHIVE}" \
    -allowProvisioningUpdates -quiet archive

echo "▸ Exporting with Developer ID …"
xcodebuild -exportArchive -archivePath "${ARCHIVE}" -exportPath "${EXPORT}" \
    -exportOptionsPlist Support/ExportOptions.plist -allowProvisioningUpdates -quiet

APP="${EXPORT}/${APP_NAME}.app"
codesign --verify --deep --strict "${APP}"
SIG_INFO=$(codesign -dvv "${APP}" 2>&1)
[[ "${SIG_INFO}" == *"Authority=Developer ID Application"* ]] \
    || fail "Exported app is not signed with Developer ID."
[[ "${SIG_INFO}" == *"(runtime)"* ]] \
    || fail "Exported app has no hardened runtime – notarization would fail."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist")
BASENAME="${APP_NAME}-${VERSION}"
echo "▸ Version ${VERSION}"

notarize() {
    echo "▸ Notarizing $(basename "$1") (this usually takes a few minutes) …"
    local log="${SCRATCH}/notary-$(basename "$1").json"
    xcrun notarytool submit "$1" --keychain-profile "${NOTARY_PROFILE}" --wait \
        --output-format json > "${log}" || true
    local status id
    status=$(/usr/bin/plutil -extract status raw -o - "${log}" 2>/dev/null || echo "unknown")
    id=$(/usr/bin/plutil -extract id raw -o - "${log}" 2>/dev/null || echo "")
    if [[ "${status}" != "Accepted" ]]; then
        [[ -n "${id}" ]] && xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" >&2
        fail "Notarization of $(basename "$1") failed (status: ${status})."
    fi
}

# ── 1. Notarize + staple the app itself (so it also works offline after copying) ──
ZIP_TMP="${SCRATCH}/${APP_NAME}-notarize.zip"
ditto -c -k --keepParent "${APP}" "${ZIP_TMP}"
notarize "${ZIP_TMP}"
rm -f "${ZIP_TMP}"
xcrun stapler staple "${APP}"

# ZIP for people who prefer it (e.g. GitHub release asset).
ditto -c -k --keepParent "${APP}" "${RELEASE}/${BASENAME}.zip"

# ── 2. DMG with drag-to-Applications layout ──────────────────────────────────
echo "▸ Building DMG …"
STAGE="${SCRATCH}/dmg-stage"
rm -rf "${STAGE}" && mkdir -p "${STAGE}"
ditto "${APP}" "${STAGE}/${APP_NAME}.app"
ln -s /Applications "${STAGE}/Applications"
DMG="${RELEASE}/${BASENAME}.dmg"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" -fs HFS+ -format UDZO -ov "${DMG}" >/dev/null
rm -rf "${STAGE}"
[[ -n "${SIGN_ID}" ]] && codesign --sign "${SIGN_ID}" --timestamp "${DMG}"
notarize "${DMG}"
xcrun stapler staple "${DMG}"

# ── 3. Verify ────────────────────────────────────────────────────────────────
echo "▸ Verifying …"
xcrun stapler validate "${APP}"
xcrun stapler validate "${DMG}"
spctl -a -vv -t exec "${APP}"
[[ -n "${SIGN_ID}" ]] && spctl -a -vv -t open --context context:primary-signature "${DMG}"

shasum -a 256 "${DMG}" "${RELEASE}/${BASENAME}.zip" | tee "${RELEASE}/SHA256SUMS.txt"
echo "✓ Release ready in ${RELEASE}"
[[ -t 1 ]] && open "${RELEASE}" || true
