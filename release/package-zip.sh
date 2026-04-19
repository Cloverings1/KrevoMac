#!/bin/bash
#
# package-zip.sh <version>
#
# Packages a ZIP distribution that avoids the macOS DMG-verification
# Gatekeeper dialog entirely. The ZIP contains Krevo.app, Install.command,
# and README.txt at the root. The recipient extracts it and double-clicks
# Install.command.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="Krevo"

usage() {
  cat <<'EOF'
Usage: ./release/package-zip.sh <version>

Expected input:
  builds/<version>/Krevo.app

Output:
  builds/<version>/Krevo-<version>.zip
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
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}.zip"
README_TEMPLATE="${SCRIPT_DIR}/README.txt.template"
INSTALL_SCRIPT="${SCRIPT_DIR}/Install.command"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: missing app bundle at ${APP_PATH}" >&2
  exit 1
fi
if [[ ! -f "${INSTALL_SCRIPT}" ]]; then
  echo "error: missing ${INSTALL_SCRIPT}" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/krevo-zip.${VERSION}.XXXXXX")"
cleanup() { rm -rf "${STAGING_DIR}"; }
trap cleanup EXIT

PAYLOAD_DIR="${STAGING_DIR}/Krevo-${VERSION}"
mkdir -p "${PAYLOAD_DIR}"

ditto "${APP_PATH}" "${PAYLOAD_DIR}/${APP_NAME}.app"
xattr -dr com.apple.quarantine "${PAYLOAD_DIR}/${APP_NAME}.app" 2>/dev/null || true

cp "${INSTALL_SCRIPT}" "${PAYLOAD_DIR}/Install.command"
chmod +x "${PAYLOAD_DIR}/Install.command"
xattr -cr "${PAYLOAD_DIR}/Install.command" 2>/dev/null || true

sed \
  -e "s|__VERSION__|${VERSION}|g" \
  -e "s|__APP_NAME__|${APP_NAME}|g" \
  -e "s|__SIGNING_DESCRIPTION__|ad-hoc signature|g" \
  -e "s|__NOTARIZATION_DESCRIPTION__|not notarized|g" \
  -e "s|__OPEN_INSTRUCTIONS__|$(escape_sed "That xattr command clears the download quarantine flag — after that, just double-click Krevo.app to launch.")|g" \
  "${README_TEMPLATE}" > "${PAYLOAD_DIR}/README.txt"

if [[ -f "${ZIP_PATH}" ]]; then
  rm -f "${ZIP_PATH}"
fi

echo "Creating ZIP ${ZIP_PATH}"
(cd "${STAGING_DIR}" && ditto -c -k --keepParent "Krevo-${VERSION}" "${ZIP_PATH}")

echo "Created ${ZIP_PATH}"
