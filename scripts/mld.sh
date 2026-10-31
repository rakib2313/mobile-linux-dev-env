#!/usr/bin/env bash
# =============================================================================
# mld - day-to-day control for the mobile Linux desktop (runs in Termux)
# Installed to $PREFIX/bin/mld by install.sh
# =============================================================================
set -Eeuo pipefail

MLD_HOME="${MLD_HOME:-$HOME/.mld}"
if [ -r "$MLD_HOME/mld.env" ]; then
  # shellcheck source=/dev/null
  . "$MLD_HOME/mld.env"
fi
: "${MLD_DISTRO:=debian}"
: "${MLD_USER:=dev}"
: "${MLD_SRC:=}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
RUN_DIR="$MLD_HOME/run"
PID_FILE="$RUN_DIR/desktop.pid"
LOG_FILE="$RUN_DIR/desktop.log"
VNC_PORT="${MLD_VNC_PORT:-5901}"

msg() { printf '\033[1;36m[mld]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[mld]\033[0m %s\n' "$*" >&2; }

guest()      { proot-distro login "$MLD_DISTRO" --user "$MLD_USER" --shared-tmp -- "$@"; }
guest_root() { proot-distro login "$MLD_DISTRO" --shared-tmp -- "$@"; }

is_running() {
  local pid
  [ -f "$PID_FILE" ] || return 1
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

port_open() {
  ( exec 3<>"/dev/tcp/127.0.0.1/${VNC_PORT}" ) 2>/dev/null
}

show_connect() {
  cat <<EOF

  Open your VNC viewer app and connect to:  localhost:${VNC_PORT}
  (use the VNC password you chose; stop with: mld stop)

EOF
}

cmd_start() {
  mkdir -p "$RUN_DIR"
  chmod 700 "$RUN_DIR"
  if is_running; then
    msg "Desktop is already running."
    show_connect
    return 0
  fi
  if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock || true; fi
  : >"$LOG_FILE"
  msg "Starting desktop (profile: ${MLD_PROFILE:-auto}) ..."
  nohup proot-distro login "$MLD_DISTRO" --user "$MLD_USER" --shared-tmp -- \
    bash /opt/mld/scripts/setup-vnc.sh run >>"$LOG_FILE" 2>&1 </dev/null &
  echo $! >"$PID_FILE"
  disown "$!" 2>/dev/null || true
  local i
  for i in $(seq 1 60); do
    if port_open; then
      msg "Desktop is up."
      show_connect
      return 0
    fi
    if ! is_running; then break; fi
    sleep 0.5
  done
  err "The desktop did not start. Last log lines:"
  tail -n 20 "$LOG_FILE" >&2 || true
  cmd_stop >/dev/null 2>&1 || true
  return 1
}

cmd_stop() {
  local pid
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then kill "$pid" 2>/dev/null || true; fi
    rm -f "$PID_FILE"
  fi
  sleep 1
  if command -v pkill >/dev/null 2>&1; then
    pkill -f 'setup-vnc.sh run' 2>/dev/null || true
    pkill -x Xtigervnc 2>/dev/null || true
  fi
  rm -f "$PREFIX/tmp/.X1-lock" "$PREFIX/tmp/.X11-unix/X1" 2>/dev/null || true
  if command -v termux-wake-unlock >/dev/null 2>&1; then termux-wake-unlock || true; fi
  msg "Desktop stopped."
}

cmd_status() {
  if is_running && port_open; then
    msg "Desktop: RUNNING  (connect to localhost:${VNC_PORT})"
  elif is_running; then
    msg "Desktop: STARTING (process alive, port not open yet)"
  else
    msg "Desktop: stopped"
  fi
}

cmd_update() {
  [ -n "$MLD_SRC" ] && [ -d "$MLD_SRC/.git" ] || { err "No git checkout recorded; re-run the installer one-liner."; return 1; }
  git -C "$MLD_SRC" pull --ff-only
  bash "$MLD_SRC/scripts/install.sh" --refresh
}

cmd_autostart() {
  local boot="$HOME/.termux/boot/mld-start.sh"
  case "${1:-}" in
    on)
      mkdir -p "$(dirname "$boot")"
      printf '#!/data/data/com.termux/files/usr/bin/sh\ntermux-wake-lock\nmld start\n' >"$boot"
      chmod 700 "$boot"
      msg "Autostart enabled (requires the Termux:Boot app)." ;;
    off)
      rm -f "$boot"
      msg "Autostart disabled." ;;
    *) err "Usage: mld autostart on|off"; return 1 ;;
  esac
}

cmd_help() {
  cat <<'EOF'
mld - mobile Linux desktop control

  mld start              Start the desktop (VNC on localhost:5901)
  mld stop               Stop the desktop
  mld restart            Stop, then start
  mld status             Show whether the desktop is running
  mld passwd             Change the VNC password
  mld resolution WxH     Set screen size, e.g. 1280x720 (restart afterwards)
  mld shell              Open a terminal in the Linux environment (user)
  mld root               Open a root shell in the Linux environment
  mld ai [args]          AI coding helper (configure | ask | chat | fix)
  mld code-password      Print the code-server login password
  mld autostart on|off   Start the desktop when the phone boots (Termux:Boot)
  mld update             Pull the latest version and re-apply configs
  mld uninstall          Remove everything installed by this project
  mld version            Print version info
EOF
}

main() {
  local cmd="${1:-help}"
  if [ $# -gt 0 ]; then shift; fi
  case "$cmd" in
    start)         cmd_start ;;
    stop)          cmd_stop ;;
    restart)       cmd_stop; cmd_start ;;
    status)        cmd_status ;;
    passwd)        guest bash /opt/mld/scripts/setup-vnc.sh passwd ;;
    resolution)    guest bash /opt/mld/scripts/setup-vnc.sh resolution "${1:-}" ;;
    shell)         proot-distro login "$MLD_DISTRO" --user "$MLD_USER" --shared-tmp ;;
    root)          proot-distro login "$MLD_DISTRO" --shared-tmp ;;
    ai)            guest bash /opt/mld/scripts/ai-assistant.sh "$@" ;;
    code-password) guest bash /opt/mld/scripts/guest/mld-code.sh --show-password ;;
    autostart)     cmd_autostart "${1:-}" ;;
    update)        cmd_update ;;
    uninstall)     bash "$MLD_HOME/scripts/uninstall.sh" "$@" ;;
    version|-v|--version) echo "mobile-linux-dev-env 1.0.0" ;;
    help|-h|--help) cmd_help ;;
    *) err "Unknown command: $cmd"; cmd_help; exit 1 ;;
  esac
}

main "$@"
