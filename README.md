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
shell, inside a zellij pane the user has open. The agent observes by polling
zellij's screen-dump; the user observes by, well, looking at the pane.

## How it works

```
+--------------------+               +-------------------+
|  agent process     |               |  user shell       |
|  (no tty)          |               |  (interactive,    |
|                    |               |   inside zellij)  |
|  zwait '<cmd>'  ---|---write------>|                   |
|                    |   chars       |  $ <cmd>          |
|                    |               |  ...output...     |
|                    |               |                   |
|                    |  <-- mtime ---|  precmd hook      |
|                    |     tick      |  writes $? + tick |
|                    |               |                   |
|  dump-screen ----->|               |                   |
|  extract output    |               |                   |
+--------------------+               +-------------------+
```

1. A zellij session is running with one pane attached to an interactive shell.
2. The shell sources `shell/zwait.zsh` (or `.bash`), which adds a `precmd`
   hook that writes `$?` and touches an mtime tick file after every command.
3. From outside the session, `zwait '<cmd>'` types the command into the pane
   via `zellij action write-chars`, then polls the tick file. When the tick
   advances, the command finished. `zwait` dumps the screen, extracts the
   output between the previous prompt and the new one, prints it, and exits
   with the captured `$?`.

The user sees `<cmd>` in their shell history exactly as they would have typed
it. The agent gets clean stdout and a real exit code.

## Requirements

- [zellij](https://zellij.dev/) on `$PATH`
- bash (for the helpers themselves)
- zsh or bash for the interactive shell that runs in the pane
- Linux (uses `stat -c %Y`; macOS users can swap to `stat -f %m`)

## Install

Clone the repo anywhere, then put `bin/` on your `$PATH` and source the
shell hook in your interactive shell's rc file. For example:

```sh
git clone https://github.com/<org>/zwait
cd zwait

# helpers - any directory already on $PATH works
install -m 0755 bin/zwait bin/zr bin/zi /usr/local/bin/

# shell hook for the interactive shell that runs inside the zellij pane
echo "source $(pwd)/shell/zwait.zsh" >> ~/.zshrc      # zsh
echo "source $(pwd)/shell/zwait.bash" >> ~/.bashrc    # bash
```

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
| `ZWAIT_POLL` | `1` | Tick-file poll interval in seconds. |
| `ZWAIT_PROMPT_PREFIX` | `$ ` | First characters of your shell prompt. Used to find prompt boundaries when extracting output. |

The prompt prefix is the trickiest knob. `zwait` decides "where does the
output end and the next prompt begin" by looking for lines that start with
`$ZWAIT_PROMPT_PREFIX`. If your prompt starts with something distinctive
(e.g. `❯ `, `┌─[`, your username, `>>>`), set `ZWAIT_PROMPT_PREFIX` to that.
If your prompt is just `$ ` or `% `, the default works but command lines
that themselves start with `$` could confuse the parser. See
[docs/design.md](docs/design.md) for the parsing logic.

## Things to watch out for

- **The pane must be attached.** If the zellij session has no client, `zwait`
  still types characters but the user won't see them. `zellij list-sessions`
  shows attached state.

- **`exit` and `kill -9 $$` close the pane.** Don't `zwait 'exit'`. The shell
  dies, zellij closes the pane, the next `zwait` call fails.

- **TUIs don't work.** `vim`, `htop`, `less`, anything that takes over the
  screen and expects to control the cursor will confuse the prompt parser.
  Use the pane directly, or use `zr` to inspect state without sending input.

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

## Bash support

Shell hook for bash is in [shell/zwait.bash](shell/zwait.bash). The helpers
themselves are bash scripts and don't care which shell runs in the pane.

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

[docs/design.md](docs/design.md) covers the non-obvious choices: why mtime
ticks instead of file content, why bracketed-paste mode for the command
write, why the screen-dump regex looks the way it does, why
`delete-session --force` has an unfixable race, and what fails on which
platforms.

## License

MIT. See [LICENSE](LICENSE).
