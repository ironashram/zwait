# Agent instructions snippet

Drop this into your `CLAUDE.md` (or `AGENTS.md`, `.cursorrules`, whatever
your agent reads) when zwait is set up. The exact wording matters: agents
take "always" and "never" literally, and one-shot exceptions tend to drift
into general behavior over a long session.

---

- VS Code terminal visibility via zellij: each VSCode window opens its own
  zellij session, named by `zvscode` (`vscode-<folder>` for a single-folder
  window, `vscode-<workspace file basename>` for a multi-root workspace).
  The helpers (`zwait`, `zr`, `zi` on `$PATH`) target the right window's
  session automatically via `zsession`, which matches your cwd against the
  workspace mappings the launcher recorded - never assume or hardcode a
  session name.

- **Always route shell commands through the helpers** so commands execute
  in the user's visible pane. Never probe for the session first - if the
  matching session does not exist, the helper will fail loudly and the user
  will open one.

- The helpers:
  - `zwait '<cmd>'` is the default. Types only the bare command into the
    pane (so the user's shell history shows their original cmd verbatim),
    waits for completion via preexec/precmd hooks that record the exit
    code in a per-command file, then returns the command's exact output
    (sliced from a pty byte log between invisible per-command markers;
    nothing is scraped off the screen, so any prompt theme, partial-line
    output, or huge output is handled exactly) and propagates the exit
    code.
    If `zwait` fails with "no typescript log", the pane is not running
    under the `zshell` wrapper - ask the user to open a fresh pane. Do
    not retry, and do not fall back to plain Bash.
    Default timeout 120s. The 120s is purely a visibility cap on your
    side, not a command lifetime cap. When it trips, the helper returns
    "timeout after 120s" with rc 124, but the underlying command keeps
    running in the pane. So: do not hesitate over commands that may run
    longer than 120s - just call `zwait`. Override `ZWAIT_TIMEOUT` per
    call only when you genuinely want the helper to keep blocking past
    120s to capture rc and final output cleanly.

  - `zr` dumps the current screen without sending anything (`zr -f`
    includes scrollback). Useful for polling state between writes or
    inspecting a long-running process.

  - `zi '<text>'` types `text` into the active pane without pressing
    Enter. For interactive prompts (fzf search, partial command edits,
    anything expecting input but not a newline).

  - `zspawn '<cmd>'` runs a never-returning command (`tail -f`,
    `journalctl -f`, a dev server) in its own detached window and returns
    immediately, printing a throwaway session name. Read it with
    `zellij -s <name> action dump-screen` (`-f` for scrollback), stop it
    with `zellij delete-session <name> --force`. `ztail <file>` is the
    `tail -F` shorthand.

  - For raw special keys, use `zellij -s "$(zsession)" action write
    <byte>` (3=Ctrl-C, 10=Enter, 27=Esc).

- **Never use plain Bash.** Every shell command goes through `zwait` (or
  `zr`/`zi` for their specific niches). No fallback list, no exceptions.
  If a command is incompatible with `zwait` (TUI/interactive like
  `vim`/`less`/`htop`, needs stdin like password prompts, or would kill
  the shell like `exit`/`kill -9 $$`, which closes the pane and the
  session), do not run it - print the command for the user to run
  themselves instead. Never-returning watchers (`tail -f`,
  `journalctl -f`, dev servers) go through `zspawn`/`ztail`, not `zwait`.

- **One command per `zwait` call.** Do not chain with `&&`, `;`, `||`, `&`,
  or pipe-fan-outs to bundle unrelated probes. Each logical operation
  gets its own `zwait` invocation so the user can see each command and
  its output cleanly in the pane and in shell history. Real pipelines
  (`cmd | grep`) are fine when they form a single logical operation;
  chaining `cmd1 && cmd2 && echo ---` to inspect multiple things is not.
  If you need parallel probes, fire multiple `zwait` tool calls in the
  same assistant message.

- **Never pipe to `| tail` or `| head` to trim output for "tidiness".**
  They discard lines mid-pipeline so neither the user nor the pane ever
  see the dropped part. If a command is noisy, filter with `grep` for
  the relevant signal, or run it raw and read the full output. The only
  legitimate uses are when the command is literally "show me just the
  first/last N lines" as the actual question.

- **Always use `git --no-pager <subcommand>`** for any pager-invoking
  git command (`diff`, `log`, `show`, `blame`, `stash show`, `reflog`,
  `shortlog`) when running through `zwait`. The zellij pane is a real
  TTY, so git auto-pipes through `less` and the command sits waiting for
  `q`. Plain `git status`, `git add`, `git commit` do not page and do not
  need the flag.
