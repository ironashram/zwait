# zwait completion-signal hook for zsh.
# Source from .zshrc inside the interactive shell that runs in your zellij pane.
#
# Protocol: before sending a command, the `zwait` helper writes a unique token
# into /tmp/zwait_<session>_expect. preexec fires ONLY when a real command is
# about to run, so it (and only it) claims that token; precmd then records the
# command's exit code into /tmp/zwait_<session>_done_<token>, which the helper
# polls for. Empty Enters, Ctrl-C at an idle prompt, and terminal redraws fire
# precmd but NOT preexec, so they can never claim a token or fake a completion.

if [[ -n "$ZELLIJ_SESSION_NAME" ]]; then
  _zwait_base="/tmp/zwait_${ZELLIJ_SESSION_NAME}"
  _zwait_claim=""
  _zwait_preexec() {
    local exp="${_zwait_base}_expect"
    if [[ -s $exp ]]; then _zwait_claim="$(<$exp)"; : > "$exp"; else _zwait_claim=""; fi
  }
  _zwait_precmd() {
    local rc=$?
    if [[ -n $_zwait_claim ]]; then
      local f="${_zwait_base}_done_${_zwait_claim}"
      print -nr -- "$rc" > "${f}.t" 2>/dev/null && mv -f "${f}.t" "$f" 2>/dev/null
      _zwait_claim=""
    fi
    return $rc
  }
  typeset -ag preexec_functions precmd_functions
  (( ${preexec_functions[(I)_zwait_preexec]} )) || preexec_functions+=(_zwait_preexec)
  # _zwait_precmd must run FIRST so it captures $? before any prompt/git hook clobbers it.
  precmd_functions=(_zwait_precmd ${precmd_functions:#_zwait_precmd})
fi
