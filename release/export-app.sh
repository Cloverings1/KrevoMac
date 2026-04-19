#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="${REPO_ROOT}/Krevo"
PROJECT_PATH="${PROJECT_DIR}/Krevo.xcodeproj"
SCHEME="Krevo"
EXPORT_OPTIONS="${SCRIPT_DIR}/ExportOptions.plist"

find_developer_id_application() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
    | head -n 1
}

usage() {
  cat <<'EOF'
Usage: ./release/export-app.sh <version>

Creates:
  builds/<version>/Krevo.xcarchive
  builds/<version>/Krevo.app

Expected prerequisites:
  - A valid Developer ID Application certificate is available to Xcode
  - release/ExportOptions.plist is configured for the correct Apple team
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
BUILD_DIR="${REPO_ROOT}/builds/${VERSION}"
ARCHIVE_PATH="${BUILD_DIR}/Krevo.xcarchive"
APP_PATH="${BUILD_DIR}/Krevo.app"

if [[ ! -f "${EXPORT_OPTIONS}" ]]; then
  echo "error: missing export options at ${EXPORT_OPTIONS}" >&2
  exit 1
fi

DEVELOPER_ID_APPLICATION="$(find_developer_id_application)"
if [[ -z "${DEVELOPER_ID_APPLICATION}" ]]; then
  echo "error: no Developer ID Application signing certificate is installed on this Mac" >&2
  echo "Install the Developer ID certificate before exporting a public release." >&2
  exit 1
fi

mkdir -p "${BUILD_DIR}"

echo "Archiving ${SCHEME} to ${ARCHIVE_PATH}"
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  archive

echo "Exporting Developer ID app to ${BUILD_DIR}"
xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${BUILD_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: export did not produce ${APP_PATH}" >&2
  exit 1
fi

SIGNATURE_INFO="$(codesign -dvvv "${APP_PATH}" 2>&1 || true)"
if ! grep -Fq "Authority=Developer ID Application" <<<"${SIGNATURE_INFO}"; then
  echo "error: exported app is not signed with a Developer ID Application certificate" >&2
  echo "${SIGNATURE_INFO}" >&2
  exit 1
fi

codesign --verify --deep --strict "${APP_PATH}"

echo "Exported ${APP_PATH}"
