#!/usr/bin/env bash
# tests/lib.sh - shared helpers for the hermetic tests. Source it from a
# tests/*.test.sh file.
#
# Every test runs under a fresh temp root with HOME, CLAUDE_CONFIG_DIR and
# XDG_STATE_HOME pointing inside it, the stub claude and herdr first on PATH,
# and no firstmate or Herdr variables from the calling session, so nothing
# can reach a real ~/.claude, ~/firstmate or Herdr server.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Used by the sourcing test files.
# shellcheck disable=SC2034
FCR="$ROOT/bin/fcr"
# shellcheck disable=SC2034
HOOK="$ROOT/bin/fcr-session-hook"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fcr-test.XXXXXX")
TEST_PIDS=()
test_cleanup() {
  local pid
  for pid in ${TEST_PIDS[@]+"${TEST_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  # Stub claudes started through the stub herdr's `pane run`.
  pkill -TERM -f "$TEST_TMP" 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap test_cleanup EXIT

while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(FM_|HERDR_|CLAUDE|GIT_CONFIG_|COMPACT_ADVISER_DISABLE$|LAVISH_AXI_HOST$|DISABLE_AUTOUPDATER$|FCR_)')
export HOME="$TEST_TMP/home"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME" "$TEST_TMP/bin"
cp "$ROOT/tests/stubs/claude" "$ROOT/tests/stubs/herdr" "$TEST_TMP/bin/"
export PATH="$TEST_TMP/bin:$PATH"
export FAKE_HERDR_DIR="$TEST_TMP/herdr"
export FAKE_HERDR_SESSION=fm-test
export FCR_HERDR_WAIT=2 FCR_LAUNCH_WAIT=5
mkdir -p "$FAKE_HERDR_DIR"

TEST_COUNT=0
TEST_FAILED=0
pass() { TEST_COUNT=$((TEST_COUNT + 1)); printf 'ok %s - %s\n' "$TEST_COUNT" "$1"; }
fail() { TEST_COUNT=$((TEST_COUNT + 1)); TEST_FAILED=$((TEST_FAILED + 1)); printf 'not ok %s - %s\n' "$TEST_COUNT" "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/#   /'; }
check() {  # <description> <command...>
  local desc=$1
  shift
  if "$@" >/dev/null; then pass "$desc"; else fail "$desc"; fi
}
assert_eq() {  # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected: $2
actual:   $3"; fi
}
assert_contains() {  # <description> <needle> <haystack>
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "missing: $2
in: $3" ;; esac
}
assert_not_contains() {  # <description> <needle> <haystack>
  case "$3" in *"$2"*) fail "$1" "unexpected: $2
in: $3" ;; *) pass "$1" ;; esac
}
finish() {
  printf '1..%s\n' "$TEST_COUNT"
  [ "$TEST_FAILED" = 0 ] || { printf '# %s of %s failed\n' "$TEST_FAILED" "$TEST_COUNT"; exit 1; }
}

new_uuid() { cat /proc/sys/kernel/random/uuid; }

# make_home <dir>: a fixture firstmate home with a stub bin/fm-lock.sh whose
# status line is read from <dir>/lock-status (default "lock: free").
make_home() {
  local home=$1
  mkdir -p "$home/state" "$home/bin"
  cat >"$home/bin/fm-lock.sh" <<'EOF'
#!/usr/bin/env bash
home=$(cd "$(dirname "$0")/.." && pwd)
[ "${1:-}" = status ] || exit 1
[ "$FM_HOME" = "$home" ] || { echo "lock: wrong FM_HOME $FM_HOME"; exit 0; }
cat "$home/lock-status" 2>/dev/null || echo "lock: free"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' >"$home/bin/fm-spawn.sh"
  chmod +x "$home/bin/fm-lock.sh" "$home/bin/fm-spawn.sh"
}

# make_meta <home> <id> <key=value>...: write state/<id>.meta with Claude and
# Herdr defaults, then the given lines.
make_meta() {
  local home=$1 id=$2
  shift 2
  {
    printf 'harness=claude\nkind=ship\nbackend=herdr\nherdr_session=%s\nmodel=sonnet\neffort=low\n' "$FAKE_HERDR_SESSION"
    printf '%s\n' "$@"
  } >"$home/state/$id.meta"
}

# make_record <home> <id|primary> <session-id> <cwd> <pane> <argv-json> [env-json]:
# a session record as fcr-session-hook writes it, with a transcript file.
make_record() {
  local home=$1 id=$2 sid=$3 cwd=$4 pane=$5 argv=$6 env=${7:-'{}'} file kind=task
  file="$home/state/$id.claude-session"
  if [ "$id" = primary ]; then file="$home/state/.primary-claude-session"; kind=primary; id=''; fi
  mkdir -p "$cwd" "$TEST_TMP/transcripts"
  : >"$TEST_TMP/transcripts/$sid.jsonl"
  jq -n --arg kind "$kind" --arg id "$id" --arg state "$home/state" --arg sid "$sid" --arg cwd "$cwd" \
    --arg tp "$TEST_TMP/transcripts/$sid.jsonl" --arg hs "$FAKE_HERDR_SESSION" --arg pane "$pane" \
    --argjson argv "$argv" --argjson env "$env" '
    {format: 1, kind: $kind, task_id: $id, state_dir: $state, session_id: $sid, source: "startup",
     cwd: $cwd, transcript_path: $tp, captured_at: "2026-10-27T00:00:00Z", captured_epoch: 0,
     herdr: {session: $hs, workspace_id: ($pane | split(":")[0]), tab_id: "", pane_id: $pane},
     claude_pid: 1, argv: $argv, env: $env}' >"$file"
}

# herdr_state <json>: replace the stub herdr's whole state.
herdr_state() { printf '%s\n' "$1" >"$FAKE_HERDR_DIR/state.json"; }

# start_claude <env assignments...> -- <args...>: a long-lived stub claude in
# the background; prints its pid.
start_claude() {
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env ${envs[@]+"${envs[@]}"} FAKE_CLAUDE_SLEEP=60 claude "$@" >/dev/null 2>&1 &
  TEST_PIDS+=("$!")
  printf '%s' "$!"
}
