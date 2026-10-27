#!/usr/bin/env bash
# fcr resume against a fixture fleet: classification, placement, the meta
# rewrite, argv and env on relaunch, recursion and order, the primary, and
# failure reporting.
# jq filters are single-quoted on purpose throughout.
# shellcheck disable=SC2016
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

H="$TEST_TMP/fm"
H2="$TEST_TMP/fm-sm1"
make_home "$H"
make_home "$H2"
printf 'sm1\n' >"$H2/.fm-secondmate-home"
wt() { printf '%s/wt/%s' "$TEST_TMP" "$1"; }
export FAKE_CLAUDE_LOG="$TEST_TMP/claude.log"
export FAKE_CLAUDE_SLEEP=60

herdr_state '{
  "next": 50,
  "workspaces": {"w1": {"label": "firstmate"}, "w2": {"label": "2ndmate-sm1"}},
  "tabs": {"w1:t1": {"ws": "w1", "label": "firstmate"}, "w1:t2": {"ws": "w1", "label": "fm-t-reuse"},
           "w1:t3": {"ws": "w1", "label": "fm-t-busy"}, "w1:t4": {"ws": "w1", "label": "fm-sm1"},
           "w2:t1": {"ws": "w2", "label": "fm-c1"}},
  "panes": {"w1:p1": {"ws": "w1", "tab": "w1:t1", "cwd": "/", "fg": ["bash"]},
            "w1:p2": {"ws": "w1", "tab": "w1:t2", "cwd": "/", "fg": ["zsh"]},
            "w1:p3": {"ws": "w1", "tab": "w1:t3", "cwd": "/", "fg": ["vim"]},
            "w1:p4": {"ws": "w1", "tab": "w1:t4", "cwd": "/", "fg": ["bash"]},
            "w2:p1": {"ws": "w2", "tab": "w2:t1", "cwd": "/", "fg": ["bash"]}}
}'

std_argv() {  # <old-session-id>: a firstmate-shaped launch argv
  jq -cn --arg old "$1" '["claude", "--dangerously-skip-permissions", "--add-dir", "/a", "--add-dir", "/b",
    "--settings", "{\"feedbackDrafts\":\"off\"}", "--append-system-prompt", "You are a task worker.\nSecond line.",
    "--model", "sonnet", "--effort", "low", "--resume", $old, "--session-id=11111111-1111-1111-1111-111111111111",
    "-c", "the old restart prompt"]'
}
placement() {  # <id> <workspace> <tab> <pane>
  printf 'herdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\nwindow=%s:%s\n' "$2" "$3" "$4" "$FAKE_HERDR_SESSION" "$4"
}

# Root home tasks.
S_REUSE=$(new_uuid) S_BUSY=$(new_uuid) S_GONE=$(new_uuid) S_WSGONE=$(new_uuid) S_ATASK=$(new_uuid)
S_ASID=$(new_uuid) S_CWD=$(new_uuid) S_SM=$(new_uuid) S_C1=$(new_uuid) S_PRI=$(new_uuid) S_ARGV=$(new_uuid)
make_meta "$H" t-reuse "worktree=$(wt t-reuse)" $'endpoint_task_id=t-reuse\nherdr_workspace_id=w1\nherdr_tab_id=w1:t2\nherdr_pane_id=w1:p2\nwindow=fm-test:w1:p2'
make_record "$H" t-reuse "$S_REUSE" "$(wt t-reuse)" w1:p2 "$(std_argv "$(new_uuid)")" \
  "$(jq -cn --arg inbox "$H/state/t-reuse.inbox" '{FM_TASK_INBOX: $inbox, FM_TASK_ID: "t-reuse", GIT_CONFIG_COUNT: "1",
     GIT_CONFIG_KEY_0: "core.hooksPath", GIT_CONFIG_VALUE_0: "/hooks dir", COMPACT_ADVISER_DISABLE: "1",
     CLAUDE_CONFIG_DIR: "/cfg/it'"'"'s"}')"
make_meta "$H" t-busy "$(placement t-busy w1 w1:t3 w1:p3)"
make_record "$H" t-busy "$S_BUSY" "$(wt t-busy)" w1:p3 '["claude","--model","sonnet","go"]'
make_meta "$H" t-gone 'worktree=/somewhere' "$(placement t-gone w1 w1:t9 w1:p9)" 'branch=fm/t-gone' 'mode=no-mistakes'
make_record "$H" t-gone "$S_GONE" "$(wt t-gone)" w1:p9 '["claude","--model","sonnet","go"]'
make_meta "$H" t-wsgone "$(placement t-wsgone w7 w7:t1 w7:p1)"
make_record "$H" t-wsgone "$S_WSGONE" "$(wt t-wsgone)" w7:p1 '["claude","--model","sonnet","go"]'
make_meta "$H" t-atask "$(placement t-atask w1 w1:t1 w1:p1)"
make_record "$H" t-atask "$S_ATASK" "$(wt t-atask)" w1:p1 '["claude","go"]'
make_meta "$H" t-asid "$(placement t-asid w1 w1:t1 w1:p1)"
make_record "$H" t-asid "$S_ASID" "$(wt t-asid)" w1:p1 '["claude","go"]'
make_meta "$H" t-norec "$(placement t-norec w1 w1:t1 w1:p1)"
make_meta "$H" t-cwdgone "$(placement t-cwdgone w1 w1:t1 w1:p1)"
make_record "$H" t-cwdgone "$S_CWD" "$(wt t-cwdgone)" w1:p1 '["claude","go"]'
rmdir "$(wt t-cwdgone)"
make_meta "$H" t-codex harness=codex "$(placement t-codex w1 w1:t1 w1:p1)"
make_meta "$H" t-argv "$(placement t-argv w1 w1:t1 w1:p1)"
make_record "$H" t-argv "$S_ARGV" "$(wt t-argv)" w1:p1 \
  '["node","/opt/claude-code/cli.js","--model","opus","--debug","--","p1","p2"]'
# A second mate and its own worker.
make_meta "$H" sm1 kind=secondmate "home=$H2" "$(placement sm1 w1 w1:t4 w1:p4)"
make_record "$H" sm1 "$S_SM" "$H2" w1:p4 '["claude","--model","sonnet","Read AGENTS.md"]' \
  "$(jq -cn --arg h "$H2" '{FM_HOME: $h, FM_SUPERVISION_MODEL: "autoarm"}')"
make_meta "$H2" c1 "$(placement c1 w2 w2:t1 w2:p1)"
make_record "$H2" c1 "$S_C1" "$(wt c1)" w2:p1 '["claude","--model","sonnet","go"]'
# The primary.
make_record "$H" primary "$S_PRI" "$H" w1:p1 '["claude","--model","opus"]'

# Live sessions: one by task inbox (a fresh firstmate relaunch), one by id.
start_claude "FM_TASK_INBOX=$H/state/t-atask.inbox" -- --model sonnet 'fresh relaunch' >/dev/null
start_claude -- --resume "$S_ASID" >/dev/null
# A one-shot helper in a dead task's environment is not that task's agent.
start_claude "FM_TASK_INBOX=$H/state/t-reuse.inbox" -- -p 'supervision wake' >/dev/null
sleep 0.5

snapshot() { cat "$H"/state/*.meta "$H2"/state/*.meta | md5sum; }

# --- dry run ---------------------------------------------------------------------
before=$(snapshot)
claudes_before=$(wc -l <"$FAKE_CLAUDE_LOG")
: >"$FAKE_HERDR_DIR/calls.log"
out=$("$FCR" resume --home "$H" --dry-run --verbose 2>&1)
rc=$?
assert_eq "dry run exits 0" 0 "$rc"
assert_eq "dry run changes no meta" "$before" "$(snapshot)"
assert_not_contains "dry run makes no mutating herdr call" "run |" "$(cat "$FAKE_HERDR_DIR/calls.log")"
assert_not_contains "dry run creates nothing in herdr" "create" "$(cat "$FAKE_HERDR_DIR/calls.log")"
assert_eq "dry run starts no claude" "$claudes_before" "$(wc -l <"$FAKE_CLAUDE_LOG")"
assert_contains "dry run plans reuse of an idle pane" "would resume  t-reuse" "$out"
assert_contains "dry run plans a new tab when the pane is busy" "new tab of workspace fm-test:w1 (pane w1:p3 is busy)" "$out"
assert_contains "dry run plans a new tab when the pane is gone" "new tab of workspace fm-test:w1 (pane w1:p9 gone)" "$out"
assert_contains "dry run plans a new workspace when the workspace is gone" "new workspace of fm-test (workspace w7 gone)" "$out"
assert_contains "verbose shows the node-prefixed argv kept, prompt and -- tail dropped" \
  "cmd: node /opt/claude-code/cli.js --model opus --debug --resume $S_ARGV " "$out"
assert_contains "alive by task inbox" "alive         t-atask" "$out"
assert_contains "alive by session id" "alive         t-asid" "$out"
assert_contains "skip without a record" "skip          t-norec                      no session record" "$out"
assert_contains "skip when the folder is gone" "recorded folder is gone" "$out"
assert_contains "skip other harnesses" "harness codex (Claude only)" "$out"
assert_contains "the primary is planned when the lock is free" "would resume  primary" "$out"
order=$(printf '%s\n' "$out" | awk '$1 == "would" {print $3}' | tr '\n' ' ')
assert_eq "resume order: second mate, its tasks, the other tasks, primary last" \
  "sm1 sm1/c1 t-argv t-busy t-gone t-reuse t-wsgone primary " "$order"

# --- herdr never answers ----------------------------------------------------------
touch "$FAKE_HERDR_DIR/down"
out=$(FCR_HERDR_WAIT=1 "$FCR" resume --home "$H" 2>&1)
rc=$?
rm -f "$FAKE_HERDR_DIR/down"
assert_eq "herdr down: exit 2" 2 "$rc"
assert_contains "herdr down: clear message" "Herdr session fm-test did not answer within 1s" "$out"
assert_eq "herdr down: nothing changed" "$before" "$(snapshot)"

# --- real run, primary lock held ------------------------------------------------
printf 'lock: held by live harness pid 4242\n' >"$H/lock-status"
rm -rf "$(wt t-argv)"  # not launchable under the stub: skip it in the real run
: >"$FAKE_HERDR_DIR/calls.log"
out=$(FM_STRAY=leak CLAUDE_CODE_STRAY=leak "$FCR" resume --home "$H" 2>&1)
rc=$?
assert_eq "resume exits 0" 0 "$rc"
assert_contains "primary skipped while its lock is held" "alive         primary                      firstmate lock held by live harness pid 4242" "$out"
assert_contains "summary" "done: 6 resumed, 3 alive" "$out"
assert_eq "every herdr call passes --session explicitly" "" \
  "$(grep -v -- '| --session | fm-test$' "$FAKE_HERDR_DIR/calls.log")"
runs=$(cut -f1 "$FAKE_HERDR_DIR/runs.log" | tr '\n' ' ')
assert_contains "second mate launched before its child" "w1:p4 w2:p1 " "$runs"
assert_not_contains "alive tasks not launched again" "w1:p1" "$runs"

launched() {  # <session-id> <jq filter>: from the stub claude log
  jq -cs --arg sid "$1" "[.[] | select(any(.argv[]; . == \$sid))] | last | $2" "$FAKE_CLAUDE_LOG"
}
note_re='^\[firstmate-claude-resume\] The machine or the Herdr multiplexer restarted\. This is the same Claude session'
assert_eq "argv: options kept, old prompt and session selection dropped, --resume <id> added" \
  "$(jq -cn --arg s "$S_REUSE" '["--dangerously-skip-permissions","--add-dir","/a","--add-dir","/b","--settings",
     "{\"feedbackDrafts\":\"off\"}","--append-system-prompt","You are a task worker.\nSecond line.","--model","sonnet",
     "--effort","low","--resume",$s]')" "$(launched "$S_REUSE" '.argv[:-1]')"
note=$(launched "$S_REUSE" '.argv[-1]')
check "argv: the restart note is the new prompt" jq -en --argjson note "$note" --arg re "$note_re" '$note | test($re)'

assert_contains "note: background work did not survive" "background shell jobs, monitors, Workflows, subagents and any child processes" "$note"
assert_contains "note: resume Workflows from cache" "resumeFromRunId" "$note"
assert_eq "relaunch runs in the recorded cwd" "\"$(wt t-reuse)\"" "$(launched "$S_REUSE" .cwd)"
assert_eq "relaunch has the recorded env, exactly" \
  "$(jq -cn --arg inbox "$H/state/t-reuse.inbox" '{CLAUDE_CONFIG_DIR: "/cfg/it'"'"'s", COMPACT_ADVISER_DISABLE: "1",
     FM_TASK_ID: "t-reuse", FM_TASK_INBOX: $inbox, GIT_CONFIG_COUNT: "1", GIT_CONFIG_KEY_0: "core.hooksPath",
     GIT_CONFIG_VALUE_0: "/hooks dir"}')" "$(launched "$S_REUSE" '.env | to_entries | sort_by(.key) | from_entries')"
assert_eq "second mate relaunch env" "\"$H2\"" "$(launched "$S_SM" .env.FM_HOME)"

meta_val() { sed -n "s/^$2=//p" "$1/state/$3.meta"; }
assert_eq "reused pane: meta untouched" "w1:p2 fm-test:w1:p2" "$(meta_val "$H" herdr_pane_id t-reuse) $(meta_val "$H" window t-reuse)"
check "reused pane: the run went to the recorded pane" grep -q "^w1:p2	bash " "$FAKE_HERDR_DIR/runs.log"
busy_pane=$(meta_val "$H" herdr_pane_id t-busy)
assert_eq "busy pane: a new tab in the same workspace" "w1 fm-test:$busy_pane" "$(meta_val "$H" herdr_workspace_id t-busy) $(meta_val "$H" window t-busy)"
check "busy pane: the busy pane was left alone" bash -c "! grep -q '^w1:p3	' '$FAKE_HERDR_DIR/runs.log'"
assert_eq "new tab carries firstmate's label" '"fm-t-busy"' "$(jq --arg t "$(meta_val "$H" herdr_tab_id t-busy)" '.tabs[$t].label' "$FAKE_HERDR_DIR/state.json")"
gone_pane=$(meta_val "$H" herdr_pane_id t-gone)
gone_tab=$(meta_val "$H" herdr_tab_id t-gone)
assert_eq "gone pane: the meta rewrite changes only the four placement keys, in place" \
  "harness=claude
kind=ship
backend=herdr
herdr_session=fm-test
model=sonnet
effort=low
worktree=/somewhere
herdr_workspace_id=w1
herdr_tab_id=$gone_tab
herdr_pane_id=$gone_pane
window=fm-test:$gone_pane
branch=fm/t-gone
mode=no-mistakes" "$(cat "$H/state/t-gone.meta")"
check "gone pane: new pane is in the herdr state" jq -e --arg p "$gone_pane" '.panes[$p].ws == "w1"' "$FAKE_HERDR_DIR/state.json"
check "meta rewrite leaves no temp file" bash -c "! ls -A '$H/state' | grep -q fcr"
ws_new=$(meta_val "$H" herdr_workspace_id t-wsgone)
assert_eq "gone workspace: a new workspace labeled for the task, never the home label" '"fm-t-wsgone"' "$(jq --arg w "$ws_new" '.workspaces[$w].label' "$FAKE_HERDR_DIR/state.json")"
assert_eq "gone workspace: meta points at its pane" "fm-test:$(meta_val "$H" herdr_pane_id t-wsgone)" "$(meta_val "$H" window t-wsgone)"
assert_eq "second mate's child resumed in its own pane" "w2:p1" "$(meta_val "$H2" herdr_pane_id c1)"
launcher_dir="$XDG_STATE_HOME/firstmate-claude-resume/launch"
assert_eq "launchers are private" 700 "$(stat -c %a "$launcher_dir")"

# --- rerun: everything alive, nothing doubled ----------------------------------------
runs_before=$(wc -l <"$FAKE_HERDR_DIR/runs.log")
out=$("$FCR" resume --home "$H" 2>&1)
assert_eq "rerun exits 0" 0 "$?"
assert_contains "rerun: all resumed sessions are alive" "done: 0 resumed, 9 alive" "$out"
assert_eq "rerun launches nothing" "$runs_before" "$(wc -l <"$FAKE_HERDR_DIR/runs.log")"

# --- the primary once its lock is free --------------------------------------------------
rm -f "$H/lock-status"
out=$("$FCR" resume --home "$H" --only primary 2>&1)
assert_eq "--only primary exits 0" 0 "$?"
assert_contains "primary resumed in its recorded pane" "resumed       primary                      session $S_PRI in its pane fm-test:w1:p1" "$out"
assert_eq "--only touched nothing else" "$((runs_before + 1))" "$(wc -l <"$FAKE_HERDR_DIR/runs.log")"
assert_eq "primary relaunched in the home root" "\"$H\"" "$(launched "$S_PRI" .cwd)"

# --- failures ---------------------------------------------------------------------------
S_FAIL=$(new_uuid)
make_meta "$H" t-fail "$(placement t-fail w1 w1:t2 w1:p2)"
make_record "$H" t-fail "$S_FAIL" "$(wt t-fail)" w1:p2 '["claude","go"]'
jq '.panes["w1:p2"].fg = ["bash"]' "$FAKE_HERDR_DIR/state.json" >"$TEST_TMP/s" && mv "$TEST_TMP/s" "$FAKE_HERDR_DIR/state.json"
touch "$FAKE_HERDR_DIR/fail-run"
out=$("$FCR" resume --home "$H" --only t-fail 2>&1)
rc=$?
rm -f "$FAKE_HERDR_DIR/fail-run"
assert_eq "a failed resume exits 1" 1 "$rc"
assert_contains "the failure is reported per task" "failed        t-fail                       herdr pane run failed in fm-test:w1:p2" "$out"
out=$("$FCR" resume --home "$H" --only nope 2>&1)
assert_eq "--only with an unknown task exits 2" 2 "$?"
out=$("$FCR" resume --home "$TEST_TMP/missing" 2>&1)
assert_eq "a missing home exits 2" 2 "$?"

finish
