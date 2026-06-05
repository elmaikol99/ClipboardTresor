#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  cat >&2 <<'USAGE'
Usage:
  ./configure-archive-folder.sh /path/to/parent-folder

Example:
  ./configure-archive-folder.sh "$HOME/Documents"

ClipboardArchiv will create/use:
  /path/to/parent-folder/ClipboardArchiv
USAGE
  exit 1
fi

PARENT_PATH="$1"
case "$PARENT_PATH" in
  "~")
    PARENT_PATH="$HOME"
    ;;
  "~/"*)
    PARENT_PATH="$HOME/${PARENT_PATH#"~/"}"
    ;;
esac

mkdir -p "$PARENT_PATH"
EXPANDED_PARENT="$(cd "$PARENT_PATH" && pwd)"
defaults write local.clipboardarchiv.app ArchiveParentPath "$EXPANDED_PARENT"

cat <<EOF
Archive parent folder set to:
  $EXPANDED_PARENT

ClipboardArchiv will use:
  $EXPANDED_PARENT/ClipboardArchiv

Restart ClipboardArchiv for the change to take effect.
EOF
