# firstmate-claude-resume Strategy

## Vision

<!-- vision: author-approved 2026-11-18 -->

`firstmate-claude-resume` exists so that a reboot or a multiplexer restart costs a firstmate fleet nothing but the background work it was running.
It serves the person running a firstmate fleet on Claude Code, and it turns each recorded session back into the same Claude conversation, in its own folder, pane and launch settings.
It owns exactly one thing: knowing which Claude session each firstmate task was, and bringing that exact session back.

### Exact, never guessed

The session id comes from Claude itself at session start, never from transcript folders, timestamps or the newest file.
The launch argv and environment are read from the session's own running process, never invented.
Translating what was read into the plain `claude` command that runs the same session is allowed, such as peeling a hosting wrapper or a versioned binary path; adding settings the process did not have is not.
A launch layout fcr cannot read exactly is skipped with its reason.
A task with no record is skipped with its reason, not matched by a best guess, and sessions started before the install are simply not covered.
A wrong conversation resumed into a task's pane is worse than no conversation at all.

### Beside firstmate, not inside it

fcr forks nothing and changes no firstmate file, so firstmate updates keep pulling cleanly.
It writes only its own session records next to firstmate's task records and, when a pane had to be re-created, the placement keys in that task's meta.
It follows firstmate's existing conventions (task inbox paths, second mate homes, the primary lock) and asks firstmate for nothing, not even a hook point made for fcr's sake.
It is a stand-in for session resume in firstmate itself, and it retires when firstmate ships that.

### Do no harm to a running fleet

The recorder is silent, makes no network calls and always exits 0, so it can never break or slow a session.
A session already running is reported alive and left alone, so running fcr twice is always safe.
fcr never kills or replaces a live agent, even one it believes is the wrong session.
Anything irreversible, or anything that sets an agent moving, is the narrow default, and the wider behavior is a flag the person passes.
A session is set moving only when its transcript shows it was mid-turn or waiting on background work of its own that the restart killed.
On any other doubt it keeps the pane, stays quiet, or skips, because a quiet session can be prompted later and a moving one cannot be stopped.
A record carries the launch environment the session needs to come back the same, and credentials never enter it: names that look like secrets are dropped.

### The person runs it and sees every decision

fcr is a command the person runs after a restart, before reopening the primary; it does not start itself, and running it at the right time is the person's job.
Every task gets one line saying what happened and why, and `--dry-run` shows the whole plan while changing nothing.
Install and uninstall are one command each, back up what they edit, refuse a malformed settings file, change nothing on a second run, and keep recorded sessions unless purged.

### Proven without touching the real fleet

Tests are hermetic: a temporary home, stub claude and multiplexer, and fixture firstmate homes, never a real Claude config, firstmate home or multiplexer server.
Behavior is driven live against real Claude and a real multiplexer in an isolated session where it can be, and anything not driven live is said so.

### Scope

It is Claude Code only and Linux only; other harnesses are skipped with a reason.
It runs on Herdr today, and another multiplexer firstmate runs on is welcome as a backend that keeps the same placement, alive and blank-pane rules.
It is not a process supervisor, not a boot service, not a fork of firstmate, and not a resume tool for Claude sessions firstmate did not start.
It brings the conversation back; restoring the background jobs, monitors, Workflows and subagents the restart killed is the resumed agent's job once it is told.
It is a small tool its author uses and does not plan to maintain heavily, so a change earns its place by working without ongoing upkeep.

A change aligns when it makes the recorded session more exact or more faithful, lets the resume bring back more of firstmate's own Claude fleet correctly, or makes a decision safer or more visible, all without touching firstmate's files.
A change should be resisted when it guesses a session, edits or asks things of firstmate, kills or doubles a live agent, makes an irreversible or agent-waking step the default, records secrets, starts fcr without the person, or grows fcr past bringing firstmate's Claude sessions back.
