#!/usr/bin/env bash
set -euo pipefail

# Count lines of Zig code in the project root and src/ folder.
# Uses cloc if available, falls back to a simple wc-based count.

ROOT="$(cd "$(dirname "$0")" && pwd)"

if command -v cloc &>/dev/null; then
    cloc --by-file --include-lang=Zig --not-match-d='_test\.zig$' \
         "$ROOT"/*.zig "$ROOT/src"
else
    echo "cloc not found; falling back to wc-based count"
    echo
    find "$ROOT" -maxdepth 1 -name '*.zig' -type f -print0 \
        | xargs -0 wc -l | sort -n
    echo
    find "$ROOT/src" -name '*.zig' -type f -print0 \
        | xargs -0 wc -l | sort -n
fi
