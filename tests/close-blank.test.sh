#!/usr/bin/env bash
# fcr resume --close-blank against a fixture fleet: which blank panes close,
# which stay, the dry run, and how a failed close is reported.
# jq filters are single-quoted on purpose throughout.
# shellcheck disable=SC2016
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

H="$TEST_TMP/fm"
H2="$TEST_TMP/fm-sm1"
make_home "$H"
make_home "$H2"
wt() { printf '%s/wt/%s' "$TEST_TMP" "$1"; }
export FAKE_CLAUDE_LOG="$TEST_TMP/claude.log"
export FAKE_CLAUDE_SLEEP=60
placement() {  # <workspace> <tab> <pane>
  printf 'herdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\nwindow=%s:%s\n' "$1" "$2" "$3" "$FAKE_HERDR_SESSION" "$3"
}

# w1:p1  primary's recorded pane, blank         kept (the primary's record)
# w1:p2  blank, named by a live task's meta     kept
# w1:p3  blank, a resumable task's pane         resumed into, then busy
# w1:p4  blank, named by a second mate's meta   kept
# w2:p1  blank, named by the second mate's task kept
# w1:p5  blank, unrecorded                      closed
# w1:p6  blank, unrecorded, alone in tab w1:t6  closed, and its tab with it
# w1:p7  running vim                            kept
# w1:p8  a shell, but Herdr reports an agent    kept
# w1:p9  blank, the pane fcr runs in            kept
herdr_state '{
  "next": 50,
  "workspaces": {"w1": {"label": "firstmate"}, "w2": {"label": "2ndmate-sm1"}},
  "tabs": {"w1:t1": {"ws": "w1", "label": "firstmate"}, "w1:t6": {"ws": "w1", "label": "6"},
           "w2:t1": {"ws": "w2", "label": "fm-c1"}},
  "panes": {"w1:p1": {"ws": "w1", "tab": "w1:t1", "cwd": "/", "fg": ["bash"]},
            "w1:p2": {"ws": "w1", "tab": "w1:t1", "cwd": "/", "fg": ["bash"]},
            "w1:p3": {"ws": "w1", "tab": "w1:t1", "cwd": "/", "fg": ["bash"]},
            "w1:p4": {"ws": "w1", "tab": "w1:t1", "cwd": "/", "fg": ["bash"]},
            "w2:p1": {"ws": "w2", "tab": "w2:t1", "cwd": "/", "fg": ["bash"]},
            "w1:p5": {"ws": "w1", "tab": "w1:t1", "cwd": "/", "fg": ["bash"]},
            "w1:p6": {"ws": "w1", "tab": "w1:t6", "cwd": "/", "fg": ["-zsh"]},
            "w1:p7": {"ws": "w1", "tab": "w1:t1", "cwd": "/", "fg": ["vim"]},
            "w1:p8": {"ws": "w1", "tab": "w1:t1", "cwd": "/", "fg": ["bash"], "agent": "codex"},
            "w1:p9": {"ws": "w1", "tab": "w1:t1", "cwd": "/", "fg": ["bash"]}}
}'

S_RES=$(new_uuid) S_PRI=$(new_uuid)
make_meta "$H" t-live harness=codex "$(placement w1 w1:t1 w1:p2)"
make_meta "$H" t-res "$(placement w1 w1:t1 w1:p3)"
make_record "$H" t-res "$S_RES" "$(wt t-res)" w1:p3 '["claude","--model","sonnet","go"]'
make_meta "$H" sm1 kind=secondmate "home=$H2" "$(placement w1 w1:t1 w1:p4)"
make_meta "$H2" c1 harness=codex "$(placement w2 w2:t1 w2:p1)"
make_record "$H" primary "$S_PRI" "$H" w1:p1 '["claude","--model","opus"]'
printf 'lock: held by live harness pid 4242\n' >"$H/lock-status"

panes() { jq -r '.panes | keys | join(" ")' "$FAKE_HERDR_DIR/state.json"; }
all_panes="w1:p1 w1:p2 w1:p3 w1:p4 w1:p5 w1:p6 w1:p7 w1:p8 w1:p9 w2:p1"

# --- without the flag nothing changes ----------------------------------------------
: >"$FAKE_HERDR_DIR/calls.log"
out=$(HERDR_PANE_ID=w1:p9 "$FCR" resume --home "$H" --dry-run 2>&1)
assert_eq "no flag: exits 0" 0 "$?"
assert_not_contains "no flag: no blank pane pass" "blank panes" "$out"
assert_not_contains "no flag: panes are never listed" "pane | list" "$(cat "$FAKE_HERDR_DIR/calls.log")"

# --- dry run lists only ---------------------------------------------------------------
: >"$FAKE_HERDR_DIR/calls.log"
out=$(HERDR_PANE_ID=w1:p9 "$FCR" resume --home "$H" --dry-run --close-blank 2>&1)
assert_eq "dry run: exits 0" 0 "$?"
assert_contains "dry run: lists the unrecorded blank pane" "would close   fm-test:w1:p5" "$out"
assert_contains "dry run: lists the blank pane alone in its tab" "would close   fm-test:w1:p6" "$out"
assert_eq "dry run: lists only those two" 2 "$(grep -c '^would close' <<<"$out")"
assert_contains "dry run: summary" "plan: 2 blank panes to close" "$out"
assert_not_contains "dry run: no close call" "close" "$(cat "$FAKE_HERDR_DIR/calls.log")"
assert_eq "dry run: every pane is still there" "$all_panes" "$(panes)"

# --- the real run -------------------------------------------------------------------------
: >"$FAKE_HERDR_DIR/calls.log"
out=$(HERDR_PANE_ID=w1:p9 "$FCR" resume --home "$H" --close-blank 2>&1)
rc=$?
assert_eq "close: exits 0" 0 "$rc"
assert_contains "close: the task is resumed first" "resumed       t-res" "$out"
assert_contains "close: blank and unrecorded is closed" "closed        fm-test:w1:p5" "$out"
assert_contains "close: the other unrecorded blank is closed" "closed        fm-test:w1:p6" "$out"
assert_eq "close: only the two blanks are gone" "w1:p1 w1:p2 w1:p3 w1:p4 w1:p7 w1:p8 w1:p9 w2:p1" "$(panes)"
assert_eq "close: a tab goes with its last pane" null "$(jq -c '.tabs["w1:t6"]' "$FAKE_HERDR_DIR/state.json")"
assert_eq "close: workspaces are never closed" '["w1","w2"]' "$(jq -c '.workspaces | keys' "$FAKE_HERDR_DIR/state.json")"
assert_contains "kept: blank but named by a live task" "kept          fm-test:w1:p2                named by task t-live" "$out"
assert_contains "kept: blank but named by a second mate" "kept          fm-test:w1:p4                named by task sm1" "$out"
assert_contains "kept: blank but named by a second mate's task" "kept          fm-test:w2:p1                named by task c1" "$out"
assert_contains "kept: the primary's recorded pane" "kept          fm-test:w1:p1                named by the primary's session record" "$out"
assert_contains "kept: the pane just resumed into" "kept          fm-test:w1:p3                named by task t-res" "$out"
assert_contains "kept: running a process" "kept          fm-test:w1:p7                running a process" "$out"
assert_contains "kept: Herdr reports an agent" "kept          fm-test:w1:p8                Herdr reports agent codex" "$out"
assert_contains "kept: fcr's own pane" "kept          fm-test:w1:p9                the pane fcr runs in" "$out"
assert_contains "close: summary" "blank panes: 2 closed, 8 kept, 0 failed" "$out"
assert_eq "close: each pane is closed alone, re-checked right before" \
  "fm-test:w1:p5 fm-test:w1:p6" \
  "$(grep '^pane | close' "$FAKE_HERDR_DIR/calls.log" | awk -F' [|] ' '{printf "%s:%s ", $5, $3}' | sed 's/ $//')"
check "close: the pane is read again between the listing and its close" \
  bash -c "awk '/^pane \\| list/ {l=1} l && /^pane \\| get \\| w1:p5/ {g++} /^pane \\| close \\| w1:p5/ {exit !(g >= 2)}' '$FAKE_HERDR_DIR/calls.log'"

# --- a failed close is reported but does not fail the resume ------------------------
jq '.panes["w1:p10"] = {ws: "w1", tab: "w1:t1", cwd: "/", fg: ["bash"]}' "$FAKE_HERDR_DIR/state.json" >"$TEST_TMP/s" &&
  mv "$TEST_TMP/s" "$FAKE_HERDR_DIR/state.json"
touch "$FAKE_HERDR_DIR/fail-close"
out=$(HERDR_PANE_ID=w1:p9 "$FCR" resume --home "$H" --close-blank 2>&1)
rc=$?
rm -f "$FAKE_HERDR_DIR/fail-close"
assert_eq "failed close: the exit status is the resume's" 0 "$rc"
assert_contains "failed close: reported per pane" "failed        fm-test:w1:p10               herdr pane close failed" "$out"
assert_contains "failed close: summary" "blank panes: 0 closed, 8 kept, 1 failed" "$out"

finish
