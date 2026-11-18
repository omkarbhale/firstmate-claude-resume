#!/usr/bin/env bash
# A firstmate primary hosted as a Claude background session (`claude daemon`):
# its process tree is claude bg-pty-host ... -- <share>/claude/versions/<x.y.z>,
# where the session's comm and argv[0] are the version, not "claude".
# fcr must see such a session as alive, and resume a recorded one as plain claude.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

H="$TEST_TMP/fm"
make_home "$H"
export FAKE_CLAUDE_LOG="$TEST_TMP/claude.log"
export FAKE_CLAUDE_SLEEP=60
share="$TEST_TMP/share/claude/versions"
mkdir -p "$share"
cp "$TEST_TMP/bin/claude" "$share/2.1.310"

herdr_state '{
  "next": 50,
  "workspaces": {"w1": {"label": "firstmate"}},
  "tabs": {"w1:t1": {"ws": "w1", "label": "firstmate"}},
  "panes": {"w1:p1": {"ws": "w1", "tab": "w1:t1", "cwd": "/", "fg": ["bash"]}}
}'

# Two tasks whose sessions are live, found by id: one hosted in the background
# layout, one that is only the versioned binary (the process under the wrapper).
S_TASK=$(new_uuid) S_BARE=$(new_uuid)
make_meta "$H" t-bg "herdr_workspace_id=w1" "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p1"
make_record "$H" t-bg "$S_TASK" "$TEST_TMP/wt/t-bg" w1:p1 '["claude","--model","sonnet"]'
claude bg-pty-host --bg-pty-host "$TEST_TMP/bg.sock" 165 46 -- "$share/2.1.310" --session-id "$S_TASK" \
  --permission-mode bypassPermissions >/dev/null 2>&1 &
TEST_PIDS+=("$!")
make_meta "$H" t-bare "herdr_workspace_id=w1" "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p1"
make_record "$H" t-bare "$S_BARE" "$TEST_TMP/wt/t-bare" w1:p1 '["claude","--model","sonnet"]'
"$share/2.1.310" --session-id "$S_BARE" --permission-mode bypassPermissions >/dev/null 2>&1 &
TEST_PIDS+=("$!")

# The primary: recorded the way the hook records a background session, not live.
S_PRI=$(new_uuid)
make_record "$H" primary "$S_PRI" "$H" w1:p1 '["claude","--permission-mode","bypassPermissions","--session-id","x"]'
sleep 0.5

out=$("$FCR" resume --home "$H" --dry-run --verbose 2>&1)
assert_contains "a live background session is alive, found by its session id" "alive         t-bg " "$out"
assert_contains "the versioned binary alone is alive" "alive         t-bare" "$out"
assert_contains "the recorded background primary is planned as a plain claude resume" \
  "cmd: claude --permission-mode bypassPermissions --resume $S_PRI" "$out"

finish
