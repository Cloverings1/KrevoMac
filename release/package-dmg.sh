#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="Krevo"
ENTITLEMENTS_PATH="${REPO_ROOT}/Krevo/Krevo/Krevo.entitlements"
CODESIGN_IDENTITY="${KREVO_CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${KREVO_NOTARY_PROFILE:-}"

usage() {
  cat <<'EOF'
Usage: ./release/package-dmg.sh <version>

Expected input:
  builds/<version>/Krevo.app

Output:
  builds/<version>/Krevo-<version>.dmg

Environment:
  KREVO_CODESIGN_IDENTITY  Optional signing identity. Defaults to ad-hoc signing (`-`).
                           If the app already has a real signature, the script preserves it.
                           Set to a Developer ID Application identity for production packaging.
  KREVO_NOTARY_PROFILE     Optional notarytool keychain profile. When set, the DMG is submitted
                           for notarization, then stapled and Gatekeeper-checked.
EOF
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
BUILD_DIR="${REPO_ROOT}/builds/${VERSION}"
APP_PATH="${BUILD_DIR}/Krevo.app"
DMG_PATH="${BUILD_DIR}/Krevo-${VERSION}.dmg"
README_TEMPLATE="${SCRIPT_DIR}/README.txt.template"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: missing app bundle at ${APP_PATH}" >&2
  echo "Build the Release app into builds/${VERSION} before packaging." >&2
  exit 1
fi

if [[ ! -f "${README_TEMPLATE}" ]]; then
  echo "error: missing DMG README template at ${README_TEMPLATE}" >&2
  exit 1
fi

APP_SIGNATURE_INFO="$(codesign -dvvv "${APP_PATH}" 2>&1 || true)"

if [[ "${CODESIGN_IDENTITY}" != "-" && ! -f "${ENTITLEMENTS_PATH}" ]]; then
  echo "error: missing entitlements file at ${ENTITLEMENTS_PATH}" >&2
  exit 1
fi

if [[ -n "${NOTARY_PROFILE}" && "${CODESIGN_IDENTITY}" == "-" ]]; then
  echo "error: notarization requires a non-ad-hoc signing identity" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/krevo-dmg.${VERSION}.XXXXXX")"
PRESERVED_EXISTING_SIGNATURE=0
cleanup() {
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  NOTARIZATION_DESCRIPTION="not notarized"

  if grep -Fq "Signature=adhoc" <<<"${APP_SIGNATURE_INFO}" || ! grep -Fq "TeamIdentifier=" <<<"${APP_SIGNATURE_INFO}"; then
    SIGNING_DESCRIPTION="ad-hoc signature"
    OPEN_INSTRUCTIONS="If macOS warns because this build is not notarized, Control-click the app, choose Open, then confirm."
    echo "Ad-hoc signing ${APP_PATH}"
    codesign --force --deep --sign - "${APP_PATH}"
  else
    TEAM_ID="$(sed -n 's/^TeamIdentifier=//p' <<<"${APP_SIGNATURE_INFO}" | head -n 1)"
    if [[ -n "${TEAM_ID}" ]]; then
      SIGNING_DESCRIPTION="existing app signature (TeamIdentifier ${TEAM_ID})"
    else
      SIGNING_DESCRIPTION="existing app signature"
    fi
    OPEN_INSTRUCTIONS="Launch Krevo normally. This build keeps its existing local app signature, but it is not notarized."
    echo "Preserving existing app signature for ${APP_PATH}"
    PRESERVED_EXISTING_SIGNATURE=1
  fi
else
  SIGNING_DESCRIPTION="${CODESIGN_IDENTITY}"
  if [[ -n "${NOTARY_PROFILE}" ]]; then
    NOTARIZATION_DESCRIPTION="submitted with notarytool profile ${NOTARY_PROFILE}, stapled, and Gatekeeper-verified"
    OPEN_INSTRUCTIONS="Launch Krevo from Applications. Gatekeeper should open it normally."
  else
    NOTARIZATION_DESCRIPTION="not notarized"
    OPEN_INSTRUCTIONS="This build is Developer ID signed, but macOS may still warn until it is notarized."
  fi

  if ! grep -Fq "Authority=Developer ID Application" <<<"${APP_SIGNATURE_INFO}"; then
    echo "error: ${APP_PATH} is not signed with a Developer ID Application certificate" >&2
    echo "Export the app with ./release/export-app.sh <version> before production packaging." >&2
    exit 1
  fi
fi

VERIFY_OUTPUT="$(codesign --verify --deep --strict "${APP_PATH}" 2>&1)" || VERIFY_STATUS=$?
VERIFY_STATUS="${VERIFY_STATUS:-0}"
if [[ "${VERIFY_STATUS}" -ne 0 ]]; then
  if [[ "${PRESERVED_EXISTING_SIGNATURE}" -eq 1 && "${VERIFY_OUTPUT}" == *"CSSMERR_TP_NOT_TRUSTED"* ]]; then
    echo "warning: preserving existing local app signature despite trust verification error:" >&2
    echo "${VERIFY_OUTPUT}" >&2
  else
    echo "${VERIFY_OUTPUT}" >&2
    exit "${VERIFY_STATUS}"
  fi
fi

README_PATH="${STAGING_DIR}/README.txt"
sed \
  -e "s|__VERSION__|${VERSION}|g" \
  -e "s|__APP_NAME__|$(escape_sed "${APP_NAME}")|g" \
  -e "s|__SIGNING_DESCRIPTION__|$(escape_sed "${SIGNING_DESCRIPTION}")|g" \
  -e "s|__NOTARIZATION_DESCRIPTION__|$(escape_sed "${NOTARIZATION_DESCRIPTION}")|g" \
  -e "s|__OPEN_INSTRUCTIONS__|$(escape_sed "${OPEN_INSTRUCTIONS}")|g" \
  "${README_TEMPLATE}" > "${README_PATH}"

ditto "${APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

if [[ -f "${DMG_PATH}" ]]; then
  rm -f "${DMG_PATH}"
fi

echo "Creating DMG ${DMG_PATH}"
hdiutil create \
  -volname "Krevo ${VERSION}" \
  -srcfolder "${STAGING_DIR}" \
  -format UDZO \
  "${DMG_PATH}"
hdiutil verify "${DMG_PATH}"

if [[ "${CODESIGN_IDENTITY}" != "-" ]]; then
  echo "Signing DMG ${DMG_PATH}"
  codesign --force --sign "${CODESIGN_IDENTITY}" --timestamp "${DMG_PATH}"
  codesign --verify --verbose "${DMG_PATH}"
fi

if [[ -n "${NOTARY_PROFILE}" ]]; then
  echo "Submitting ${DMG_PATH} for notarization with profile ${NOTARY_PROFILE}"
  xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${DMG_PATH}"
  xcrun stapler validate "${DMG_PATH}"
  spctl -a -vvv -t open --context context:primary-signature "${DMG_PATH}"
fi

echo "Created ${DMG_PATH}"
