#!/usr/bin/env bash
# uninstall.sh - remove firstmate-claude-resume.
#
# Usage: ./uninstall.sh [--bin-dir <dir>] [--config-dir <dir>]... [--purge [--home <dir>]...]
#
# Removes exactly the fcr SessionStart hook entry from <config dir>/settings.json
# (backing the file up first; every other hook stays) and the installed
# <bin dir>/fcr and <bin dir>/fcr-session-hook. Bin and config dirs default as in
# install.sh. Recorded session files stay in place, so a later reinstall can
# still resume those sessions, unless --purge is given: then every
# state/*.claude-session and state/.primary-claude-session under each --home
# (default ~/firstmate) and its second mate homes is deleted, together with
# fcr's launcher scripts. Safe to rerun.
set -euo pipefail

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/settings.sh
. "$SRC_DIR/lib/settings.sh"

bin_dir="$HOME/.local/bin"
config_dirs=()
homes=()
purge=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bin-dir) [ "$#" -ge 2 ] || fcr_settings_die "--bin-dir needs a directory"; bin_dir=$2; shift 2 ;;
    --bin-dir=*) bin_dir=${1#*=}; shift ;;
    --config-dir) [ "$#" -ge 2 ] || fcr_settings_die "--config-dir needs a directory"; config_dirs+=("$2"); shift 2 ;;
    --config-dir=*) config_dirs+=("${1#*=}"); shift ;;
    --home) [ "$#" -ge 2 ] || fcr_settings_die "--home needs a directory"; homes+=("$2"); shift 2 ;;
    --home=*) homes+=("${1#*=}"); shift ;;
    --purge) purge=1; shift ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fcr_settings_die "unknown argument: $1 (see --help)" ;;
  esac
done
[ "${#config_dirs[@]}" -gt 0 ] || config_dirs=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
[ "${#homes[@]}" -gt 0 ] || homes=("$HOME/firstmate")

command -v jq >/dev/null 2>&1 || fcr_settings_die "jq is required"
for dir in "${config_dirs[@]}"; do
  fcr_settings_check "$dir/settings.json"
done

for dir in "${config_dirs[@]}"; do
  fcr_settings_uninstall "$dir/settings.json"
done

for name in fcr fcr-session-hook; do
  file="$bin_dir/$name"
  if [ -f "$file" ] && grep -q 'firstmate-claude-resume' "$file" 2>/dev/null; then
    rm -f "$file"
    printf 'removed %s\n' "$file"
  elif [ -e "$file" ]; then
    printf 'left %s in place: it is not an fcr file\n' "$file"
  fi
done

# purge_home <home>: delete this home's session records, then its second mates'.
purge_home() {
  local home=$1 meta smhome real
  real=$(cd "$home" 2>/dev/null && pwd -P) || return 0
  case " $visited " in *" $real "*) return 0 ;; esac
  visited="$visited $real"
  [ -d "$home/state" ] || return 0
  for file in "$home/state"/*.claude-session "$home/state/.primary-claude-session"; do
    [ -f "$file" ] || continue
    rm -f "$file"
    printf 'purged %s\n' "$file"
  done
  for meta in "$home/state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(sed -n 's/^kind=//p' "$meta" | tail -n 1)" = secondmate ] || continue
    smhome=$(sed -n 's/^home=//p' "$meta" | tail -n 1)
    [ -z "$smhome" ] || purge_home "$smhome"
  done
}

if [ "$purge" = 1 ]; then
  visited=''
  for home in "${homes[@]}"; do
    purge_home "$home"
  done
  launch_dir=${FCR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate-claude-resume}
  if [ -d "$launch_dir" ]; then
    rm -rf "$launch_dir"
    printf 'purged %s\n' "$launch_dir"
  fi
else
  printf 'recorded session files were kept; rerun with --purge to delete them\n'
fi
printf 'done.\n'
