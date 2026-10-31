#!/usr/bin/env bash
# =============================================================================
# install-apps.sh - desktop + developer software (runs as root in the guest)
#   XFCE4 (minimal), TigerVNC, Chromium, Firefox ESR, Node.js, Python 3, PHP CLI,
#   code-server (VS Code in the browser) with web-dev extensions.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
mld_enable_traps

exec </dev/null
mld_noninteractive_env
OPT=/opt/mld
MLD_USER="${MLD_USER:-dev}"
CODE_SERVER_FALLBACK_VERSION="4.96.4"

[ "$(id -u)" -eq 0 ] || die "install-apps.sh must run as root inside the Debian guest."
[ -f /etc/debian_version ] || die "This script must run inside the Debian guest."
[[ "$MLD_USER" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || die "Invalid user name: $MLD_USER"
id "$MLD_USER" >/dev/null 2>&1 || die "User '$MLD_USER' does not exist - run provision.sh first."

DESKTOP_PKGS=(
  xfce4-session xfwm4 xfce4-panel xfdesktop4 xfce4-settings xfce4-appfinder
  xfce4-terminal xfce4-taskmanager thunar mousepad
  tigervnc-standalone-server tigervnc-common
  adwaita-icon-theme hicolor-icon-theme fonts-dejavu-core fonts-liberation
  at-spi2-core libglib2.0-bin desktop-file-utils shared-mime-info
)
BROWSER_PKGS=(chromium firefox-esr)
DEV_PKGS=(
  nodejs npm python3 python3-pip python3-venv git curl wget
  php-cli php-mbstring php-xml php-curl
)

apt_install() { mld_apt install -y --no-install-recommends "$@"; }

install_packages() {
  log_step "Installing XFCE4 + TigerVNC"
  retry 3 5 mld_apt update
  retry 3 5 apt_install "${DESKTOP_PKGS[@]}"
  log_step "Installing browsers"
  retry 3 5 apt_install "${BROWSER_PKGS[@]}"
  log_step "Installing Node.js, Python, PHP, Git"
  retry 3 5 apt_install "${DEV_PKGS[@]}"
}

configure_firefox() {
  if [ -d /usr/lib/firefox-esr ]; then
    mkdir -p /usr/lib/firefox-esr/distribution
    cat >/usr/lib/firefox-esr/distribution/policies.json <<'EOF'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DontCheckDefaultBrowser": true,
    "NoDefaultBookmarks": true,
    "OverrideFirstRunPage": "",
    "Preferences": {
      "browser.cache.memory.capacity": { "Value": 65536, "Status": "default" },
      "browser.sessionstore.interval": { "Value": 60000, "Status": "default" },
      "layers.acceleration.disabled": { "Value": true, "Status": "default" },
      "media.ffmpeg.vaapi.enabled": { "Value": false, "Status": "default" },
      "dom.ipc.processCount": { "Value": 2, "Status": "default" }
    }
  }
}
EOF
    log_ok "Firefox tuned for low memory"
  fi
}

install_code_server() {
  local arch ver url deb
  arch="$(mld_deb_arch)"
  if have_cmd code-server; then
    log_info "code-server already installed."
    return 0
  fi
  case "$arch" in
    amd64|arm64) ;;
    *)
      log_warn "code-server has no official build for '$arch' - skipping (use a text editor or Mousepad)."
      return 0 ;;
  esac
  ver="$(curl -fsSL -m 20 https://api.github.com/repos/coder/code-server/releases/latest 2>/dev/null \
        | sed -n 's/.*"tag_name": *"v\{0,1\}\([0-9][0-9.]*\)".*/\1/p' | head -n1 || true)"
  if [ -z "$ver" ]; then
    ver="$CODE_SERVER_FALLBACK_VERSION"
    log_warn "Could not query the latest release; using ${ver}."
  fi
  url="https://github.com/coder/code-server/releases/download/v${ver}/code-server_${ver}_${arch}.deb"
  deb="/tmp/code-server_${ver}_${arch}.deb"
  log_info "Downloading code-server ${ver} (${arch})"
  retry 3 5 curl -fL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 3600 -o "$deb" "$url"
  apt_install "$deb"
  rm -f "$deb"
  log_ok "code-server ${ver} installed"
}

install_extensions() {
  local list="$OPT/configs/vscode/extensions.txt" ext
  if ! have_cmd code-server; then return 0; fi
  [ -r "$list" ] || return 0
  while IFS= read -r ext || [ -n "$ext" ]; do
    case "$ext" in
      ''|'#'*) continue ;;
    esac
    if ! [[ "$ext" =~ ^[A-Za-z0-9._-]+$ ]]; then
      log_warn "Skipping invalid extension id in list."
      continue
    fi
    if timeout -k 10 300 runuser -l "$MLD_USER" -c "code-server --install-extension '$ext'" >/dev/null 2>&1; then
      log_ok "Extension installed: $ext"
    else
      log_warn "Optional extension unavailable right now: $ext"
    fi
  done <"$list"
}

cleanup() {
  apt-get clean
  rm -rf /tmp/*.deb
}

main() {
  log_step "Installing applications (arch: $(mld_deb_arch))"
  mld_apt_recover
  install_packages
  configure_firefox
  install_code_server
  install_extensions
  cleanup
  log_ok "All applications installed"
}

main "$@"
