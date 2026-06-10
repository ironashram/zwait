# zwait completion-signal and output-marker hooks for zsh.
# Source from .zshrc inside the interactive shell that runs in your zellij pane
# (which itself must be launched by bin/zshell - see README).
#
# Protocol: before sending a command, the `zwait` helper writes a unique token
# into /tmp/zwait_<session>_expect. preexec fires ONLY when a real command is
# about to run, so it (and only it) claims that token; precmd then records the
# command's exit code into /tmp/zwait_<session>_done_<token>, which the helper
# polls for. Empty Enters, Ctrl-C at an idle prompt, and terminal redraws fire
# precmd but NOT preexec, so they can never claim a token or fake a completion.
#
# Two additions on top of the completion signal:
#
# - A _busy flag, created by every preexec and removed by every precmd, lets
#   the helper detect an idle prompt without reading the screen.
# - On claimed commands the hooks print invisible APC escape markers
#   (ESC _ zwS<token> ESC \ before, ESC _ zwE<token> ESC \ after). Terminals
#   ignore APC, so nothing renders - but the script(1) wrapper logs the raw
#   bytes, and the pty stream orders them strictly between the command echo
#   and the next prompt. The helper slices the command's exact output from
#   the log between them.

if [[ -n "$ZELLIJ_SESSION_NAME" ]]; then
  _zwait_base="/tmp/zwait_${ZELLIJ_SESSION_NAME}"
  _zwait_claim=""
  _zwait_preexec() {
    : > "${_zwait_base}_busy" 2>/dev/null
    local exp="${_zwait_base}_expect"
    if [[ -s $exp ]]; then
      _zwait_claim="$(<$exp)"; : > "$exp"
      print -n -- $'\e_zwS'"${_zwait_claim}"$'\e\\'
    else
      _zwait_claim=""
    fi
  }
  _zwait_precmd() {
    local rc=$?
    rm -f "${_zwait_base}_busy" 2>/dev/null
    if [[ -n $_zwait_claim ]]; then
      print -n -- $'\e_zwE'"${_zwait_claim}"$'\e\\'
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
