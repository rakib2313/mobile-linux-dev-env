#!/usr/bin/env bash
# =============================================================================
# mld-code - start code-server (bound to 127.0.0.1) and open it in an app window.
# The random login password is copied to the clipboard (paste with Ctrl+V).
#   mld-code                   start + open
#   mld-code --show-password   print the password and exit
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
mld_enable_traps

CONFIG="$HOME/.config/code-server/config.yaml"
PORT=8080
URL="http://127.0.0.1:${PORT}"
LOG="$HOME/.cache/mld/code-server.log"

get_password() {
  sed -n 's/^password:[[:space:]]*//p' "$CONFIG" | head -n1
}

healthy() {
  curl -fsS -m 2 "${URL}/healthz" >/dev/null 2>&1
}

have_cmd code-server || die "code-server is not installed on this CPU architecture ($(mld_arch))."
[ -f "$CONFIG" ] || die "code-server is not configured yet. Run: bash /opt/mld/scripts/setup-vnc.sh setup"

if [ "${1:-}" = "--show-password" ]; then
  get_password
  exit 0
fi

if ! healthy; then
  if [ -r /etc/mld/profile.conf ]; then
    mld_load_profile /etc/mld/profile.conf
  fi
  mkdir -p "$HOME/projects" "$(dirname "$LOG")"
  NODE_OPTIONS="--max-old-space-size=${MLD_CODE_NODE_MB:-512}" \
    nohup code-server --config "$CONFIG" --disable-telemetry --disable-update-check \
    "$HOME/projects" >>"$LOG" 2>&1 &
  disown "$!" 2>/dev/null || true
  for _ in $(seq 1 80); do
    if healthy; then break; fi
    sleep 0.5
  done
  healthy || die "code-server did not start. See $LOG"
fi

if [ -n "${DISPLAY:-}" ]; then
  if have_cmd xclip; then
    printf '%s' "$(get_password)" | xclip -selection clipboard -i >/dev/null 2>&1 || true
  fi
  if have_cmd chromium; then
    exec chromium "--app=${URL}"
  fi
  exec xdg-open "$URL"
fi

log_info "code-server is running at ${URL}"
log_info "Password: run  mld-code --show-password"
