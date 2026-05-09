# Design notes

The non-obvious choices and why they're made the way they are. If you're
just using `zwait`, you don't need to read this. If you're hacking on it or
porting it to a different terminal multiplexer, you probably do.

## Why a real shared TTY at all

Standard agent shells (Claude Code's Bash tool, Aider's commands, OpenInterpreter's
subprocess) spawn the command without a controlling terminal. That gives you:

- No `isatty()` -> tools downgrade to non-interactive mode (no colors, no
  pagination, often less verbose).
- No `tcgetpgrp` -> some tools refuse to run at all (pinentry, some ssh
  prompts).
- No way for the user to interact mid-command.
- No way for the user to *see* the command unless the agent reports it back.

You can route output to a tail-able log file, but that doesn't fix the TTY
contract or give the user a place to type. The minimum thing that fixes both
is "make the agent's commands run in a TTY the user can see and type into."

zellij is one way to get that: it lets external processes write input
characters to a pane (`action write-chars`) and read the rendered screen back
(`action dump-screen`). tmux has the same primitives (`send-keys` and
`capture-pane`); a port to tmux would change about ten lines of `zwait`.
GNU screen has them too (`stuff` and `hardcopy`).

## Why mtime ticks instead of file content

The completion signal is "the precmd hook ran, which means the previous
command finished." We could express that as:

- A counter file the precmd writes (incrementing each time)
- The exit code itself (precmd writes `$?` to a file)
- A unique marker the precmd writes

All of those work, but they all require comparing *content*, which means
either reading the file twice and diffing, or writing a unique value the
caller knows in advance and waiting for it to appear.

`stat -c %Y` is simpler: it returns a Unix timestamp with second resolution.
Read it before sending the command, poll until it advances, done. No content
comparison, no race between read and write, no unique-marker bookkeeping.

The exit code still gets written to a separate `_rc` file (read once, after
the tick advances), but that's just a value-carrier, not a signal.

The one limitation: two commands that complete within the same second won't
distinguishable by mtime alone. In practice, `zwait` types one command,
waits for it to complete, then exits - so the next `zwait` invocation
re-reads the mtime fresh. Multiple `zwait` calls in flight against the same
session would race, but that's a misuse pattern.

## Why bracketed-paste mode for the write

The command is sent as:

```
ESC [ 200 ~  <command>  ESC [ 201 ~  \n
```

The `ESC [ 200~` / `ESC [ 201~` markers are
[bracketed paste mode](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-Bracketed-Paste-Mode).
Modern shells (zsh's `bracketed-paste-magic`, bash 5.x) treat input between
those markers as a single paste rather than character-by-character keystrokes.
That has two effects:

1. **Multi-line commands paste atomically.** Without bracketed paste, a
   command containing a literal newline gets split: the shell executes the
   first line as soon as it sees the newline, and the rest gets queued or
   becomes a syntax error.
2. **History is clean.** zsh records the entire pasted block as one history
   entry instead of fragmenting it.

The trailing `\n` (sent as a separate `action write 10`) is what actually
runs the pasted command. If you sent the newline inside the bracketed-paste
block, zsh would treat it as a paste-internal newline, not a submit.

## Why the screen-dump regex looks the way it does

`zwait` extracts output by:

1. Dumping the entire visible pane.
2. Finding all lines that start with `$ZWAIT_PROMPT_PREFIX`.
3. The output is "everything between the second-to-last prompt and the last
   prompt, minus the typed command lines themselves."

The `$NLINES` adjustment skips the typed command (which appears right after
the previous prompt). For a one-line command, that's 1 line; for a
heredoc-style multi-line command, more.

This is fragile by design. Any output that itself happens to start with the
prompt prefix will confuse the parser. If your prompt is `$ `, then a command
like `zwait 'echo "\$ hello"'` will produce output starting with `$ `,
which the parser will mistake for a new prompt.

Mitigations:

- Use a distinctive prompt prefix (`❯ `, `┌─[`, your username with a colon).
- Disable shell prompt themes that produce variable-width or color-only
  prompts - the parser sees the rendered text, so ANSI escapes are stripped
  by zellij's `dump-screen`, but if your prompt's first non-escape char
  varies (e.g. shows a different glyph for git-clean vs git-dirty), pick
  the dirty case as the prefix and tolerate occasional clean-case parsing
  oddities.

A more robust alternative would be to have the precmd hook write a unique
sentinel (e.g. a UUID) into the prompt itself, and parse on that. That's a
cleaner v2.

## Why the post-tick "settle" loop

After the tick advances, `zwait` doesn't immediately dump. It does:

```
sleep 0.05
dump
sleep 0.1
dump
sleep 0.2
dump
... up to ~3.4s total
```

Each dump checks "is there a fresh prompt line at position > 1?". The reason:
the precmd hook fires *before* the prompt is rendered. So at the moment the
tick advances, the screen is "command output, then nothing yet, then the
prompt is about to be drawn." If we dump too early, we miss the new prompt
and our regex thinks the command isn't done.

The exponential-backoff polls catch the redraw quickly when it's fast and
gracefully when zsh's prompt computation is slow (git-status-in-prompt,
kubectl-context-in-prompt, etc).

## Why `delete-session --force` has an unfixable race

The example VSCode profile and similar use cases want "if a stale `zwait`
session exists from a crashed previous run, kill it and start fresh." The
naive command:

```sh
zellij delete-session zwait --force
exec zellij attach -c zwait
```

Has a race: `delete-session --force` sends `KillSession` to the running
zellij daemon and *returns immediately*, before the daemon has actually
torn the session down. Then `attach -c` either:

- Reattaches to the dying session (it sees the socket as still present),
  briefly works, then fails when the daemon finishes its kill.
- Or creates a fresh session, depending on timing.

We don't add a polling loop to wait for the socket to disappear because
any delay between profile-launch and `exec zellij` is long enough for
VSCode's terminal subsystem to display the "extension wants to relaunch
terminal" yellow warning. So the profile takes the race and lives with the
~1% case where the new session inherits weirdness.

A robust fix would be to `delete-session --force` *synchronously* (zellij
upstream issue) or to use a different session name each time (which the
example VSCode profile does, indirectly, via the `${workspaceFolderBasename}`
derivation).

## Why locked mode and single-pane

The example VSCode profile sets up zellij with no other panes, often in
locked mode. This is on purpose:

- Multiple panes mean `action write-chars` writes to whichever pane is
  active, which is racy if the user has been clicking around.
- Locked mode disables zellij's keybindings, so an accidental Ctrl-Q
  doesn't kill the session out from under the agent.

If you want zellij's full power inside the same session (multiple panes,
floating windows, etc.), drop the lock and use `zellij action focus-pane`
or pane IDs in your wrapper. That's beyond what `zwait` aims to do.

## Why the helpers are bash, not Python or Go

Three reasons:

1. **No build step.** `git clone && put on PATH` works on any Linux box.
2. **Inspection.** Users who hit a bug can `cat $(which zwait)` and read
   the whole thing. The 70-line awk-and-sleep loop is not magic.
3. **The dependencies are the same anyway.** `zellij`, `awk`, `stat` -
   all already on the system.

The cost: portability is ad-hoc. macOS needs `stat -f %m` instead of `stat
-c %Y`. BSD awk and GNU awk differ on a few edge cases. If `zwait` ever
gets serious adoption, a single-binary Go rewrite would be reasonable.

## What fails on which platforms

- **macOS:** `stat -c %Y` doesn't work. Replace with `stat -f %m`. Otherwise
  fine.
- **WSL:** works, but `/tmp` is per-WSL-instance, so don't try to drive a
  zellij session that's running on the Windows host.
- **non-Linux Unixes (FreeBSD, OpenBSD):** `stat` flags differ. zellij itself
  builds and runs there. Untested.
- **Termux / Android:** zellij is in the Termux repos. `/tmp` works. Untested.
