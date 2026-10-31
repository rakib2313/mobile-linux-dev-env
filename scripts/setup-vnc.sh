#!/usr/bin/env bash
# =============================================================================
# setup-vnc.sh - VNC + desktop setup/runtime (runs INSIDE Debian, as normal user)
#   setup              first-time config: password, xstartup, XFCE tweaks,
#                      shortcuts, code-server config, starter project
#   run                start Xtigervnc + XFCE in the foreground (used by `mld start`)
#   stop | status      manage the running session
#   passwd             change the VNC password
#   resolution WxH     persist a custom screen size
# VNC listens on 127.0.0.1 only (set MLD_VNC_LAN=1 to override - not recommended).
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
mld_enable_traps

OPT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VNC_DIR="$HOME/.vnc"
USER_CONF="$HOME/.config/mld/user.conf"
CACHE_DIR="$HOME/.cache/mld"
DISPLAY_NUM=1
PORT=5901
X_PID=""
S_PID=""

require_user() {
  [ "$(id -u)" -ne 0 ] || die "Run this as the desktop user, not root (use: mld start / mld passwd)."
}

load_settings() {
  if [ -r /etc/mld/profile.conf ]; then
    mld_load_profile /etc/mld/profile.conf
  else
    mld_load_profile "$OPT_DIR/configs/profiles/active.conf"
  fi
  if [ -r "$USER_CONF" ]; then
    mld_load_profile "$USER_CONF"
  fi
  : "${MLD_VNC_GEOMETRY:=1280x720}"
  : "${MLD_VNC_DEPTH:=16}"
  : "${MLD_COMPOSITING:=false}"
  : "${MLD_VNC_DISPLAY:=1}"
  [[ "$MLD_VNC_GEOMETRY" =~ ^[0-9]{3,4}x[0-9]{3,4}$ ]] || die "Invalid geometry: $MLD_VNC_GEOMETRY"
  [[ "$MLD_VNC_DEPTH" =~ ^(8|16|24|32)$ ]] || die "Invalid colour depth: $MLD_VNC_DEPTH"
  [[ "$MLD_VNC_DISPLAY" =~ ^[0-9]+$ ]] || die "Invalid display number: $MLD_VNC_DISPLAY"
  DISPLAY_NUM="$MLD_VNC_DISPLAY"
  PORT=$((5900 + DISPLAY_NUM))
  mkdir -p "$CACHE_DIR"
}

# ---- password ---------------------------------------------------------------
set_password() {
  local pw="" confirm="" pwfile="/mnt/handoff/vncpw"
  ( umask 077; mkdir -p "$VNC_DIR" )
  chmod 700 "$VNC_DIR"
  if [ -r "$pwfile" ]; then
    pw="$(head -n1 "$pwfile")"
    rm -f "$pwfile"
  elif [ -n "${MLD_VNC_PASSWORD:-}" ]; then
    pw="$MLD_VNC_PASSWORD"
  elif mld_tty >/dev/null; then
    while :; do
      mld_prompt_secret "Choose a VNC password (6-8 characters)" pw || die "No interactive terminal available."
      mld_prompt_secret "Repeat the password" confirm || die "No interactive terminal available."
      if [ "${#pw}" -lt 6 ]; then
        log_warn "Password is too short (minimum 6 characters)."
        continue
      fi
      if [ "$pw" != "$confirm" ]; then
        log_warn "Passwords do not match - try again."
        continue
      fi
      break
    done
  else
    pw="$(openssl rand -hex 4)"
    log_warn "No terminal available. Generated one-time VNC password: ${pw}  (change it with: mld passwd)"
  fi
  if [ "${#pw}" -gt 8 ]; then
    log_warn "VNC only uses the first 8 characters of a password."
  fi
  printf '%s\n' "$pw" | vncpasswd -f >"$VNC_DIR/passwd"
  chmod 600 "$VNC_DIR/passwd"
  pw=""; confirm=""
  log_ok "VNC password saved (file mode 600)."
}

# ---- config writers ---------------------------------------------------------
write_xstartup() {
  install -m 755 "$OPT_DIR/configs/vnc/xstartup" "$VNC_DIR/xstartup"
  log_ok "Installed ~/.vnc/xstartup"
}

write_xfce_defaults() {
  local d="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml" comp=false
  mkdir -p "$d"
  if [ "$MLD_COMPOSITING" = "true" ]; then comp=true; fi
  if [ ! -f "$d/xfwm4.xml" ]; then
    cat >"$d/xfwm4.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="${comp}"/>
    <property name="show_dock_shadow" type="bool" value="false"/>
    <property name="show_frame_shadow" type="bool" value="false"/>
    <property name="show_popup_shadow" type="bool" value="false"/>
    <property name="sync_to_vblank" type="bool" value="false"/>
    <property name="workspace_count" type="int" value="2"/>
    <property name="easy_click" type="string" value="Alt"/>
  </property>
</channel>
EOF
  fi
  if [ ! -f "$d/xfce4-session.xml" ]; then
    cat >"$d/xfce4-session.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-session" version="1.0">
  <property name="general" type="empty">
    <property name="SaveOnExit" type="bool" value="false"/>
  </property>
</channel>
EOF
  fi
  log_ok "XFCE tuned (compositing: ${comp})"
}

write_code_server_config() {
  local cfg_dir="$HOME/.config/code-server" settings_dir="$HOME/.local/share/code-server/User"
  ( umask 077; mkdir -p "$cfg_dir" )
  chmod 700 "$cfg_dir"
  if [ ! -f "$cfg_dir/config.yaml" ]; then
    ( umask 077
      printf 'bind-addr: 127.0.0.1:8080\nauth: password\npassword: %s\ncert: false\n' \
        "$(openssl rand -hex 12)" >"$cfg_dir/config.yaml" )
    log_ok "Generated a random code-server password (see: mld code-password)"
  fi
  chmod 600 "$cfg_dir/config.yaml"
  mkdir -p "$settings_dir"
  if [ ! -f "$settings_dir/settings.json" ]; then
    install -m 644 "$OPT_DIR/configs/vscode/settings.json" "$settings_dir/settings.json"
  fi
}

write_shortcuts() {
  local desk="$HOME/Desktop" name src dest sum
  mkdir -p "$desk"
  for name in chromium firefox-esr mld-code mld-ai org.xfce.terminal xfce4-terminal thunar org.xfce.mousepad mousepad; do
    src="/usr/share/applications/${name}.desktop"
    dest="$desk/${name}.desktop"
    if [ -f "$src" ] && [ ! -f "$dest" ]; then
      cp "$src" "$dest"
      chmod 755 "$dest"
      if have_cmd gio && have_cmd dbus-run-session; then
        sum="$(sha256sum "$dest" | cut -d' ' -f1)"
        dbus-run-session -- gio set "$dest" "metadata::xfce-exe-checksum" "$sum" >/dev/null 2>&1 || true
      fi
    fi
  done
  log_ok "Desktop shortcuts created"
}

write_shell_profile() {
  local marker="# >>> mobile-linux-dev-env >>>"
  mkdir -p "$HOME/.npm-global/bin" "$HOME/.local/bin"
  if ! grep -qF "$marker" "$HOME/.bashrc" 2>/dev/null; then
    cat >>"$HOME/.bashrc" <<'EOF'

# >>> mobile-linux-dev-env >>>
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
export EDITOR=nano
alias ai='ai-assistant'
alias ll='ls -alF'
# <<< mobile-linux-dev-env <<<
EOF
  fi
}

scaffold_project() {
  local p="$HOME/projects/hello-web"
  if [ -d "$p" ]; then return 0; fi
  mkdir -p "$p"
  cat >"$p/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Hello from my phone</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <main>
    <h1>Hello, world!</h1>
    <p id="msg">Edit <code>index.html</code> in VS Code and refresh.</p>
    <button id="btn">Click me</button>
  </main>
  <script src="app.js"></script>
</body>
</html>
EOF
  cat >"$p/style.css" <<'EOF'
body { font-family: system-ui, sans-serif; background: #1e1e2e; color: #cdd6f4; margin: 0; }
main { max-width: 40rem; margin: 3rem auto; padding: 0 1rem; }
button { padding: .6rem 1rem; border: 0; border-radius: .4rem; background: #89b4fa; cursor: pointer; }
EOF
  cat >"$p/app.js" <<'EOF'
document.getElementById("btn").addEventListener("click", () => {
  document.getElementById("msg").textContent = "You are coding on a phone. Nice!";
});
EOF
  log_ok "Starter project created at ~/projects/hello-web"
}

# ---- session control --------------------------------------------------------
stop_session() {
  local uid p
  uid="$(id -u)"
  for p in xfce4-session xfwm4 xfce4-panel xfdesktop xfsettingsd Xtigervnc; do
    pkill -u "$uid" -x "$p" >/dev/null 2>&1 || true
  done
  sleep 1
  rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"
}

run_cleanup() {
  local pid
  for pid in "$S_PID" "$X_PID"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
  stop_session
}

cmd_setup() {
  require_user
  load_settings
  log_step "Configuring VNC and the desktop"
  if [ ! -f "$VNC_DIR/passwd" ] || [ "${1:-}" = "--reset-password" ]; then
    set_password
  else
    log_info "Keeping existing VNC password (use: mld passwd to change)."
  fi
  write_xstartup
  write_xfce_defaults
  write_code_server_config
  write_shell_profile
  write_shortcuts
  scaffold_project
  log_ok "Setup finished. Start the desktop from Termux with: mld start"
}

cmd_run() {
  require_user
  load_settings
  [ -f "$VNC_DIR/passwd" ] || die "No VNC password yet. Run: mld passwd"
  [ -x "$VNC_DIR/xstartup" ] || die "Missing ~/.vnc/xstartup. Run: bash /opt/mld/scripts/setup-vnc.sh setup"
  have_cmd Xtigervnc || die "Xtigervnc not found - install-apps.sh did not finish."
  stop_session

  local logf="$CACHE_DIR/vnc.log" xauth_file="${XAUTHORITY:-$HOME/.Xauthority}"
  local -a lh=(-localhost)
  : >"$logf"
  export DISPLAY=":${DISPLAY_NUM}"
  export XAUTHORITY="$xauth_file"
  ( umask 077; touch "$XAUTHORITY" )
  xauth -f "$XAUTHORITY" remove "$DISPLAY" >/dev/null 2>&1 || true
  xauth -f "$XAUTHORITY" add "$DISPLAY" . "$(openssl rand -hex 16)"

  if [ "${MLD_VNC_LAN:-0}" = "1" ]; then
    lh=()
    log_warn "MLD_VNC_LAN=1: VNC is reachable from your network. Use a strong password."
  fi

  trap 'run_cleanup; mld_cleanup' EXIT
  trap 'exit 0' INT TERM

  Xtigervnc "$DISPLAY" \
    -geometry "$MLD_VNC_GEOMETRY" -depth "$MLD_VNC_DEPTH" \
    -rfbport "$PORT" -rfbauth "$VNC_DIR/passwd" -SecurityTypes VncAuth \
    -auth "$XAUTHORITY" -nolisten tcp -AlwaysShared \
    -desktop "mobile-linux-dev-env" ${lh[@]+"${lh[@]}"} >>"$logf" 2>&1 &
  X_PID=$!

  local i
  for i in $(seq 1 40); do
    if [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; then break; fi
    if ! kill -0 "$X_PID" 2>/dev/null; then
      tail -n 20 "$logf" >&2 || true
      die "Xtigervnc exited early (see $logf)"
    fi
    sleep 0.5
  done
  [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ] || die "X server socket did not appear (see $logf)"

  "$VNC_DIR/xstartup" >>"$logf" 2>&1 &
  S_PID=$!
  log_ok "Desktop running: ${MLD_VNC_GEOMETRY} @ ${MLD_VNC_DEPTH}-bit on 127.0.0.1:${PORT}"

  wait -n "$X_PID" "$S_PID" || true
  log_info "Desktop session ended."
}

cmd_stop() {
  require_user
  load_settings
  stop_session
  log_ok "Session stopped."
}

cmd_status() {
  load_settings
  if [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ] && pgrep -u "$(id -u)" -x Xtigervnc >/dev/null 2>&1; then
    log_ok "VNC is running on 127.0.0.1:${PORT}"
  else
    log_info "VNC is not running."
  fi
}

cmd_passwd() {
  require_user
  load_settings
  set_password
  log_info "The new password applies the next time you run: mld start"
}

cmd_resolution() {
  local geo="${1:-}"
  require_user
  [[ "$geo" =~ ^[0-9]{3,4}x[0-9]{3,4}$ ]] || die "Usage: mld resolution WIDTHxHEIGHT  (e.g. 1280x720)"
  mkdir -p "$(dirname "$USER_CONF")"
  printf 'MLD_VNC_GEOMETRY=%s\n' "$geo" >"$USER_CONF"
  log_ok "Resolution set to ${geo}. Restart with: mld restart"
}

usage() {
  cat <<'EOF'
Usage: setup-vnc.sh <setup|run|stop|status|passwd|resolution WxH>
EOF
}

main() {
  local cmd="${1:-}"
  if [ $# -gt 0 ]; then shift; fi
  case "$cmd" in
    setup)      cmd_setup "$@" ;;
    run)        cmd_run ;;
    stop)       cmd_stop ;;
    status)     cmd_status ;;
    passwd)     cmd_passwd ;;
    resolution) cmd_resolution "${1:-}" ;;
    *)          usage; exit 1 ;;
  esac
}

main "$@"
