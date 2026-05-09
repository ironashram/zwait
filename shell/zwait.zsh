# zwait completion-signal hook for zsh.
# Source from .zshrc inside the interactive shell that runs in your zellij pane.
# After every command, writes the command's exit code and an mtime tick that
# the `zwait` helper polls from outside the session.

if [[ -n "$ZELLIJ_SESSION_NAME" ]]; then
  _zwait_capture() {
    local rc=$?
    print -nr -- "$rc" > "/tmp/zwait_${ZELLIJ_SESSION_NAME}_rc" 2>/dev/null
    : > "/tmp/zwait_${ZELLIJ_SESSION_NAME}_tick" 2>/dev/null
    return $rc
  }
  typeset -ag precmd_functions
  (( ${precmd_functions[(I)_zwait_capture]} )) || precmd_functions+=(_zwait_capture)
fi
