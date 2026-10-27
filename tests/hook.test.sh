#!/usr/bin/env bash
# The SessionStart recorder: where it writes, what it records, and what it skips.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

home="$TEST_TMP/fm"
make_home "$home"
wt="$TEST_TMP/worktrees/t1"
mkdir -p "$wt"
export FAKE_CLAUDE_HOOK="$HOOK"
export FAKE_CLAUDE_HOOK_RC="$TEST_TMP/hook-rc"
record="$home/state/t1.claude-session"

# --- task record --------------------------------------------------------------
sid=$(new_uuid)
(
  cd "$wt" &&
    env FM_TASK_INBOX="$home/state/t1.inbox" FM_TASK_ID=t1 COMPACT_ADVISER_DISABLE=1 \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/hooks \
      LAVISH_AXI_HOST=127.0.0.1 CLAUDE_CONFIG_DIR="$HOME/.claude-alt" DISABLE_AUTOUPDATER=1 \
      CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_OAUTH_TOKEN=secret-oauth \
      ANTHROPIC_API_KEY=secret-key FM_GITHUB_TOKEN=secret-gh OTHER_VAR=nope \
      HERDR_SESSION=fm-test HERDR_WORKSPACE_ID=w3 HERDR_TAB_ID=w3:t2 HERDR_PANE_ID=w3:p2 \
      FAKE_CLAUDE_SESSION_ID="$sid" \
      claude --dangerously-skip-permissions --settings '{"a":{"b":"c d"}}' --model sonnet \
      --append-system-prompt $'multi\nline prompt' 'the original prompt'
)
check "task record written at state/<task-id>.claude-session" test -f "$record"
assert_eq "hook exits 0" 0 "$(tail -n 1 "$FAKE_CLAUDE_HOOK_RC")"
assert_eq "record names the session id" "$sid" "$(jq -r .session_id "$record")"
assert_eq "record kind is task" "task t1" "$(jq -r '"\(.kind) \(.task_id)"' "$record")"
assert_eq "record cwd" "$wt" "$(jq -r .cwd "$record")"
assert_eq "record source" startup "$(jq -r .source "$record")"
assert_eq "record transcript path" "$wt/$sid.jsonl" "$(jq -r .transcript_path "$record")"
assert_eq "record herdr placement" "fm-test w3 w3:t2 w3:p2" \
  "$(jq -r '.herdr | "\(.session) \(.workspace_id) \(.tab_id) \(.pane_id)"' "$record")"
check "record has a capture timestamp" jq -e '.captured_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$record"
expected_argv=$(jq -cn --arg c "$TEST_TMP/bin/claude" '[$c, "--dangerously-skip-permissions", "--settings", "{\"a\":{\"b\":\"c d\"}}",
  "--model", "sonnet", "--append-system-prompt", "multi\nline prompt", "the original prompt"]')
assert_eq "record argv is the exact launch argv from /proc" "$expected_argv" "$(jq -c .argv "$record")"
assert_eq "record env keeps exactly the allowlisted names" \
  "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_CONFIG_DIR COMPACT_ADVISER_DISABLE DISABLE_AUTOUPDATER FM_TASK_ID FM_TASK_INBOX GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 LAVISH_AXI_HOST" \
  "$(jq -r '.env | keys | join(" ")' "$record")"
assert_eq "record env values" "/hooks|$HOME/.claude-alt" "$(jq -r '"\(.env.GIT_CONFIG_VALUE_0)|\(.env.CLAUDE_CONFIG_DIR)"' "$record")"
assert_not_contains "no secret value is recorded" secret "$(cat "$record")"
check "no temp file is left behind" bash -c "! ls -A '$home/state' | grep -q tmp"
assert_eq "record is private" 600 "$(stat -c %a "$record")"

# --- rewritten on resume / clear ---------------------------------------------
sid2=$(new_uuid)
(cd "$wt" && FM_TASK_INBOX="$home/state/t1.inbox" claude --resume "$sid2" --model sonnet 'note')
assert_eq "a later session start rewrites the record with the current id" "$sid2" "$(jq -r .session_id "$record")"
assert_eq "resume source is recorded" resume "$(jq -r .source "$record")"
assert_eq "the replaced id is kept in previous_sessions, newest first" "$sid startup" \
  "$(jq -r '.previous_sessions[0] | "\(.session_id) \(.source)"' "$record")"
(cd "$wt" && FM_TASK_INBOX="$home/state/t1.inbox" claude --resume "$sid2" --model sonnet 'note')
assert_eq "restarting the same session adds no previous entry" 1 "$(jq '.previous_sessions | length' "$record")"

# --- nested and --print sessions are skipped ----------------------------------
before=$(cat "$record")
(cd "$wt" && FM_TASK_INBOX="$home/state/t1.inbox" claude -p 'one shot')
assert_eq "--print session does not touch the record" "$before" "$(cat "$record")"
(cd "$wt" && FM_TASK_INBOX="$home/state/t1.inbox" CLAUDECODE=1 claude --model sonnet 'x')
assert_eq "a nested claude (CLAUDECODE=1 at launch) does not touch the record" "$before" "$(cat "$record")"
# The nested child must have been the only hook run: prove the parent would record.
sid3=$(new_uuid)
(cd "$wt" && FM_TASK_INBOX="$home/state/t1.inbox" FAKE_CLAUDE_CHILD=1 FAKE_CLAUDE_SESSION_ID="$sid3" claude --model sonnet 'x')
assert_eq "the parent of a nested claude still records itself" "$sid3" "$(jq -r .session_id "$record")"

# --- primary --------------------------------------------------------------------
psid=$(new_uuid)
(cd "$home" && HERDR_SOCKET_PATH="$HOME/.config/herdr/sessions/fm-lab-x/herdr.sock" HERDR_PANE_ID=w1:p1 \
  FAKE_CLAUDE_SESSION_ID="$psid" claude)
check "primary record written when cwd is a firstmate home root" test -f "$home/state/.primary-claude-session"
assert_eq "primary record session id" "$psid" "$(jq -r .session_id "$home/state/.primary-claude-session")"
assert_eq "herdr session derived from the socket path" fm-lab-x "$(jq -r .herdr.session "$home/state/.primary-claude-session")"
(cd "$home" && HERDR_SOCKET_PATH="$HOME/.config/herdr/herdr.sock" HERDR_PANE_ID=w1:p1 claude)
assert_eq "default socket path means the default session" default "$(jq -r .herdr.session "$home/state/.primary-claude-session")"

# --- not firstmate ----------------------------------------------------------------
other="$TEST_TMP/elsewhere"
mkdir -p "$other"
(cd "$other" && claude 'hi')
check "a non-firstmate session writes nothing" bash -c "[ -z \"\$(find '$TEST_TMP' -name '*.claude-session' -newer '$record' -not -path '$home/*')\" ]"
check "nothing written in a non-firstmate cwd" bash -c "[ -z \"\$(ls -A '$other')\" ]"

# --- robustness ---------------------------------------------------------------------
out=$(printf 'not json' | FM_TASK_INBOX="$home/state/t1.inbox" "$HOOK" 2>&1; echo "rc=$?")
assert_eq "garbage stdin: silent, exit 0" "rc=0" "$out"
out=$(: | FM_TASK_INBOX="$home/state/t1.inbox" "$HOOK" 2>&1; echo "rc=$?")
assert_eq "empty stdin: silent, exit 0" "rc=0" "$out"
out=$(printf '{"session_id":"x","cwd":"/"}' | FM_TASK_INBOX="/nonexistent/state/t9.inbox" "$HOOK" 2>&1; echo "rc=$?")
assert_eq "missing state dir: silent, exit 0" "rc=0" "$out"
start=$(date +%s%N)
printf '{"session_id":"%s","cwd":"%s"}' "$(new_uuid)" "$wt" | FM_TASK_INBOX="$home/state/t1.inbox" "$HOOK"
elapsed_ms=$((($(date +%s%N) - start) / 1000000))
check "hook finishes quickly (${elapsed_ms}ms)" test "$elapsed_ms" -lt 2000

finish
