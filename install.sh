#!/usr/bin/env bash
# install.sh - install firstmate-claude-resume for Claude Code.
#
# Usage: ./install.sh [--bin-dir <dir>] [--config-dir <dir>]...
#
# Copies bin/fcr and bin/fcr-session-hook into the bin dir (default
# ~/.local/bin) and adds ONE SessionStart hook entry running
# <bin dir>/fcr-session-hook to <config dir>/settings.json, next to any hooks
# already there. Config dirs come from --config-dir (repeatable), else
# $CLAUDE_CONFIG_DIR, else ~/.claude. Project-level .claude/settings.json files
# are never touched.
#
# A settings file that is not a JSON object is refused before anything is
# changed. An existing file is backed up to settings.json.fcr-backup-<time>
# before it is rewritten, and is only rewritten when the entry is missing or
# different, so rerunning is safe. An entry from an earlier install in another
# bin dir is replaced, never duplicated.
set -euo pipefail

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/settings.sh
. "$SRC_DIR/lib/settings.sh"

bin_dir="$HOME/.local/bin"
config_dirs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bin-dir) [ "$#" -ge 2 ] || fcr_settings_die "--bin-dir needs a directory"; bin_dir=$2; shift 2 ;;
    --bin-dir=*) bin_dir=${1#*=}; shift ;;
    --config-dir) [ "$#" -ge 2 ] || fcr_settings_die "--config-dir needs a directory"; config_dirs+=("$2"); shift 2 ;;
    --config-dir=*) config_dirs+=("${1#*=}"); shift ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fcr_settings_die "unknown argument: $1 (see --help)" ;;
  esac
done
[ "${#config_dirs[@]}" -gt 0 ] || config_dirs=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}")

command -v jq >/dev/null 2>&1 || fcr_settings_die "jq is required"
if [ ! -f "$SRC_DIR/bin/fcr" ] || [ ! -f "$SRC_DIR/bin/fcr-session-hook" ]; then
  fcr_settings_die "run install.sh from a firstmate-claude-resume checkout"
fi

# Refuse malformed settings before changing anything at all.
for dir in "${config_dirs[@]}"; do
  fcr_settings_check "$dir/settings.json"
done

mkdir -p "$bin_dir"
bin_dir=$(cd "$bin_dir" && pwd)
install -m 755 "$SRC_DIR/bin/fcr" "$bin_dir/fcr"
install -m 755 "$SRC_DIR/bin/fcr-session-hook" "$bin_dir/fcr-session-hook"
printf 'installed %s/fcr and %s/fcr-session-hook\n' "$bin_dir" "$bin_dir"

for dir in "${config_dirs[@]}"; do
  fcr_settings_install "$dir/settings.json" "$bin_dir/fcr-session-hook"
done

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) printf 'note: %s is not on PATH; add it to run fcr by name\n' "$bin_dir" ;;
esac
printf 'done. After a reboot or Herdr restart, run: fcr resume --dry-run, then fcr resume\n'
