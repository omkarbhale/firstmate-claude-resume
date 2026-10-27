#!/usr/bin/env bash
# lint.sh - shellcheck every shell file in the repository.
set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"
command -v shellcheck >/dev/null 2>&1 || { echo "lint.sh: shellcheck is required" >&2; exit 1; }
shellcheck -x --norc bin/fcr bin/fcr-session-hook install.sh uninstall.sh lint.sh lib/settings.sh \
  tests/run.sh tests/lib.sh tests/*.test.sh tests/stubs/claude tests/stubs/herdr
echo "shellcheck clean"
