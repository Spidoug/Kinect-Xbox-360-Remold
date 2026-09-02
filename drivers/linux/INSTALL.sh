#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Interactive desktop entry point: without arguments show the same control
# panel used after installation, including option 10 for SynKinect Studio.
# --direct preserves a scriptable install path for the menu and automation.
if [[ $# -eq 0 ]]; then
  exec "$ROOT/KINECT.sh"
fi
if [[ "${1:-}" == "--direct" ]]; then
  shift
fi
exec "$ROOT/source/scripts/install.sh" "$@"
