#!/usr/bin/env bash
set -euo pipefail
# Idempotent installer. Rerun freely after updates.
#
#   ./install.sh [phase...]
#
# Phases (default: all):
#   binaries   - bin/* -> $PREFIX/bin
#   shellhook  - shell/zwait.zsh -> $PREFIX/share/zwait + source line in ~/.zshrc
#   zellijcfg  - default_shell "$PREFIX/bin/zshell" in zellij's config.kdl
#                (seeded from examples/zellij-config.kdl when absent)
#   vscodecfg  - merge the zellij terminal profile into VSCode settings.json
#
# PREFIX defaults to /usr/local. Arch package users: the PKGBUILD installs
# the files under /usr, so only the config phases are needed:
#   PREFIX=/usr ./install.sh shellhook zellijcfg vscodecfg

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"

SUDO=""
mkdir -p "$PREFIX" 2>/dev/null || true
[[ -w "$PREFIX" ]] || SUDO=sudo

binaries() {
  $SUDO install -Dm755 "$REPO_DIR"/bin/* -t "$PREFIX/bin"
  echo "binaries -> $PREFIX/bin"
}

shellhook() {
  local dst="$PREFIX/share/zwait/zwait.zsh"
  if ! cmp -s "$REPO_DIR/shell/zwait.zsh" "$dst" 2>/dev/null; then
    $SUDO install -Dm644 "$REPO_DIR/shell/zwait.zsh" "$dst"
  fi
  local line="source $dst"
  grep -qxF "$line" "$HOME/.zshrc" 2>/dev/null || printf '%s\n' "$line" >> "$HOME/.zshrc"
  echo "shell hook -> $dst (sourced from ~/.zshrc)"
}

zellijcfg() {
  local kdl="${XDG_CONFIG_HOME:-$HOME/.config}/zellij/config.kdl"
  local want="default_shell \"$PREFIX/bin/zshell\""
  mkdir -p "$(dirname "$kdl")"
  if [[ ! -f "$kdl" ]]; then
    sed "s|^default_shell .*|$want|" "$REPO_DIR/examples/zellij-config.kdl" > "$kdl"
  elif grep -q '^default_shell ' "$kdl"; then
    grep -qxF "$want" "$kdl" || sed -i "s|^default_shell .*|$want|" "$kdl"
  else
    printf '%s\n' "$want" >> "$kdl"
  fi
  echo "zellij default_shell -> $PREFIX/bin/zshell ($kdl)"
}

vscodecfg() {
  local sj="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/settings.json"
  if ! command -v jq >/dev/null 2>&1; then
    echo "vscodecfg: jq not found - merge examples/vscode-profile.json into $sj by hand" >&2
    return 0
  fi
  mkdir -p "$(dirname "$sj")"
  [[ -f "$sj" ]] || printf '{}\n' > "$sj"
  if ! jq empty "$sj" 2>/dev/null; then
    echo "vscodecfg: $sj is not plain JSON (comments/trailing commas?) - merge examples/vscode-profile.json by hand" >&2
    return 0
  fi
  jq --arg cmd "exec $PREFIX/bin/zvscode" '
    .["terminal.integrated.profiles.linux"].zellij = {path: "/bin/sh", args: ["-c", $cmd]} |
    .["terminal.integrated.defaultProfile.linux"] = "zellij" |
    .["terminal.integrated.shellIntegration.enabled"] = false |
    .["terminal.integrated.enablePersistentSessions"] = false |
    .["terminal.integrated.enableMultiLinePasteWarning"] = "never" |
    .["python.terminal.shellIntegration.enabled"] = false
  ' "$sj" > "$sj.zwait.tmp"
  if cmp -s "$sj" "$sj.zwait.tmp"; then
    rm "$sj.zwait.tmp"
    echo "vscode profile -> $sj (already set)"
  else
    cp "$sj" "$sj.bak.$(date +%s)"
    mv "$sj.zwait.tmp" "$sj"
    echo "vscode profile -> $sj (backup kept)"
  fi
}

phases=("$@")
[[ ${#phases[@]} -eq 0 ]] && phases=(all)
for p in "${phases[@]}"; do
  case "$p" in
    binaries|shellhook|zellijcfg|vscodecfg) "$p" ;;
    all) binaries; shellhook; zellijcfg; vscodecfg ;;
    *) echo "unknown phase '$p' (binaries shellhook zellijcfg vscodecfg all)" >&2; exit 2 ;;
  esac
done
