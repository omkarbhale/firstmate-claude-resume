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
assert_eq "record env is the whole launch environment, marked full" full "$(jq -r .env_scope "$record")"
assert_eq "record env keeps the launch variables, including ones outside any allowlist" \
  "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_CONFIG_DIR COMPACT_ADVISER_DISABLE DISABLE_AUTOUPDATER FM_TASK_ID FM_TASK_INBOX GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 LAVISH_AXI_HOST OTHER_VAR" \
  "$(jq -r '.env | keys | map(select(test("^(CLAUDE_|COMPACT_|DISABLE_|FM_|GIT_CONFIG_|LAVISH_|OTHER_)"))) | join(" ")' "$record")"
assert_eq "record env has the ordinary session environment too" "$PATH|$HOME|nope" \
  "$(jq -r '"\(.env.PATH)|\(.env.HOME)|\(.env.OTHER_VAR)"' "$record")"
assert_eq "record env values" "/hooks|$HOME/.claude-alt" "$(jq -r '"\(.env.GIT_CONFIG_VALUE_0)|\(.env.CLAUDE_CONFIG_DIR)"' "$record")"
assert_eq "pane and process names are not recorded" "" \
  "$(jq -r '.env | keys[] | select(test("^(HERDR_|PWD$|OLDPWD$|SHLVL$|_$|CLAUDECODE$)"))' "$record")"
assert_eq "credential-like names are withheld, and only their names are kept" \
  "ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN FM_GITHUB_TOKEN" "$(jq -r '.env_withheld | join(" ")' "$record")"
assert_eq "no credential-like name is in the recorded env" "" \
  "$(jq -r '.env | keys[] | select(test("TOKEN|API_KEY"))' "$record")"
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

# --- the recorded cwd is the home root, not a subfolder of it --------------------------
sub="$home/projects/clone/src"
mkdir -p "$sub"
sid_sub=$(new_uuid)
(cd "$sub" && FM_TASK_INBOX="$home/state/t1.inbox" FAKE_CLAUDE_SESSION_ID="$sid_sub" claude --model sonnet 'x')
assert_eq "a task session reporting a subfolder of its home records the home root" "$home" "$(jq -r .cwd "$record")"
assert_eq "the record is for that session" "$sid_sub" "$(jq -r .session_id "$record")"
# A secondmate's own home is a separate tree from the state dir its inbox is in.
smhome="$TEST_TMP/fm-sm"
make_home "$smhome"
mkdir -p "$smhome/projects/clone"
(cd "$smhome/projects/clone" && FM_TASK_INBOX="$home/state/t1.inbox" claude --model sonnet 'x')
assert_eq "a secondmate in a subfolder of its own home records that home root" "$smhome" "$(jq -r .cwd "$record")"
(cd "$wt" && FM_TASK_INBOX="$home/state/t1.inbox" claude --model sonnet 'x')
assert_eq "a task worktree outside any home keeps its reported cwd" "$wt" "$(jq -r .cwd "$record")"

# --- the credential denylist ----------------------------------------------------
# Every name below is credential-like and must never reach the record; every
# name in the second group looks close but is an ordinary setting and is kept.
deny_names='GITHUB_TOKEN NPM_TOKEN AWS_SECRET_ACCESS_KEY AWS_ACCESS_KEY_ID DB_PASSWORD PGPASSWD GPG_PASSPHRASE
  OPENAI_API_KEY STRIPE_APIKEY GOOGLE_PRIVATE_KEY SIGNING_KEY MY_CREDENTIALS BEARER_VALUE SESSION_COOKIE
  SSH_AUTH_SOCK HTTP_AUTHORIZATION DEPLOY_KEY GITLAB_PAT DB_PW SENTRY_DSN DATABASE_URL REDIS_URL
  lowercase_secret'
keep_names='GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME KEYBOARD_LAYOUT GIT_CONFIG_KEY_0 AUTHORS_FILE
  MONKEY_PATH PATCH_LEVEL EDITOR LANG TERM SOME_URL'
deny_env=()
for n in $deny_names; do deny_env+=("$n=hunter2"); done
keep_env=()
for n in $keep_names; do keep_env+=("$n=plain"); done
(cd "$wt" && FM_TASK_INBOX="$home/state/t1.inbox" env "${deny_env[@]}" "${keep_env[@]}" claude --model sonnet 'x')
leaked=$(jq -r --arg names "$deny_names" '.env | keys[] as $k | select(($names | split(" ") | map(select(. != "")) | index($k)) != null) | $k' "$record")
assert_eq "no credential-like name is recorded" "" "$leaked"
assert_not_contains "no credential value is recorded" hunter2 "$(cat "$record")"
missing=''
for n in $keep_names; do jq -e --arg n "$n" '.env | has($n)' "$record" >/dev/null || missing+=" $n"; done
assert_eq "close-looking ordinary names are still recorded" "" "$missing"
withheld_missing=''
for n in $deny_names; do jq -e --arg n "$n" '.env_withheld | index($n)' "$record" >/dev/null || withheld_missing+=" $n"; done
assert_eq "each withheld credential name is listed (names only)" "" "$withheld_missing"

# The extra denylist file: one extended regex per line, # comments and blanks ignored.
mkdir -p "$HOME/.config/fcr"
printf '# my own secrets\n\n^CORP_\n  \nINTERNAL_(ID|HASH)$\n' >"$HOME/.config/fcr/env-deny"
(cd "$wt" && FM_TASK_INBOX="$home/state/t1.inbox" CORP_THING=x corp_lower=x INTERNAL_ID=1 INTERNAL_HASH=2 INTERNAL_OTHER=3 claude --model sonnet 'x')
assert_eq "names matching the extra denylist are not recorded" "INTERNAL_OTHER" \
  "$(jq -r '.env | keys[] | select(test("^(CORP_|corp_|INTERNAL_)"))' "$record")"
assert_eq "extra-denylist names are listed as withheld" "CORP_THING INTERNAL_HASH INTERNAL_ID" \
  "$(jq -r '.env_withheld | map(select(test("^(CORP_|INTERNAL_)"))) | join(" ")' "$record")"
assert_eq "the built-in denylist still applies with an extra file" "" "$(jq -r '.env | keys[] | select(test("TOKEN"))' "$record")"
printf '(unbalanced\n' >"$HOME/.config/fcr/env-deny"
(cd "$wt" && FM_TASK_INBOX="$home/state/t1.inbox" GITHUB_TOKEN=hunter2 KEEP_ME=1 claude --model sonnet 'x')
assert_eq "a malformed extra pattern falls back to the built-in denylist, not an empty env" "1|" \
  "$(jq -r '"\(.env.KEEP_ME)|\(.env.GITHUB_TOKEN // "")"' "$record")"
rm -f "$HOME/.config/fcr/env-deny"
printf '^FROM_FILE_VAR$\n' >"$TEST_TMP/alt-deny"
(cd "$wt" && FM_TASK_INBOX="$home/state/t1.inbox" FCR_ENV_DENY_FILE="$TEST_TMP/alt-deny" FROM_FILE_VAR=1 claude --model sonnet 'x')
assert_eq "FCR_ENV_DENY_FILE names the extra file" "" "$(jq -r '.env | keys[] | select(. == "FROM_FILE_VAR")' "$record")"

# --- primary --------------------------------------------------------------------
psid=$(new_uuid)
(cd "$home" && HERDR_SOCKET_PATH="$HOME/.config/herdr/sessions/fm-lab-x/herdr.sock" HERDR_PANE_ID=w1:p1 \
  FAKE_CLAUDE_SESSION_ID="$psid" claude)
check "primary record written when cwd is a firstmate home root" test -f "$home/state/.primary-claude-session"
assert_eq "primary record session id" "$psid" "$(jq -r .session_id "$home/state/.primary-claude-session")"
assert_eq "herdr session derived from the socket path" fm-lab-x "$(jq -r .herdr.session "$home/state/.primary-claude-session")"
(cd "$home" && HERDR_SOCKET_PATH="$HOME/.config/herdr/herdr.sock" HERDR_PANE_ID=w1:p1 claude)
assert_eq "default socket path means the default session" default "$(jq -r .herdr.session "$home/state/.primary-claude-session")"

# --- background-session primary (hosted by `claude daemon`) ---------------------
# claude bg-pty-host ... -- <share>/claude/versions/<x.y.z> --session-id <id> ...
# The session is the versioned binary, not the claude-named wrapper above it.
share="$TEST_TMP/share/claude/versions"
mkdir -p "$share"
cp "$TEST_TMP/bin/claude" "$share/2.1.310"
bgsid=$(new_uuid)
rm -f "$home/state/.primary-claude-session"
(cd "$home" && FAKE_CLAUDE_LOG="$TEST_TMP/bg.log" FAKE_CLAUDE_SESSION_ID="$bgsid" FM_HOME="$home" \
  claude bg-pty-host --bg-pty-host "$TEST_TMP/bg.sock" 165 46 -- "$share/2.1.310" \
  --session-id "$bgsid" --permission-mode bypassPermissions)
bgrec="$home/state/.primary-claude-session"
check "background primary: record written" test -f "$bgrec"
assert_eq "background primary: session id" "$bgsid" "$(jq -r .session_id "$bgrec" 2>/dev/null)"
assert_eq "background primary: argv is the session's, with the versioned binary named claude" \
  "$(jq -cn --arg s "$bgsid" '["claude", "--session-id", $s, "--permission-mode", "bypassPermissions"]')" "$(jq -c .argv "$bgrec" 2>/dev/null)"
assert_not_contains "background primary: the wrapper is not recorded" bg-pty-host "$(cat "$bgrec" 2>/dev/null)"
# The stub logs each run's pid: the recorded one must be the session's.
session_pid=$(jq -r --arg s "$bgsid" 'select(.argv | index("--session-id")) | select(.argv | index($s)) | .pid' "$TEST_TMP/bg.log" 2>/dev/null | head -n 1)
assert_eq "background primary: claude_pid is the session, not the wrapper" "$session_pid" "$(jq -r .claude_pid "$bgrec" 2>/dev/null)"
assert_eq "background primary: no pane recorded when the session has no HERDR_* variables" "" \
  "$(jq -r .herdr.pane_id "$bgrec" 2>/dev/null)"

# If the session process is not recognisable, the wrapper's command after "--"
# is recorded instead of the wrapper.
mkdir -p "$TEST_TMP/other"
cp "$TEST_TMP/bin/claude" "$TEST_TMP/other/session"
rm -f "$bgrec"
(cd "$home" && FAKE_CLAUDE_SESSION_ID="$bgsid" claude bg-pty-host --bg-pty-host "$TEST_TMP/bg.sock" 165 46 -- \
  "$TEST_TMP/other/session" --session-id "$bgsid" --permission-mode bypassPermissions)
assert_eq "unrecognised session: the command after -- is recorded, not the wrapper" \
  "$(jq -cn --arg c "$TEST_TMP/other/session" --arg s "$bgsid" '[$c, "--session-id", $s, "--permission-mode", "bypassPermissions"]')" \
  "$(jq -c .argv "$bgrec" 2>/dev/null)"

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
