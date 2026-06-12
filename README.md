# zwait

Drive a user's visible terminal pane from a headless agent. Three small helpers
plus a shell hook turn a [zellij](https://zellij.dev/) session into a shared
TTY: an automation tool (Claude Code, Aider, your own script) sends commands
into the pane via `zwait`, and the user watches the same output you do, with
their normal shell history.

## The problem

When an LLM agent runs shell commands, it usually spawns a subprocess with no
TTY. Two things break:

1. The user can't see what the agent did. They get a diff at the end. They
   don't see the `kubectl get pods` output that informed the next decision,
   the long compile log, or the password prompt that the agent is now stuck
   on.
2. The agent can't drive interactive tools that need a real TTY: `git
   commit -S` (pinentry), `ssh` (password / 2FA), `fzf`, anything that wants
   to redraw the screen.

`zwait` fixes both by making the agent's commands run in the user's actual
shell, inside a zellij pane the user has open. The agent gets the command's
exact output from a pty byte log; the user observes by, well, looking at the
pane.

## How it works

```
+--------------------+               +-------------------+
|  agent process     |               |  user shell       |
|  (no tty)          |               |  (zsh under       |
|                    |               |   script(1),      |
|  zwait '<cmd>'  ---|---write------>|   inside zellij)  |
|                    |   chars       |                   |
|                    |               |  $ <cmd>          |
|                    |               |  ...output...     |
|                    |  <- result ---|  precmd hook      |
|                    |     file      |  writes $? to it  |
|                    |               |                   |
|  slice byte log <--|---------------|  script(1) logs   |
|  between markers   |               |  the pty stream   |
+--------------------+               +-------------------+
```

1. zellij's `default_shell` is `bin/zshell`, which runs the interactive zsh
   under `script(1)`, logging the pane's raw pty byte stream to a
   per-instance typescript behind the `/tmp/zwait_<session>_log` symlink.
2. The shell sources `shell/zwait.zsh`. Its `preexec`/`precmd` hooks do three
   things: claim the per-command token `zwait` wrote before sending (preexec
   fires only when a real command runs, so empty Enters and redraws can't fake
   a completion, and precmd writes the command's `$?` into the result file
   named for that token); maintain a `_busy` flag so the helper can tell the
   pane is idle without reading the screen; and print invisible APC escape
   markers around each claimed command. Terminals ignore APC so nothing
   renders - but script(1) logs the raw bytes, and the pty stream orders them
   strictly between the command echo and the next prompt.
3. From outside the session, `zwait '<cmd>'` waits for the busy flag to clear,
   types the command into the pane via `zellij action write-chars`, polls for
   its result file, then slices the command's exact output bytes out of the
   log between its two markers, renders them (escape stripping,
   carriage-return overwrites), prints the result and exits with the captured
   `$?`. Concurrent `zwait` calls against the same session are serialized by a
   per-session lock, so a batch of calls can't garble the shared pane.

The user sees `<cmd>` in their shell history exactly as they would have typed
it. The agent gets clean stdout and a real exit code.

There is no screen scraping and no prompt-pattern matching anywhere: the
output is a byte range in an append-only log, delimited by nonce-keyed
markers. Prompt themes, line wrapping, partial lines (output without a
trailing newline), and zellij's scrollback limit are all irrelevant by
construction.

## Requirements

- [zellij](https://zellij.dev/) on `$PATH`
- bash (for the helpers themselves)
- zsh for the interactive shell that runs in the pane (needs `preexec`/`precmd`)
- Linux (the per-session lock uses util-linux `flock`; the pty log uses
  util-linux `script`)

## Install

Clone the repo anywhere, put `bin/` on your `$PATH`, source the shell hook in
your interactive shell's rc file, and set `bin/zshell` as zellij's default
shell. For example:

```sh
git clone https://github.com/<org>/zwait
cd zwait

# helpers - any directory already on $PATH works
install -m 0755 bin/zwait bin/zr bin/zi bin/zshell /usr/local/bin/

# shell hook for the interactive shell that runs inside the zellij pane
echo "source $(pwd)/shell/zwait.zsh" >> ~/.zshrc

# pane shells must run under the script(1) wrapper
echo 'default_shell "/usr/local/bin/zshell"' >> ~/.config/zellij/config.kdl
```

Panes opened before `default_shell` was wired in have no byte log; `zwait`
refuses to drive them ("no typescript log") - open a fresh pane.

Then start a zellij session your agent will use:

```sh
zellij attach -c zwait
```

And from your agent (or another terminal):

```sh
zwait 'ls -la'
zwait 'kubectl get pods -n kube-system'
```

Default session name is `zwait`. Override with `ZELLIJ_SESSION=<name>` per
call, or `export ZELLIJ_SESSION=<name>` once.

## The three helpers

- `zwait '<cmd>'` - type one command into the pane, wait for completion,
  return its stdout and exit code. Default timeout 120s (override with
  `ZWAIT_TIMEOUT=300`). The 120s is a visibility cap on the helper, not a
  command lifetime cap: if it times out, the underlying command keeps
  running in the pane and the user can interact with it normally.

- `zr` - dump the current screen without sending anything. `zr -f` includes
  scrollback. Useful for polling state between writes or inspecting a
  long-running process.

- `zi '<text>'` - type text into the active pane without pressing Enter.
  For interactive prompts (fzf search, partial command edits, anything
  expecting input but not a newline). For raw bytes (Ctrl-C, Esc):
  `zellij -s "$ZELLIJ_SESSION" action write 3` (3 = Ctrl-C, 10 = Enter,
  27 = Esc).

## Configuration

Environment variables:

| Variable | Default | Effect |
|---|---|---|
| `ZELLIJ_SESSION` | `zwait` | Session name to target. |
| `ZWAIT_TIMEOUT` | `120` | Seconds before `zwait` gives up (command keeps running). |
| `ZWAIT_POLL` | `1` | Result-file poll interval in seconds. |

There is no prompt configuration: output extraction is keyed on invisible
per-command markers in the pty byte log, so any prompt theme works untouched.

**The byte log records everything displayed in the pane** - including output
of commands the user types by hand - in plaintext at
`/tmp/zwait_<session>_log` (a symlink to a fresh per-instance `_log_<pid>`
file, mode 0600, created every time a pane starts; older instances' files
are removed).
Typed *input* is never logged, so hidden prompts (sudo/gpg/ssh passphrases)
don't leak into it. On most distros `/tmp` is tmpfs: RAM-backed, gone at
reboot.

## Things to watch out for

- **Parallel calls are safe but serialized.** Multiple `zwait` calls against
  the same session (e.g. an agent firing a batch in one message) won't corrupt
  the pane - a per-session lock runs them one at a time. No speedup from
  parallelism on a single pane, just safety.

- **The pane must be attached.** If the zellij session has no client, `zwait`
  still types characters but the user won't see them. `zellij list-sessions`
  shows attached state.

- **`exit` and `kill -9 $$` close the pane.** Don't `zwait 'exit'`. The shell
  dies, zellij closes the pane, the next `zwait` call fails.

- **TUIs don't make sense through `zwait`.** `vim`, `htop`, `less` work fine
  when the user runs them directly in the pane (it's a real tty all the way
  down), but driving one via `zwait` returns its raw redraw churn rendered to
  noise - the renderer handles carriage-return overwrites, not full-screen
  cursor addressing. Use the pane directly, or `zr` to inspect state without
  sending input.

- **Commands that never return.** `tail -f`, dev servers, etc. Use a
  `--timeout` flag on the command itself, or run it in the background
  (`zwait 'cmd &'`), or accept that `zwait` will hit its timeout and the
  user can Ctrl-C in the pane.

- **VSCode env-mismatch warning (Claude Code users only).** If you drive
  zwait from Claude Code's VSCode extension, you may see a yellow
  "extension wants to relaunch terminal" banner when reloading the
  terminal pane. It's harmless - the Claude Code extension contributes a
  random `CLAUDE_CODE_SSE_PORT` env var on each activation and VSCode
  flags the change. The `enablePersistentSessions: false` setting in
  [examples/vscode-profile.json](examples/vscode-profile.json) reduces
  the noise; fully suppressing it requires a small custom VSCode
  extension that no-ops `ScopedEnvironmentVariableCollection.replace()`
  for that key. Out of scope for this repo.

## Mirroring from another terminal

The zellij session is just a regular zellij session - nothing about it is
VSCode-specific once it exists. From any external terminal:

```sh
zellij attach <session-name>
```

You'll see everything that happens in the VSCode (or whatever) pane,
mirrored live. Useful for dual-monitor setups where the editor lives on
one screen and you want to watch the agent's commands on the other.

`zwait` itself doesn't care which client is attached, or how many - it
targets the session by name. Multiple clients mirror by default in zellij.

Caveats:

- **Order matters with the VSCode profile.** If you launch zellij
  externally first and then open the matching VSCode workspace, VSCode's
  profile runs `delete-session --force` and kills your external session.
  Open VSCode first, attach externally second.
- **VSCode reloads kill the external attach.** Reload Window, extension
  updates, or closing and reopening the workspace all re-run the profile,
  which re-creates the session and drops the external client. Re-attach.
- **Detach, don't close.** `Ctrl-o d` in the external client detaches
  cleanly without killing the session. Closing the terminal window works
  too but is rougher.
- **Locked mode is session-wide, not per-client.** If the pane is in
  locked mode for the editor's sake, `Ctrl-g` from the external client
  toggles it for everyone (including the editor pane). Convenient when you
  want to type from outside; surprising the first time it happens.
- **Set `ZELLIJ_SESSION` from the external shell.** The public `zwait`
  defaults to a session literally named `zwait`. If your VSCode profile
  uses a per-workspace name like `vscode-myrepo`, point `zwait` at it
  with `ZELLIJ_SESSION=vscode-myrepo zwait '...'` (or `export
  ZELLIJ_SESSION=...` once per terminal).

## Examples

- [examples/vscode-profile.json](examples/vscode-profile.json) - VSCode
  terminal profile that auto-launches a per-workspace zellij session, so each
  VSCode window gets its own pane that doesn't conflict with other windows.

- [examples/claude-md-snippet.md](examples/claude-md-snippet.md) - drop-in
  block for `CLAUDE.md` (or equivalent agent instructions) that teaches the
  agent the rules: route everything through `zwait`, one command per call,
  no `| head` / `| tail` for tidiness, `git --no-pager` for paginated
  subcommands.

## Design

[docs/design.md](docs/design.md) covers the non-obvious choices: why a
preexec-claimed token (and a per-session lock) instead of an mtime tick or a
precmd-consumed pointer, why bracketed-paste mode for the command write, why
output comes from a pty byte log sliced between invisible APC markers instead
of screen scraping, why `delete-session --force` has an unfixable race, and
what fails on which platforms.

## License

MIT. See [LICENSE](LICENSE).
