#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

echo "=== Building zig-cov ==="

# Clean previous build artifacts
zig build clean 2>/dev/null || true

# Build the project
zig build

echo "=== Build complete ==="
echo "Installed to: ./zig-out"
echo "Run: ./zig-out/bin/zig-cov --help"