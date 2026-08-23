#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
JAVA="$HERE/java/bin/java"
if [[ ! -x "$JAVA" ]]; then
  JAVA="$(command -v java || true)"
fi
if [[ -z "$JAVA" ]]; then
  echo "Java 17 or newer was not found." >&2
  exit 1
fi
exec "$JAVA" -cp "$HERE/SynKinectStudio.jar:$HERE/lib/*" SynKinectStudio "$@"
