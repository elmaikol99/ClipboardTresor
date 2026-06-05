#!/usr/bin/env bash
set -euo pipefail

defaults delete local.clipboardarchiv.app ArchiveParentPath 2>/dev/null || true

cat <<'EOF'
Archive folder setting reset.

ClipboardArchiv will use the default location again:
  ~/Documents/ClipboardArchiv

Restart ClipboardArchiv for the change to take effect.
EOF
