# firstmate-claude-resume

Bring [firstmate](https://github.com/kunchenguid/firstmate)'s Claude workers and second mates back in their own sessions after a reboot or multiplexer restart.

When the machine reboots or Herdr restarts, every firstmate agent dies and its pane comes back as a bare shell.
Firstmate's own recovery then starts second mates again as fresh sessions, so their conversations are lost.
`fcr` brings each one back as the same Claude session (`claude --resume <id>`), with its full chat history, in its own folder and pane, with its original launch settings.

It does not fork or change firstmate.
It adds one Claude `SessionStart` hook that records each session id, plus a command you run after a restart.

## How it works

- **Recorder.** `fcr-session-hook` runs on every Claude session start, resume, clear and compact.
  For a firstmate worker or second mate, which firstmate launches with `FM_TASK_INBOX=<home>/state/<task-id>.inbox`, it writes `<home>/state/<task-id>.claude-session` next to the task's own record.
  For the primary firstmate session, started in a firstmate home root, it writes `<home>/state/.primary-claude-session`.
  The record holds the exact session id from Claude itself, so there is no guessing from transcript folders or timestamps.
  It also holds the cwd, the Herdr session, workspace, tab and pane, the exact launch argv read from `/proc`, an allowlisted set of launch variables (`FM_*`, `GIT_CONFIG_*`, `COMPACT_ADVISER_DISABLE`, `LAVISH_AXI_HOST`, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_*` and `DISABLE_AUTOUPDATER`, minus anything that looks like a credential), and the last 10 session ids the record named before.
  It is silent, makes no network calls and always exits 0, so it can never break or slow a session.
  It ignores `claude -p` runs and Claude processes started from inside another Claude session (`CLAUDECODE=1`), so a helper never overwrites its task's record.
- **Resume.** `fcr resume` walks a firstmate home and every second mate home it records.
  For each Claude task it reports one of three outcomes: `alive` (a live interactive `claude` already runs that session or task, so nothing is doubled), `resumed`, or `skip` with the reason.
  Each session restarts in its recorded folder with its recorded argv and variables.
  The original prompt and any old `--resume`, `--session-id`, `--continue` or `--fork-session` are dropped, and `--resume <id>` is added with a short restart note.
  The note tells the agent the restart killed its background jobs, monitors, Workflows, subagents and child processes, and that it should check and resume them (a Workflow with `resumeFromRunId`).
  The recorded pane is reused when it still exists and holds only a shell.
  Otherwise fcr creates a new tab in the recorded workspace, or a new workspace if that is gone too, and rewrites only `window`, `herdr_workspace_id`, `herdr_tab_id` and `herdr_pane_id` in the task's meta, so firstmate supervises the new pane.
  Second mates are resumed before their own tasks, and the primary last.

## Requirements

- Linux (the recorder reads `/proc`), `bash` 4+, `jq`.
- [Claude Code](https://code.claude.com) as firstmate's harness, and [Herdr](https://herdr.dev) as its multiplexer.

## Install

```sh
git clone https://github.com/omkarbhale/firstmate-claude-resume
cd firstmate-claude-resume
./install.sh
```

This copies `fcr` and `fcr-session-hook` into `~/.local/bin` and adds one `SessionStart` entry to `~/.claude/settings.json`, next to any hooks already there.
It backs the settings file up first (`settings.json.fcr-backup-<time>`), refuses a malformed one without changing anything, and never touches a project's `.claude/settings.json`.
Running it again changes nothing.

- `--bin-dir <dir>` installs somewhere else.
- `--config-dir <dir>` (repeatable) names the Claude config folder; it defaults to `$CLAUDE_CONFIG_DIR`, then `~/.claude`.
  Use it once per config folder your firstmate fleet launches Claude with, such as a worker account pin's folder.

Only sessions started after the install are recorded.
To cover a fleet that is already running, restart its sessions (or wait for its next clear or compact).

## After a reboot or a Herdr restart

1. Start or attach Herdr, so the session your fleet ran in is up again.
2. Before you reopen the primary firstmate, run:

   ```sh
   fcr resume --dry-run   # see the plan; changes nothing
   fcr resume
   ```

   `--home <dir>` points at a home other than `~/firstmate`, and `--only <task-id>` (or `--only primary`) limits the run to one task.
   `fcr resume` waits up to 30 seconds for Herdr to answer, prints one line per task, and exits nonzero if any resumable task failed.
   Running it twice is safe: anything already running is reported `alive` and left alone.

The primary is included only when `<home>/bin/fm-lock.sh status` reports no live owner, and it is resumed last, after everything it supervises is running again.

### Why before the primary

Run `fcr resume` first.
If you reopen the primary firstmate as a new session first, its startup recovery relaunches every dead second mate as a fresh session straight away, so those second mates lose their conversation.
fcr then sees them running and leaves them alone, as it must.
Workers are not relaunched by firstmate's startup, so fcr still resumes them with their history.
The primary itself is also a new session in that case.

The earlier ids are not lost: each record keeps the last 10 in `previous_sessions`.
To get one of those conversations back by hand:

```sh
jq '.previous_sessions' ~/firstmate/state/<task-id>.claude-session
cd <its cwd> && claude --resume <session-id>
```

## Uninstall

```sh
./uninstall.sh
```

This removes the fcr `SessionStart` entry (backing the settings file up first, and leaving every other hook alone) and the installed `fcr` and `fcr-session-hook`.
It takes the same `--bin-dir` and `--config-dir` options as install.
Recorded session files stay in place, so a reinstall can still resume them.
`--purge` also deletes them, under `~/firstmate` and its second mate homes, or under each `--home <dir>`.
Running it again is safe.

## Limits

- Claude Code only; other harnesses are skipped (reported as `skip`).
- Herdr only; tasks on another backend are skipped.
- Linux only, because the recorder reads the launch argv and environment from `/proc`.
- It does not start anything at boot; you run `fcr resume`.
- It is not a firstmate fork and changes no firstmate file; it only writes the session records next to firstmate's task records and, when a pane had to be re-created, the four placement keys in that task's meta.
- It is a stand-in for [kunchenguid/firstmate#7844](https://github.com/kunchenguid/firstmate/issues/7844); retire it if firstmate ships session resume itself.

## Development

```sh
./tests/run.sh   # hermetic: temp HOME, stub claude and herdr, fixture homes
./lint.sh        # shellcheck
```

The tests never touch a real `~/.claude`, firstmate home or Herdr server.
