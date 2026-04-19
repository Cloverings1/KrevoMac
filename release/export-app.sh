#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="${REPO_ROOT}/Krevo"
PROJECT_PATH="${PROJECT_DIR}/Krevo.xcodeproj"
SCHEME="Krevo"
EXPORT_OPTIONS="${SCRIPT_DIR}/ExportOptions.plist"

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

if [[ ! -f "${EXPORT_OPTIONS}" ]]; then
  echo "error: missing export options at ${EXPORT_OPTIONS}" >&2
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

echo "Exported ${BUILD_DIR}/Krevo.app"
