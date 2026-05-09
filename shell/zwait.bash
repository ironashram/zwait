# zwait completion-signal hook for bash.
# Source from .bashrc inside the interactive shell that runs in your zellij pane.
# After every command, writes the command's exit code and an mtime tick that
# the `zwait` helper polls from outside the session.
#
# Note: bash's PROMPT_COMMAND fires before $? is reset, so we capture it first.

if [ -n "${ZELLIJ_SESSION_NAME:-}" ]; then
  _zwait_capture() {
    local rc=$?
    printf '%s' "$rc" > "/tmp/zwait_${ZELLIJ_SESSION_NAME}_rc" 2>/dev/null
    : > "/tmp/zwait_${ZELLIJ_SESSION_NAME}_tick" 2>/dev/null
    return $rc
  }
  case ";${PROMPT_COMMAND:-};" in
    *";_zwait_capture;"*) ;;
    *) PROMPT_COMMAND="_zwait_capture${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
  esac
fi
