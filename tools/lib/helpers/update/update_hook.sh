#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# Update hook
# Runs from tools/prod.sh update, after the images and before the stack.
#
# Holds every change a host needs for this tree, since 2.0.0. Each entry
# looks at this host and acts only when it has to: a host that skipped
# releases goes through all of them in one run, a new install passes
# them untouched. Entries stay here once added.
#
# Released versions call this path, it stays where it is.
# ──────────────────────────────────────────────────────────────────

set -euo pipefail
