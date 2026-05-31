# zwait completion-signal hook for zsh.
# Source from .zshrc inside the interactive shell that runs in your zellij pane.
# Before sending a command, the `zwait` helper writes the path of a per-command
# result file into /tmp/zwait_<session>_current. After the command finishes,
# this hook writes the command's exit code into that file and clears the
# pointer; the helper polls for the file to appear.

if [[ -n "$ZELLIJ_SESSION_NAME" ]]; then
  _zwait_capture() {
    local rc=$?
    local cur="/tmp/zwait_${ZELLIJ_SESSION_NAME}_current" target=""
    [[ -s $cur ]] && target="$(<$cur)"
    if [[ -n $target ]]; then
      print -nr -- "$rc" > "$target" 2>/dev/null
      : > "$cur" 2>/dev/null
    fi
    return $rc
  }
  typeset -ag precmd_functions
  (( ${precmd_functions[(I)_zwait_capture]} )) || precmd_functions+=(_zwait_capture)
fi
