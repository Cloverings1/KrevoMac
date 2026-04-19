#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_developer_id_application() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
    | head -n 1
}

usage() {
  cat <<'EOF'
Usage: ./release/build-distribution.sh <version>

Builds a customer-facing Krevo release:
  1. Export Krevo.app with Developer ID
  2. Package Krevo-<version>.dmg with the same identity
  3. Notarize, staple, and Gatekeeper-verify the DMG
  4. Run distribution verification checks

Environment:
  KREVO_CODESIGN_IDENTITY  Optional Developer ID Application identity for DMG signing.
                           Defaults to the first Developer ID Application identity in the keychain.
  KREVO_NOTARY_PROFILE     Required notarytool keychain profile for public distribution.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"

if [[ -z "${KREVO_CODESIGN_IDENTITY:-}" ]]; then
  KREVO_CODESIGN_IDENTITY="$(find_developer_id_application)"
  export KREVO_CODESIGN_IDENTITY
fi

if [[ -z "${KREVO_CODESIGN_IDENTITY}" ]]; then
  echo "error: no Developer ID Application signing identity is installed on this Mac" >&2
  exit 1
fi

if [[ -z "${KREVO_NOTARY_PROFILE:-}" ]]; then
  echo "error: KREVO_NOTARY_PROFILE is required for public distribution" >&2
  exit 1
fi

"${SCRIPT_DIR}/export-app.sh" "${VERSION}"
"${SCRIPT_DIR}/package-dmg.sh" "${VERSION}"
"${SCRIPT_DIR}/verify-distribution.sh" "${VERSION}"
