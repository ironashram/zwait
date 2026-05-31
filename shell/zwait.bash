# zwait completion-signal hook for bash.
# Source from .bashrc inside the interactive shell that runs in your zellij pane.
# Before sending a command, the `zwait` helper writes the path of a per-command
# result file into /tmp/zwait_<session>_current. After the command finishes,
# this hook writes the command's exit code into that file and clears the
# pointer; the helper polls for the file to appear.
#
# Note: bash's PROMPT_COMMAND fires before $? is reset, so we capture it first.

if [ -n "${ZELLIJ_SESSION_NAME:-}" ]; then
  _zwait_capture() {
    local rc=$?
    local cur="/tmp/zwait_${ZELLIJ_SESSION_NAME}_current" target=""
    [ -s "$cur" ] && target=$(cat "$cur" 2>/dev/null)
    if [ -n "$target" ]; then
      printf '%s' "$rc" > "$target" 2>/dev/null
      : > "$cur" 2>/dev/null
    fi
    return $rc
  }
  case ";${PROMPT_COMMAND:-};" in
    *";_zwait_capture;"*) ;;
    *) PROMPT_COMMAND="_zwait_capture${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
  esac
fi
