#!/usr/bin/env bash
# The restart note: sent only to a session that was working when it stopped,
# read from its transcript; --no-prompt sends it to none, --prompt to all.
# jq filters are single-quoted on purpose throughout.
# shellcheck disable=SC2016
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

H="$TEST_TMP/fm"
make_home "$H"
wt() { printf '%s/wt/%s' "$TEST_TMP" "$1"; }
export FAKE_CLAUDE_LOG="$TEST_TMP/claude.log"
export FAKE_CLAUDE_SLEEP=60
: >"$FAKE_CLAUDE_LOG"

herdr_state '{
  "next": 50,
  "workspaces": {"w1": {"label": "firstmate"}},
  "tabs": {"w1:t1": {"ws": "w1", "label": "firstmate"}},
  "panes": {"w1:p1": {"ws": "w1", "tab": "w1:t1", "cwd": "/", "fg": ["bash"]}}
}'

declare -A SID
task() {  # <id> <transcript line>...: a resumable task with that transcript
  local id=$1
  shift
  SID[$id]=$(new_uuid)
  make_meta "$H" "$id" 'herdr_workspace_id=w1' 'herdr_tab_id=w1:t1' 'herdr_pane_id=w1:p1' 'window=fm-test:w1:p1'
  make_record "$H" "$id" "${SID[$id]}" "$(wt "$id")" w1:p1 '["claude","--model","sonnet","go"]'
  transcript "${SID[$id]}" "$@"
}

api_error='{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"API Error: Unable to connect to API"}]}}'
streaming='{"type":"assistant","message":{"role":"assistant","stop_reason":null,"content":[{"type":"text","text":"Half a rep"}]}}'
sidechain_end='{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"subagent done"}]}}'
interrupted='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}'
interrupted_tool='{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","is_error":true,"content":"The user doesn'"'"'t want to proceed with this tool use."},{"type":"text","text":"[Request interrupted by user for tool use]"}]}}'
caveat='{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>The command below was run directly by the user.</local-command-caveat>"}}'
command='{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-message>model</command-message>"}}'
stdout='{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to opus</local-command-stdout>"}}'
meta='{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>context</system-reminder>"}}'
noise='{"type":"last-prompt","lastPrompt":"do the task"}'

# Working: mid-turn when it stopped.
task w-tooluse "$T_PROMPT" "$T_TOOL_USE"
task w-toolresult "$T_PROMPT" "$T_TOOL_USE" "$T_TOOL_RESULT" "$noise"
task w-prompt "$T_PROMPT" "$T_END_TURN" "$T_TURN_DURATION" "$T_PROMPT"
task w-streaming "$T_PROMPT" "$streaming"
task w-apierror "$T_PROMPT" "$T_TOOL_USE" "$T_TOOL_RESULT" "$api_error"
task w-cutoff "$T_PROMPT" "$T_TOOL_USE" '{"type":"assistant","message":{"role":"assis'
task w-sidechain "$T_PROMPT" "$T_TOOL_USE" "$sidechain_end"
# Idle: the turn had ended.
task i-endturn "$T_PROMPT" "$T_END_TURN" "$T_TURN_DURATION" "$noise"
task i-interrupted "$T_PROMPT" "$T_TOOL_USE" "$interrupted"
task i-intertool "$T_PROMPT" "$T_TOOL_USE" "$interrupted_tool"
task i-localcmd "$T_PROMPT" "$T_END_TURN" "$caveat" "$command" "$stdout"
task i-meta "$T_PROMPT" "$T_END_TURN" "$meta"
task i-empty
# Unknown: no transcript to read.
task u-nopath "$T_PROMPT" "$T_TOOL_USE"
jq 'del(.transcript_path)' "$H/state/u-nopath.claude-session" >"$TEST_TMP/r" && mv "$TEST_TMP/r" "$H/state/u-nopath.claude-session"

plan_line() { printf '%s\n' "$1" | grep -E "^would resume +$2 "; }

out=$("$FCR" resume --home "$H" --dry-run --verbose 2>&1)
assert_eq "dry run exits 0" 0 "$?"
for id in w-tooluse w-toolresult w-prompt w-streaming w-apierror w-cutoff w-sidechain; do
  assert_contains "$id: was working, gets the restart note" "; restart note (was working)" "$(plan_line "$out" "$id")"
done
for id in i-endturn i-interrupted i-intertool i-localcmd i-meta i-empty; do
  assert_contains "$id: was idle, no restart note" "; no restart note (was idle)" "$(plan_line "$out" "$id")"
done
assert_contains "no transcript path: unknown, no restart note" "; no restart note (turn state unknown)" "$(plan_line "$out" u-nopath)"
assert_contains "verbose: a working session's command ends with the note" \
  "--resume ${SID[w-tooluse]} \\[firstmate-claude-resume\\]" "$out"
assert_contains "verbose: an idle session's command ends with its id" \
  "cmd: claude --model sonnet --resume ${SID[i-endturn]}"$'\n' "$out"

out=$("$FCR" resume --home "$H" --dry-run --no-prompt 2>&1)
assert_eq "--no-prompt: no note for any session" "" "$(printf '%s\n' "$out" | grep '^would' | grep -v '; no restart note (--no-prompt)$')"
out=$("$FCR" resume --home "$H" --dry-run --prompt 2>&1)
assert_eq "--prompt: the note for every session" "" "$(printf '%s\n' "$out" | grep '^would' | grep -v '; restart note (--prompt)$')"
out=$("$FCR" resume --home "$H" --dry-run --prompt --no-prompt 2>&1)
assert_eq "--prompt with --no-prompt is a usage error" 2 "$?"
assert_contains "the usage error says why" "--no-prompt and --prompt cannot be combined" "$out"

# Real runs: what the relaunched claude gets.
launched_argv() {  # <session-id>
  jq -cs --arg sid "$1" '[.[] | select(any(.argv[]; . == $sid))] | last | .argv' "$FAKE_CLAUDE_LOG"
}
note_re='^\[firstmate-claude-resume\] The machine or the Herdr multiplexer restarted\.'

out=$("$FCR" resume --home "$H" --only w-tooluse --no-prompt 2>&1)
assert_eq "--no-prompt --only: exits 0" 0 "$?"
assert_contains "--no-prompt --only: reported" "resumed       w-tooluse" "$out"
assert_contains "--no-prompt --only: says no note was sent" "; no restart note (--no-prompt)" "$out"
assert_eq "--no-prompt: a working session comes back with no prompt" \
  "$(jq -cn --arg s "${SID[w-tooluse]}" '["--model","sonnet","--resume",$s]')" "$(launched_argv "${SID[w-tooluse]}")"
assert_eq "--only: nothing else launched" 1 "$(wc -l <"$FAKE_CLAUDE_LOG")"

out=$("$FCR" resume --home "$H" --only i-endturn 2>&1)
assert_eq "an idle session: exits 0" 0 "$?"
assert_eq "an idle session comes back with no prompt" \
  "$(jq -cn --arg s "${SID[i-endturn]}" '["--model","sonnet","--resume",$s]')" "$(launched_argv "${SID[i-endturn]}")"

out=$("$FCR" resume --home "$H" --only w-toolresult 2>&1)
assert_eq "a working session: exits 0" 0 "$?"
check "a working session gets the restart note as its prompt" \
  jq -en --argjson a "$(launched_argv "${SID[w-toolresult]}")" --arg s "${SID[w-toolresult]}" --arg re "$note_re" \
  '$a[:-1] == ["--model","sonnet","--resume",$s] and ($a[-1] | test($re))'

out=$("$FCR" resume --home "$H" --only i-meta --prompt 2>&1)
assert_eq "--prompt: exits 0" 0 "$?"
check "--prompt: an idle session gets the restart note" \
  jq -en --argjson a "$(launched_argv "${SID[i-meta]}")" --arg re "$note_re" '$a[-1] | test($re)'

finish
