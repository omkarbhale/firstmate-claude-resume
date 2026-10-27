# shellcheck shell=bash
# lib/settings.sh - Claude settings.json editing shared by install.sh and
# uninstall.sh. Sourced, never run.
#
# The fcr hook entry is recognized by its command naming fcr-session-hook as
# the final path component, so an install from another bin dir is still found.

fcr_settings_die() {
  printf '%s: %s\n' "${0##*/}" "$*" >&2
  exit 1
}

# jq definitions shared by every filter below.
FCR_SETTINGS_JQ_DEFS='
  def isfcr: ((.command? // "") | type == "string") and ((.command? // "") | test("(^|/)fcr-session-hook'"'"'?$"));
  def strip_fcr:
    if (.hooks | type) == "object" and (.hooks.SessionStart | type) == "array" then
      .hooks.SessionStart |= map(
        if (type == "object") and any(.hooks[]?; isfcr)
        then (.hooks |= map(select(isfcr | not))) | select((.hooks | length) > 0)
        else . end)
      | if .hooks.SessionStart == [] then del(.hooks.SessionStart) else . end
      | if .hooks == {} then del(.hooks) else . end
    else . end;
'

# fcr_settings_check <settings.json>: refuse a file that exists but is not a
# JSON object whose hooks (when present) are an object.
fcr_settings_check() {
  local file=$1
  [ -e "$file" ] || return 0
  [ -f "$file" ] || fcr_settings_die "$file is not a regular file"
  [ -s "$file" ] || return 0
  jq -e 'type == "object" and ((.hooks // {}) | type == "object") and ((.hooks.SessionStart // []) | type == "array")' \
    "$file" >/dev/null 2>&1 ||
    fcr_settings_die "$file is not valid Claude settings JSON (object with an object 'hooks'); fix it first, nothing was changed"
}

fcr_settings_quote() {  # <path>: single-quoted for a shell command line
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

# fcr_settings_write <file> <new-json>: back up the existing file, then
# replace it atomically.
fcr_settings_write() {
  local file=$1 json=$2 tmp backup
  if [ -s "$file" ]; then
    backup="$file.fcr-backup-$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$file" "$backup"
    printf 'backed up %s to %s\n' "$file" "$backup"
  fi
  tmp="$file.fcr-tmp.$$"
  printf '%s\n' "$json" >"$tmp"
  if [ -e "$file" ]; then chmod --reference="$file" "$tmp" 2>/dev/null || true; fi
  mv -f "$tmp" "$file"
}

# fcr_settings_install <settings.json> <hook path>
fcr_settings_install() {
  local file=$1 hook=$2 current desired command
  mkdir -p "$(dirname "$file")"
  current='{}'
  [ ! -s "$file" ] || current=$(jq -c . "$file")
  command=$(fcr_settings_quote "$hook")
  desired=$(printf '%s' "$current" | jq --arg cmd "$command" "$FCR_SETTINGS_JQ_DEFS"'
    def entry: {hooks: [{type: "command", command: $cmd, timeout: 10}]};
    if [ .hooks.SessionStart[]?.hooks[]? | select(isfcr) ] == [entry.hooks[0]]
       and ([ .hooks.SessionStart[]? | select(any(.hooks[]?; isfcr)) ] == [entry])
    then .
    else strip_fcr | .hooks.SessionStart = ((.hooks.SessionStart // []) + [entry])
    end')
  if [ "$(printf '%s' "$desired" | jq -cS .)" = "$(printf '%s' "$current" | jq -cS .)" ] && [ -s "$file" ]; then
    printf '%s already has the fcr SessionStart hook\n' "$file"
    return 0
  fi
  fcr_settings_write "$file" "$desired"
  printf 'added the fcr SessionStart hook to %s\n' "$file"
}

# fcr_settings_uninstall <settings.json>
fcr_settings_uninstall() {
  local file=$1 current desired
  [ -s "$file" ] || { printf '%s: no settings, nothing to remove\n' "$file"; return 0; }
  current=$(jq -c . "$file")
  desired=$(printf '%s' "$current" | jq "$FCR_SETTINGS_JQ_DEFS"' strip_fcr')
  if [ "$(printf '%s' "$desired" | jq -cS .)" = "$(printf '%s' "$current" | jq -cS .)" ]; then
    printf '%s has no fcr hook\n' "$file"
    return 0
  fi
  fcr_settings_write "$file" "$desired"
  printf 'removed the fcr SessionStart hook from %s\n' "$file"
}
