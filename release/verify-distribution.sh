#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: ./release/verify-distribution.sh <version>

Checks that builds/<version>/ contains a public-distribution-safe artifact set:
  - Krevo.app signed with Developer ID Application
  - no development-only entitlements or device provisioning profile
  - Krevo-<version>.dmg signed, stapled, and Gatekeeper-accepted (if present)
EOF
}

app_entitlements() {
  codesign --display --entitlements :- "$1" 2>/dev/null || true
}

app_profile_plist() {
  local profile_path="$1/Contents/embedded.provisionprofile"
  if [[ -f "${profile_path}" ]]; then
    security cms -D -i "${profile_path}" 2>/dev/null || true
  fi
}

app_has_get_task_allow() {
  local entitlements
  entitlements="$(app_entitlements "$1")"
  grep -Fq "<key>com.apple.security.get-task-allow</key><true/>" <<<"${entitlements}"
}

app_has_development_profile() {
  local profile_plist
  profile_plist="$(app_profile_plist "$1")"
  [[ -n "${profile_plist}" ]] || return 1

  grep -Fq "<key>ProvisionedDevices</key>" <<<"${profile_plist}" \
    || grep -Fq "Mac Team Provisioning Profile:" <<<"${profile_plist}"
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
BUILD_DIR="${REPO_ROOT}/builds/${VERSION}"
APP_PATH="${BUILD_DIR}/Krevo.app"
DMG_PATH="${BUILD_DIR}/Krevo-${VERSION}.dmg"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: missing app bundle at ${APP_PATH}" >&2
  exit 1
fi

APP_SIGNATURE_INFO="$(codesign -dvvv "${APP_PATH}" 2>&1 || true)"
if ! grep -Fq "Authority=Developer ID Application" <<<"${APP_SIGNATURE_INFO}"; then
  echo "error: ${APP_PATH} is not signed with a Developer ID Application certificate" >&2
  echo "${APP_SIGNATURE_INFO}" >&2
  exit 1
fi

codesign --verify --deep --strict "${APP_PATH}"

if app_has_get_task_allow "${APP_PATH}"; then
  echo "error: ${APP_PATH} still has com.apple.security.get-task-allow enabled" >&2
  exit 1
fi

if app_has_development_profile "${APP_PATH}"; then
  echo "error: ${APP_PATH} still embeds a development provisioning profile" >&2
  exit 1
fi

if [[ -f "${DMG_PATH}" ]]; then
  codesign --verify --verbose "${DMG_PATH}"
  xcrun stapler validate "${DMG_PATH}"
  spctl -a -vvv -t open --context context:primary-signature "${DMG_PATH}"
else
  echo "warning: missing DMG at ${DMG_PATH}; skipped container notarization checks" >&2
fi

echo "Distribution verification passed for ${VERSION}"
