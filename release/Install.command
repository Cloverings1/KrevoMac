#!/bin/bash
#
# Krevo installer
#
# Double-click this file to install Krevo into /Applications.
# This removes macOS's download quarantine flag so Krevo will open
# without a "damaged / cannot be opened" warning, then copies the app
# into /Applications.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Krevo.app"
SRC_APP="${SCRIPT_DIR}/${APP_NAME}"
DEST_APP="/Applications/${APP_NAME}"

printf '\n\033[1mKrevo installer\033[0m\n\n'

if [[ ! -d "${SRC_APP}" ]]; then
  echo "error: could not find ${APP_NAME} next to this installer." >&2
  echo "Make sure you are running Install.command from the mounted Krevo disk image." >&2
  read -n 1 -s -r -p "Press any key to close..."
  exit 1
fi

echo "Copying ${APP_NAME} to /Applications..."
if [[ -d "${DEST_APP}" ]]; then
  rm -rf "${DEST_APP}"
fi
cp -R "${SRC_APP}" "${DEST_APP}"

echo "Clearing macOS quarantine flag..."
xattr -dr com.apple.quarantine "${DEST_APP}" 2>/dev/null || true
xattr -cr "${DEST_APP}" 2>/dev/null || true

echo "Launching Krevo..."
open "${DEST_APP}"

printf '\n\033[32mDone.\033[0m Krevo is now installed in /Applications.\n'
printf 'You can drag this disk image to the Trash and eject it.\n\n'
read -n 1 -s -r -t 5 -p "This window will close in a few seconds..." || true
echo
