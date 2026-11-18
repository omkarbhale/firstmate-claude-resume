#!/usr/bin/env bash
# The launch environment end to end: a record the hook wrote (whole environment
# minus credentials) is relaunched with exactly that environment, while the pane
# shell's own variables, including its copy of a withheld credential, behave as
# documented. An older allowlist record keeps resetting only its allowlisted names.
# jq filters are single-quoted on purpose throughout.
# shellcheck disable=SC2016
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

H="$TEST_TMP/fm"
make_home "$H"
wt() { printf '%s/wt/%s' "$TEST_TMP" "$1"; }
export FAKE_CLAUDE_LOG="$TEST_TMP/claude.log"
export FAKE_CLAUDE_SLEEP=60 FAKE_CLAUDE_ENV_ALL=1
export FAKE_CLAUDE_HOOK="$HOOK"
: >"$FAKE_CLAUDE_LOG"

herdr_state '{
  "next": 50,
  "workspaces": {"w1": {"label": "firstmate"}},
  "tabs": {"w1:t1": {"ws": "w1", "label": "firstmate"}, "w1:t2": {"ws": "w1", "label": "fm-t-old"}},
  "panes": {"w1:p1": {"ws": "w1", "tab": "w1:t1", "cwd": "/", "fg": ["bash"]},
            "w1:p2": {"ws": "w1", "tab": "w1:t2", "cwd": "/", "fg": ["bash"]}}
}'
launched() {  # <session-id> <jq filter>
  jq -cs --arg sid "$1" "[.[] | select(any(.argv[]; . == \$sid))] | last | $2" "$FAKE_CLAUDE_LOG"
}

# --- a full-scope record, written by the real hook from a real launch ---------------
make_meta "$H" t-full 'herdr_workspace_id=w1' 'herdr_tab_id=w1:t1' 'herdr_pane_id=w1:p1' 'window=fm-test:w1:p1'
mkdir -p "$(wt t-full)"
S_FULL=$(new_uuid)
(cd "$(wt t-full)" && env -i PATH="$PATH" HOME="$HOME" FM_TASK_INBOX="$H/state/t-full.inbox" FM_TASK_ID=t-full \
  ODD_SETTING="it's a \"quoted\" value" EMPTY_VAR= MULTI=$'line1\nline2' TERM=xterm-256color LANG=C.UTF-8 \
  RUNTIME_THING=kept GITHUB_TOKEN=session-secret ANTHROPIC_API_KEY=session-key \
  HERDR_PANE_ID=w9:p9 HERDR_SESSION=old-session CLAUDE_CODE_SESSION_ID=stale-id \
  FAKE_CLAUDE_SESSION_ID="$S_FULL" FAKE_CLAUDE_SLEEP=0 FAKE_CLAUDE_HOOK="$HOOK" FAKE_CLAUDE_ENV_ALL=1 \
  FAKE_CLAUDE_LOG="$FAKE_CLAUDE_LOG" \
  claude --model sonnet 'first prompt')
rec="$H/state/t-full.claude-session"
check "the hook wrote a full-scope record" jq -e '.env_scope == "full"' "$rec"
assert_not_contains "no credential value in the record" session-secret "$(cat "$rec")"
assert_not_contains "no credential value in the record (2)" session-key "$(cat "$rec")"
# Re-point the record at the fixture pane and transcript, and let the relaunched
# stub stay alive (the first launch above ran it with FAKE_CLAUDE_SLEEP=0).
jq --arg tp "$TEST_TMP/transcripts/$S_FULL.jsonl" '.herdr.pane_id = "w1:p2" | .herdr.workspace_id = "w1" | .herdr.tab_id = "w1:t2"
  | .herdr.session = "fm-test" | .transcript_path = $tp | .env.FAKE_CLAUDE_SLEEP = "60"' "$rec" >"$TEST_TMP/r" && mv "$TEST_TMP/r" "$rec"
make_meta "$H" t-full 'herdr_workspace_id=w1' 'herdr_tab_id=w1:t2' 'herdr_pane_id=w1:p2' 'window=fm-test:w1:p2'
mkdir -p "$TEST_TMP/transcripts"
transcript "$S_FULL" "$T_PROMPT" "$T_TOOL_USE"

# The pane shell (the stub herdr runs the launcher in fcr's own environment)
# holds: a credential of its own, a variable the session never had, a stale
# FM_ name, and CLAUDECODE.
out=$(PANE_ONLY_VAR=leak GITHUB_TOKEN=pane-token FM_STRAY=leak CLAUDE_CODE_STRAY=leak CLAUDECODE=1 \
  "$FCR" resume --home "$H" --only t-full 2>&1)
assert_eq "resume exits 0" 0 "$?"
assert_contains "resumed" "resumed       t-full" "$out"
envs() { launched "$S_FULL" ".env_all | $1"; }
assert_eq "recorded values come back exactly (quotes, empty, multi-line)" \
  "$(jq -cn --arg i "$H/state/t-full.inbox" '["it'"'"'s a \"quoted\" value", "", "line1\nline2", "t-full", $i, "kept", "xterm-256color", "C.UTF-8"]')" \
  "$(envs '[.ODD_SETTING, .EMPTY_VAR, .MULTI, .FM_TASK_ID, .FM_TASK_INBOX, .RUNTIME_THING, .TERM, .LANG]')"
assert_eq "recorded PATH and HOME come back" "\"$PATH\" \"$HOME\"" "$(envs '.PATH') $(envs '.HOME')"
assert_eq "the pane shell's variables the session never had are gone" true \
  "$(envs '[.PANE_ONLY_VAR, .FM_STRAY, .CLAUDE_CODE_STRAY, .CLAUDECODE] | all(. == null)')"
assert_eq "the pane's own copy of a withheld credential is kept" '"pane-token"' "$(envs .GITHUB_TOKEN)"
assert_eq "a credential only the old session had is not invented" null "$(envs .ANTHROPIC_API_KEY)"
assert_eq "the pane's HERDR_* placement is kept, not the old pane's" '"w1:p2"' "$(envs .HERDR_PANE_ID)"
assert_eq "the stale per-process name is not restored" null "$(envs .CLAUDE_CODE_SESSION_ID)"

# --- an older allowlist record keeps the old, narrower behaviour ----------------------
make_meta "$H" t-old 'herdr_workspace_id=w1' 'herdr_tab_id=w1:t1' 'herdr_pane_id=w1:p1' 'window=fm-test:w1:p1'
S_OLD=$(new_uuid)
make_record "$H" t-old "$S_OLD" "$(wt t-old)" w1:p1 '["claude","--model","sonnet","go"]' \
  "$(jq -cn --arg l "$FAKE_CLAUDE_LOG" '{FM_TASK_ID: "t-old", COMPACT_ADVISER_DISABLE: "1", FAKE_CLAUDE_LOG: $l}')"
transcript "$S_OLD" "$T_PROMPT" "$T_TOOL_USE"
out=$(PANE_ONLY_VAR=keep-me FM_STRAY=gone "$FCR" resume --home "$H" --only t-old 2>&1)
assert_eq "old record: resume exits 0" 0 "$?"
oenv() { launched "$S_OLD" ".env_all | $1"; }
assert_eq "old record: only the allowlisted names are reset and set" '"t-old" null' "$(oenv .FM_TASK_ID) $(oenv .FM_STRAY)"
assert_eq "old record: the pane's other variables survive" '"keep-me"' "$(oenv .PANE_ONLY_VAR)"

# --- the hook and the launcher agree on the names the pane keeps -----------------------
hook_skip=$(sed -n "s/^FCR_ENV_SKIP='\(.*\)'$/\1/p" "$HOOK")
check "the hook skips every pane name the launcher keeps" bash -c "
  for n in HERDR_PANE_ID HERDR_SESSION PWD OLDPWD SHLVL _ SHELLOPTS BASHOPTS; do
    printf '%s\n' \"\$n\" | grep -Eq '$hook_skip' || { echo \"not skipped: \$n\" >&2; exit 1; }
  done"

finish
