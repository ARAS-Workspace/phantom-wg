#!/usr/bin/env bash
# Run clippy inside dev container: every target, undocumented unsafe blocks
# included, every warning an error
# Usage: dev/clippy.sh
#        dev/clippy.sh --release
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec "${SCRIPT_DIR}/cargo.sh" clippy --all-targets "$@" -- \
    -W clippy::undocumented_unsafe_blocks -D warnings
