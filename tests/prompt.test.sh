#!/usr/bin/env bash
# The restart note: sent only to a session that was working when it stopped, or
# idle but waiting on a background job of its own, read from its transcript;
# --no-prompt sends it to none, --prompt to all.
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

# Background jobs, shaped like Claude Code's transcript entries.
bg_result() {  # <extra toolUseResult json fields>: a user entry carrying a tool result
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu2","content":"started"}]},"toolUseResult":{%s}}' "$1"
}
bash_start=$(bg_result '"stdout":"","stderr":"","interrupted":false,"backgroundTaskId":"bash1"')
bash_start2=$(bg_result '"stdout":"","stderr":"","interrupted":false,"backgroundTaskId":"bash2","timedOutAfterMs":120000')
monitor_start=$(bg_result '"persistent":true,"taskId":"mon1","timeoutMs":300000')
agent_start=$(bg_result '"status":"async_launched","agentId":"agent1","description":"research"')
sync_agent=$(bg_result '"status":"completed","agentId":"agent9","content":[]')
side_start=$(bg_result '"backgroundTaskId":"side1"' | jq -c '. + {isSidechain: true}')
taskstop=$(bg_result '"message":"Successfully stopped task: mon1 (tail -F x)","task_id":"mon1","task_type":"local_bash","command":"tail -F x"')
notice() {  # <task id> <status>: a task-notification body
  printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>tu2</tool-use-id>\n<status>%s</status>\n<summary>Background command done</summary>\n</task-notification>' "$1" "$2"
}
n_queued() { jq -nc --arg p "$(notice "$1" "${2:-completed}")" '{type:"attachment",attachment:{type:"queued_command",commandMode:"task-notification",prompt:$p}}'; }
n_enqueue() { jq -nc --arg p "$(notice "$1" "${2:-completed}")" '{type:"queue-operation",operation:"enqueue",content:$p}'; }
n_user() { jq -nc --arg p "$(notice "$1" "${2:-completed}")" '{type:"user",origin:{kind:"task-notification"},message:{role:"user",content:$p}}'; }
monitor_event='{"type":"attachment","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>\n<task-id>mon1</task-id>\n<summary>Monitor event: \"watch\"</summary>\n<event>line 1</event>\n</task-notification>"}}'
hook_resume='{"type":"attachment","attachment":{"type":"hook_success","hookEvent":"SessionStart","hookName":"SessionStart:resume"}}'
hook_compact='{"type":"attachment","attachment":{"type":"hook_success","hookEvent":"SessionStart","hookName":"SessionStart:compact"}}'

# Waiting: idle, with a job the restart killed.
task g-bash "$T_PROMPT" "$T_TOOL_USE" "$bash_start" "$T_END_TURN" "$T_TURN_DURATION"
task g-monitor "$T_PROMPT" "$T_TOOL_USE" "$monitor_start" "$T_END_TURN" "$T_TURN_DURATION"
task g-agent "$T_PROMPT" "$T_TOOL_USE" "$agent_start" "$T_END_TURN" "$T_TURN_DURATION"
task g-two "$T_PROMPT" "$bash_start" "$bash_start2" "$T_END_TURN"
task g-event "$T_PROMPT" "$monitor_start" "$monitor_event" "$T_END_TURN"
task g-partial "$T_PROMPT" "$bash_start" "$bash_start2" "$(n_queued bash1)" "$T_END_TURN"
task g-localcmd "$T_PROMPT" "$bash_start" "$T_END_TURN" "$caveat" "$command" "$stdout"
task g-afterresume "$T_PROMPT" "$bash_start" "$T_END_TURN" "$hook_resume" "$T_PROMPT" "$monitor_start" "$T_END_TURN"
task g-compact "$T_PROMPT" "$bash_start" "$hook_compact" "$T_END_TURN"
# Idle with nothing left running.
task d-queued "$T_PROMPT" "$bash_start" "$(n_queued bash1)" "$T_END_TURN"
task d-enqueue "$T_PROMPT" "$bash_start" "$(n_enqueue bash1 failed)" "$T_END_TURN"
task d-usermsg "$T_PROMPT" "$bash_start" "$(n_user bash1 killed)" "$T_END_TURN"
task d-agent "$T_PROMPT" "$agent_start" "$(n_queued agent1)" "$T_END_TURN"
task d-taskstop "$T_PROMPT" "$monitor_start" "$taskstop" "$T_END_TURN"
task d-stopped "$T_PROMPT" "$monitor_start" "$(n_queued mon1 stopped)" "$T_END_TURN"
task d-syncagent "$T_PROMPT" "$sync_agent" "$T_END_TURN"
task d-sidechain "$T_PROMPT" "$side_start" "$T_END_TURN"
task d-restarted "$T_PROMPT" "$bash_start" "$monitor_start" "$T_END_TURN" "$hook_resume" "$T_PROMPT" "$T_END_TURN"
task d-interrupted "$T_PROMPT" "$bash_start" "$T_END_TURN" "$interrupted"
# A job and a pending turn: working, whatever the jobs.
task w-withjob "$T_PROMPT" "$bash_start" "$T_TOOL_USE"
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
assert_contains "g-bash: idle but waiting on a Bash background job" "; restart note (was idle, waiting on 1 background job)" "$(plan_line "$out" g-bash)"
for id in g-monitor g-agent g-event g-partial g-localcmd g-afterresume g-compact; do
  assert_contains "$id: idle but waiting on one background job" "; restart note (was idle, waiting on 1 background job)" "$(plan_line "$out" "$id")"
done
assert_contains "g-two: the line counts the jobs" "; restart note (was idle, waiting on 2 background jobs)" "$(plan_line "$out" g-two)"
for id in d-queued d-enqueue d-usermsg d-agent d-taskstop d-stopped d-syncagent d-sidechain d-restarted d-interrupted; do
  assert_contains "$id: idle with nothing running, no restart note" "; no restart note (was idle)" "$(plan_line "$out" "$id")"
done
assert_contains "w-withjob: working wins over the job count" "; restart note (was working)" "$(plan_line "$out" w-withjob)"
assert_contains "no transcript path: unknown, no restart note" "; no restart note (turn state unknown)" "$(plan_line "$out" u-nopath)"
assert_contains "verbose: a working session's command ends with the note" \
  "--resume ${SID[w-tooluse]} \\[firstmate-claude-resume\\]" "$out"
assert_contains "verbose: an idle session's command ends with its id" \
  "cmd: claude --model sonnet --resume ${SID[i-endturn]}"$'\n' "$out"

out=$("$FCR" resume --home "$H" --dry-run --no-prompt 2>&1)
assert_eq "--no-prompt: no note for any session, jobs or not" "" "$(printf '%s\n' "$out" | grep '^would' | grep -v '; no restart note (--no-prompt)$')"
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

out=$("$FCR" resume --home "$H" --only g-bash 2>&1)
assert_eq "a session waiting on a job: exits 0" 0 "$?"
assert_contains "a session waiting on a job: reported" "; restart note (was idle, waiting on 1 background job)" "$out"
check "a session waiting on a job gets the restart note as its prompt" \
  jq -en --argjson a "$(launched_argv "${SID[g-bash]}")" --arg s "${SID[g-bash]}" --arg re "$note_re" \
  '$a[:-1] == ["--model","sonnet","--resume",$s] and ($a[-1] | test($re))'

out=$("$FCR" resume --home "$H" --only d-queued 2>&1)
assert_eq "a session whose job finished: exits 0" 0 "$?"
assert_eq "a session whose job finished comes back with no prompt" \
  "$(jq -cn --arg s "${SID[d-queued]}" '["--model","sonnet","--resume",$s]')" "$(launched_argv "${SID[d-queued]}")"

out=$("$FCR" resume --home "$H" --only i-meta --prompt 2>&1)
assert_eq "--prompt: exits 0" 0 "$?"
check "--prompt: an idle session gets the restart note" \
  jq -en --argjson a "$(launched_argv "${SID[i-meta]}")" --arg re "$note_re" '$a[-1] | test($re)'

finish
