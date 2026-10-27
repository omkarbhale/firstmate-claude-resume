#!/usr/bin/env bash
# install.sh / uninstall.sh against temp settings that already hold other hooks.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cfg="$TEST_TMP/cfg"
bin="$TEST_TMP/inst-bin"
settings="$cfg/settings.json"
mkdir -p "$cfg"
cat >"$settings" <<'EOF'
{
  "model": "sonnet",
  "hooks": {
    "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "echo other-start"}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre"}]}]
  }
}
EOF
original=$(jq -cS . "$settings")
fcr_entries() { jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | test("fcr-session-hook"))] | length' "$1"; }
others() { jq -cS 'del(.hooks.SessionStart[]? | select(any(.hooks[]?; .command | test("fcr-session-hook"))))' "$1"; }
backups() { find "$cfg" -name 'settings.json.fcr-backup-*' | wc -l; }

# A project-level settings file in the working directory must never change.
proj="$TEST_TMP/project"
mkdir -p "$proj/.claude"
printf '{"hooks":{}}\n' >"$proj/.claude/settings.json"
proj_before=$(md5sum <"$proj/.claude/settings.json")

# --- install ---------------------------------------------------------------------
out=$(cd "$proj" && "$ROOT/install.sh" --bin-dir "$bin" --config-dir "$cfg" 2>&1)
assert_eq "install exits 0" 0 "$?"
check "fcr installed" test -x "$bin/fcr"
check "hook installed" test -x "$bin/fcr-session-hook"
assert_eq "exactly one fcr SessionStart entry" 1 "$(fcr_entries "$settings")"
assert_eq "the entry runs the installed hook by absolute path" "'$bin/fcr-session-hook'" \
  "$(jq -r '.hooks.SessionStart[] | .hooks[] | select(.command | test("fcr")) | .command' "$settings")"
assert_eq "other hooks and settings are untouched" "$original" "$(others "$settings")"
assert_eq "settings were backed up first" 1 "$(backups)"
assert_eq "the backup is the original" "$original" "$(jq -cS . "$(find "$cfg" -name 'settings.json.fcr-backup-*')")"
assert_eq "project-level .claude/settings.json untouched" "$proj_before" "$(md5sum <"$proj/.claude/settings.json")"
"$bin/fcr" version >/dev/null
assert_eq "installed fcr runs" 0 "$?"

# --- idempotent -------------------------------------------------------------------
after_first=$(cat "$settings")
sleep 1
out=$("$ROOT/install.sh" --bin-dir "$bin" --config-dir "$cfg" 2>&1)
assert_eq "rerun exits 0" 0 "$?"
assert_contains "rerun says it is already installed" "already has the fcr SessionStart hook" "$out"
assert_eq "rerun leaves settings byte-identical" "$after_first" "$(cat "$settings")"
assert_eq "rerun makes no new backup" 1 "$(backups)"

# --- another bin dir replaces, never duplicates ---------------------------------------
bin2="$TEST_TMP/other bin"
"$ROOT/install.sh" --bin-dir "$bin2" --config-dir "$cfg" >/dev/null 2>&1
assert_eq "install from another bin dir keeps one entry" 1 "$(fcr_entries "$settings")"
assert_eq "the entry now names the new bin dir, quoted" "'$bin2/fcr-session-hook'" \
  "$(jq -r '.hooks.SessionStart[] | .hooks[] | select(.command | test("fcr")) | .command' "$settings")"
assert_eq "other hooks still untouched" "$original" "$(others "$settings")"
"$ROOT/install.sh" --bin-dir "$bin" --config-dir "$cfg" >/dev/null 2>&1

# --- the installed hook really runs from settings ------------------------------------
hook_cmd=$(jq -r '.hooks.SessionStart[] | .hooks[] | select(.command | test("fcr")) | .command' "$settings")
fm="$TEST_TMP/fm"
make_home "$fm"
out=$(printf '{"session_id":"abc","cwd":"%s","source":"startup"}' "$fm" | bash -c "$hook_cmd" 2>&1; echo "rc=$?")
assert_eq "the settings command runs silently and exits 0" "rc=0" "$out"

# --- default config dir ---------------------------------------------------------------
out=$(CLAUDE_CONFIG_DIR="$TEST_TMP/envcfg" "$ROOT/install.sh" --bin-dir "$bin" 2>&1)
assert_eq "CLAUDE_CONFIG_DIR is the default config dir" 1 "$(fcr_entries "$TEST_TMP/envcfg/settings.json")"
out=$(env -u CLAUDE_CONFIG_DIR "$ROOT/install.sh" --bin-dir "$bin" 2>&1)
assert_eq "HOME/.claude is the fallback (temp HOME)" 1 "$(fcr_entries "$HOME/.claude/settings.json")"
out=$("$ROOT/install.sh" --bin-dir "$bin" --config-dir "$TEST_TMP/m1" --config-dir "$TEST_TMP/m2" 2>&1)
assert_eq "--config-dir is repeatable" "1 1" "$(fcr_entries "$TEST_TMP/m1/settings.json") $(fcr_entries "$TEST_TMP/m2/settings.json")"

# --- malformed settings are refused -------------------------------------------------------
bad="$TEST_TMP/bad"
mkdir -p "$bad"
printf '{"hooks": [1,2' >"$bad/settings.json"
bad_before=$(cat "$bad/settings.json")
bin3="$TEST_TMP/bin3"
out=$("$ROOT/install.sh" --bin-dir "$bin3" --config-dir "$bad" 2>&1)
assert_eq "malformed settings: install fails" 1 "$?"
assert_contains "malformed settings: says why" "not valid Claude settings JSON" "$out"
assert_eq "malformed settings: file unchanged" "$bad_before" "$(cat "$bad/settings.json")"
check "malformed settings: nothing installed" test ! -e "$bin3/fcr"
printf '{"hooks": []}' >"$bad/settings.json"
out=$("$ROOT/install.sh" --bin-dir "$bin3" --config-dir "$bad" 2>&1)
assert_eq "non-object hooks: install fails" 1 "$?"

# --- uninstall ----------------------------------------------------------------------------
sm="$TEST_TMP/fm-sm"
make_home "$sm"
printf 'kind=secondmate\nharness=claude\nhome=%s\n' "$sm" >"$fm/state/sm.meta"
printf '{}' >"$fm/state/t1.claude-session"
printf '{}' >"$fm/state/.primary-claude-session"
printf '{}' >"$sm/state/c1.claude-session"
out=$("$ROOT/uninstall.sh" --bin-dir "$bin" --config-dir "$cfg" 2>&1)
assert_eq "uninstall exits 0" 0 "$?"
assert_eq "uninstall removes the fcr entry" 0 "$(fcr_entries "$settings")"
assert_eq "uninstall leaves everything else exactly as before install" "$original" "$(jq -cS . "$settings")"
check "uninstall removes fcr" test ! -e "$bin/fcr"
check "uninstall removes the hook" test ! -e "$bin/fcr-session-hook"
check "uninstall keeps session records" test -f "$fm/state/t1.claude-session"
out=$("$ROOT/uninstall.sh" --bin-dir "$bin" --config-dir "$cfg" 2>&1)
assert_eq "uninstall rerun exits 0" 0 "$?"
assert_contains "uninstall rerun is a no-op" "has no fcr hook" "$out"
printf 'not ours\n' >"$bin/fcr"
"$ROOT/uninstall.sh" --bin-dir "$bin" --config-dir "$cfg" >/dev/null 2>&1
check "uninstall leaves a foreign file named fcr alone" test -f "$bin/fcr"
mkdir -p "$XDG_STATE_HOME/firstmate-claude-resume/launch"
out=$("$ROOT/uninstall.sh" --bin-dir "$bin" --config-dir "$cfg" --purge --home "$fm" 2>&1)
assert_eq "uninstall --purge exits 0" 0 "$?"
check "--purge removes task records" test ! -e "$fm/state/t1.claude-session"
check "--purge removes the primary record" test ! -e "$fm/state/.primary-claude-session"
check "--purge follows second mate homes" test ! -e "$sm/state/c1.claude-session"
check "--purge removes launchers" test ! -e "$XDG_STATE_HOME/firstmate-claude-resume"
check "--purge keeps the meta files" test -f "$fm/state/sm.meta"

finish
