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
characters to a pane (`action write-chars`). tmux has the same primitive
(`send-keys`); a port to tmux would change about ten lines of `zwait`.
GNU screen has it too (`stuff`). Output capture is multiplexer-independent:
it comes from a `script(1)` pty log, not from the multiplexer's screen
buffer.

## Why a preexec-claimed token

The completion signal is "a real command finished." The subtlety is matching a
generic shell-hook firing to the *specific* command `zwait` sent. `zwait`
allocates a unique token under the lock (`/tmp/zwait_<session>_seq`, a monotonic
counter, never reused) and writes it into `/tmp/zwait_<session>_expect` right
before sending the command. The shell's `preexec` hook - which fires *only* when
a real command is about to run - claims that token; the `precmd` hook then writes
the command's exit code into `/tmp/zwait_<session>_done_<token>` (via a temp file
plus atomic rename, so a reader never sees a half-written or zero-byte file). The
helper polls for *its own* done file.

The earlier design consumed a single shared pointer inside `precmd` instead:
`zwait` wrote the result path into `_current`, and `precmd` read-and-cleared it.
That looks per-command but isn't, because `precmd` fires on *every* prompt
redraw - empty Enter, Ctrl-C at an idle prompt, a late repaint of the previous
command's prompt. Any such spurious `precmd` between "zwait armed the pointer"
and "the real command finished" consumes the pointer: it either writes the wrong
(previous) exit code, returning a premature/empty result, or clears the slot so
the real command's `precmd` no-ops and the helper hangs until timeout. Gating the
claim on `preexec` closes this entirely - empty Enters and redraws fire `precmd`
but never `preexec`, so they can't claim a token, and the exit code is paired with
the token at the moment the command actually finishes.

An even earlier version used `stat -c %Y` on a shared tick file (read mtime
before sending, poll until it advances). Two problems the token doesn't have:

- **Second resolution.** Two commands that complete within the same wall-clock
  second are indistinguishable by mtime, so a fast command right after another
  could be missed. Token files have no such ambiguity.
- **No attribution.** A shared tick can't tell *which* command finished, and two
  in-flight calls clobber each other's signal. The per-session lock serializes
  callers and the per-token file isolates results.

## Why a per-session lock and idle guard

All calls against one session type into the same pane, so two writers would
interleave keystrokes on the same input line. `zwait` takes an exclusive
`flock` on `/tmp/zwait_<session>_lock` (util-linux `flock`) for the whole
send-and-wait critical section. Concurrent calls then serialize: each runs to
completion in turn. There is no wall-clock speedup on a single pane - the point
is safety, so batching independent calls can't corrupt the pane.

The lock alone isn't enough for one edge case: if a call hits its timeout and
exits (releasing the lock) while its command is still running, the next call
would acquire the lock and type into a busy pane. So after acquiring the lock,
`zwait` waits (bounded by `ZWAIT_TIMEOUT`) for the hook-maintained `_busy`
flag to clear: every `preexec` creates it, every `precmd` removes it, so its
absence means the shell is back at a prompt. No screen read involved. If the
pane never goes idle in time, the call bails with rc 124 instead of typing
into a running command. The `zshell` wrapper removes a stale flag at pane
start, so a crashed shell can't deadlock the check.

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

## Why a pty byte log sliced between APC markers

Earlier versions extracted output by dumping the rendered screen and finding
prompt lines by a configurable prefix (`ZWAIT_PROMPT_PREFIX`). That was
fragile by design and broke in practice: any output line starting with the
prefix confused the parser, and - the bug that killed the approach - a
command whose output has no trailing newline makes the shell draw the next
prompt mid-row, where a line-anchored prefix check can't see it. One such
command silently corrupted extraction and wedged every subsequent call's
idle check. It also inherited the multiplexer's limits: hard wrapping at
pane width, and silent truncation at the scrollback ceiling.

The current design removes the screen from the read path entirely:

1. `zshell` runs the pane's zsh under `script(1)`, which logs the raw pty
   byte stream to `/tmp/zwait_<session>_log`.
2. When the preexec hook claims a token, it prints `ESC _ zwS<token> ESC \`;
   when precmd finishes that command, it prints `ESC _ zwE<token> ESC \`.
   These are APC (Application Program Command) escape sequences: terminals
   ignore them, so nothing renders and the user sees a byte-identical pane -
   but `script` sits *below* the terminal and logs them raw.
3. The pty stream is a single ordered pipe, so the start marker lands after
   the command echo and the end marker lands before the prompt redraw - by
   construction, not by parsing. `zwait` greps the log tail (from the size it
   recorded before typing) for its two nonce-keyed markers and slices the
   bytes between them. The nonce makes collision with genuine output
   practically impossible: output would have to contain the raw ESC sequence
   with the current counter value.

The slice is pre-render terminal bytes, so `zwait` post-processes it: strip
OSC/APC/CSI escapes, emulate carriage-return overwrites within each line
(progress bars collapse to their final frame), drop zsh's partial-line `%`
marker when it stands alone, trim blank edge lines. The one known artifact
class: full-screen cursor-addressed output (TUIs, multi-line progress
redraws) renders to noise - the renderer is line-oriented, not a terminal
emulator. For everything zwait is meant to run, the slice is exact.

Why not capture by redirecting the command's stdout through `tee` in the
hooks instead? Because that replaces the command's tty with a pipe: colors
vanish from the user's pane, pagers and `isatty()`-keyed behavior change.
The `script` layer keeps a real pty end-to-end - pinentry, sudo prompts, ssh
all behave normally, and hidden input (passphrases) never enters the log
because only the output direction is recorded.

## Why the post-completion "settle" loop

After the done file appears, `zwait` retries the marker search with a short
exponential backoff (0 to ~3.2s total). The reason: `script`'s copy loop is
asynchronous, so the end marker may still be in flight between the pty and
the log file for a few milliseconds after precmd writes the done file. The
first attempt (no sleep) almost always succeeds; the backoff covers a loaded
machine. This is also why the hooks print markers rather than recording log
byte offsets via `stat`: an offset sampled in precmd can land before the
command's final bytes have been drained into the log, silently clipping the
tail. The marker is part of the stream itself, so it can't be reordered
relative to the output.

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
3. **The dependencies are the same anyway.** `zellij`, `awk`, `flock` -
   all already on the system.

The cost: portability is ad-hoc. The lock uses util-linux `flock`, which
BSD/macOS don't ship. BSD awk and GNU awk differ on a few edge cases. If
`zwait` ever gets serious adoption, a single-binary Go rewrite would be
reasonable.

## What fails on which platforms

- **macOS:** no util-linux `flock` (BSD `flock` differs); the lock needs
  adapting or removing. BSD `script` exists but takes different flags
  (`script -qF` instead of `-fqe -c`); `zshell` needs a small port. GNU
  `dd`'s `iflag=skip_bytes,count_bytes` and `grep -abo` also need BSD
  equivalents. Completion detection is just file existence and works.
- **WSL:** works, but `/tmp` is per-WSL-instance, so don't try to drive a
  zellij session that's running on the Windows host.
- **non-Linux Unixes (FreeBSD, OpenBSD):** `flock` and a few `awk` edge cases
  differ. zellij itself builds and runs there. Untested.
- **Termux / Android:** zellij is in the Termux repos. `/tmp` works. Untested.
