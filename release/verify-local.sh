#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="${REPO_ROOT}/Krevo"
PROJECT_PATH="${PROJECT_DIR}/Krevo.xcodeproj"
SCHEME="Krevo"

usage() {
  cat <<'EOF'
Usage: ./release/verify-local.sh <version>

Runs the current shippable local verification lane:
  1. Debug build
  2. Unit tests only (`KrevoTests`)
  3. Release build into builds/<version>

Notes:
  - The generated UI test target is intentionally excluded from this gate.
  - Finish with a manual menu-bar smoke pass before shipping.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
BUILD_DIR="${REPO_ROOT}/builds/${VERSION}"

echo "Running Debug build"
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Debug \
  build

echo "Running unit tests"
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -destination 'platform=macOS' \
  -only-testing:KrevoTests \
  test

echo "Running Release build into ${BUILD_DIR}"
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  build \
  CONFIGURATION_BUILD_DIR="${BUILD_DIR}"

cat <<EOF
Local verification succeeded.

Manual smoke still required:
- Launch the app
- Verify the menu bar item appears
- Open the popover
- Verify the signed-out or signed-in shell renders
- Verify file picker / drag target is reachable
- Quit the app cleanly
EOF
