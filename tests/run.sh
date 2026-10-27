#!/usr/bin/env bash
# tests/run.sh - run every tests/*.test.sh (or the given ones) and report.
# Hermetic: each test builds its own temp HOME, Claude config dir, firstmate
# homes and stub claude/herdr; nothing touches the real ones.
set -u
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ "$#" -gt 0 ] || set -- "$dir"/*.test.sh
failed=0
for t in "$@"; do
  printf '# %s\n' "${t##*/}"
  if ! bash "$t"; then
    failed=$((failed + 1))
  fi
done
if [ "$failed" -gt 0 ]; then
  printf '# %s test file(s) failed\n' "$failed"
  exit 1
fi
printf '# all test files passed\n'
