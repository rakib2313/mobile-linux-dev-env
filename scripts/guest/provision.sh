#!/usr/bin/env bash
# =============================================================================
# provision.sh - base provisioning of the Debian guest (runs as root in PRoot)
#   network check, apt tuning for PRoot / mobile networks, base packages, locale,
#   non-root desktop user, performance profile, Chromium flags, launchers.
# Every command that could block is time-limited, and nothing here reads the keyboard.
# Env: MLD_USER (default dev), MLD_PROFILE (low|mid|high), MLD_CONFIGS_ONLY=1,
#      MLD_FULL_UPGRADE=1 (also run apt upgrade), MLD_APT_TIMEOUT (seconds per apt call)
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
MLD_PROFILE="${MLD_PROFILE:-low}"

[ "$(id -u)" -eq 0 ] || die "provision.sh must run as root inside the Debian guest."
[ -f /etc/debian_version ] || die "This script must run inside the Debian guest."
[[ "$MLD_USER" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || die "Invalid user name: $MLD_USER"
[[ "$MLD_PROFILE" =~ ^(low|mid|high)$ ]] || die "Invalid profile: $MLD_PROFILE"

BASE_PKGS=(
  ca-certificates curl wget git openssl locales tzdata procps psmisc
  dbus dbus-x11 xauth x11-xserver-utils xclip xdg-utils xdg-user-dirs
  nano less unzip zip jq htop bash-completion
)

check_network() {
  local host=deb.debian.org ip
  if ! getent hosts "$host" >/dev/null 2>&1; then
    log_warn "DNS lookup failed - switching to public DNS servers."
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >/etc/resolv.conf
  fi
  ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  [ -n "$ip" ] || die "Cannot resolve ${host}. Check your internet connection (try Wi-Fi) and re-run the installer."
  if ! retry 3 3 timeout 20 bash -c "exec 3<>/dev/tcp/${ip}/80"; then
    die "Cannot connect to ${host} (${ip}:80). Check your internet connection (try Wi-Fi) and re-run the installer."
  fi
  log_ok "Network reachable (${host} -> ${ip})"
}

configure_apt() {
  mkdir -p /etc/apt/apt.conf.d /etc/dpkg/dpkg.cfg.d /usr/sbin
  cat >/etc/apt/apt.conf.d/99mld <<'EOF'
// PRoot + mobile-network friendly settings (managed by mobile-linux-dev-env)
APT::Sandbox::User "root";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::Color "0";
Acquire::Retries "3";
Acquire::Languages "none";
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::http::Pipeline-Depth "0";
Dpkg::Use-Pty "0";
Dpkg::Options { "--force-confdef"; "--force-confold"; };
EOF
  printf 'force-unsafe-io\n' >/etc/dpkg/dpkg.cfg.d/99mld
  # No service auto-start inside PRoot (there is no init system).
  printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
  chmod 755 /usr/sbin/policy-rc.d
}

install_base() {
  log_info "Updating package lists ..."
  retry 3 5 mld_apt update
  if [ "${MLD_FULL_UPGRADE:-0}" = "1" ]; then
    log_info "Upgrading installed packages ..."
    retry 3 5 mld_apt -y upgrade
  fi
  log_info "Installing base packages (${#BASE_PKGS[@]}) ..."
  retry 3 5 mld_apt install -y --no-install-recommends "${BASE_PKGS[@]}"
}

configure_locale() {
  if [ -f /etc/locale.gen ]; then
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
    timeout -k 10 900 locale-gen >/dev/null </dev/null
  fi
  printf 'LANG=en_US.UTF-8\n' >/etc/default/locale
}

create_user() {
  if id "$MLD_USER" >/dev/null 2>&1; then
    log_info "User '$MLD_USER' already exists."
  else
    timeout 120 useradd -m -s /bin/bash "$MLD_USER"
    log_ok "Created user '$MLD_USER'"
  fi
  timeout 60 passwd -l "$MLD_USER" >/dev/null 2>&1 || true
  local g
  for g in audio video; do
    if getent group "$g" >/dev/null 2>&1; then
      timeout 60 usermod -aG "$g" "$MLD_USER" || true
    fi
  done
  chmod 750 "/home/$MLD_USER" || true
}

install_configs() {
  mkdir -p /etc/mld /etc/chromium.d
  install -m 644 "$OPT/configs/profiles/${MLD_PROFILE}.conf" /etc/mld/profile.conf
  install -m 644 "$OPT/configs/chromium/flags.conf" /etc/mld/chromium-flags.conf
  cat >/etc/chromium.d/99-mld <<'EOF'
# Managed by mobile-linux-dev-env: low-memory, PRoot-safe Chromium flags.
MLD_BASE_FLAGS="$(grep -Ev '^[[:space:]]*(#|$)' /etc/mld/chromium-flags.conf | tr '\n' ' ')"
MLD_EXTRA_FLAGS="$( . /etc/mld/profile.conf; printf '%s' "${MLD_CHROMIUM_EXTRA:-}" )"
export CHROMIUM_FLAGS="${CHROMIUM_FLAGS:-} ${MLD_BASE_FLAGS} ${MLD_EXTRA_FLAGS}"
EOF
  chmod 644 /etc/chromium.d/99-mld
  log_ok "Profile '${MLD_PROFILE}' and Chromium flags installed"
}

install_launchers() {
  mkdir -p /usr/local/bin /usr/share/applications
  ln -sf "$OPT/scripts/ai-assistant.sh" /usr/local/bin/ai-assistant
  ln -sf "$OPT/scripts/guest/mld-code.sh" /usr/local/bin/mld-code
  ln -sf "$OPT/scripts/setup-vnc.sh" /usr/local/bin/mld-vnc

  cat >/usr/share/applications/mld-code.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=VS Code (code-server)
Comment=Web-based VS Code with web-dev extensions
Exec=mld-code
Icon=applications-development
Terminal=false
Categories=Development;IDE;TextEditor;
EOF
  cat >/usr/share/applications/mld-ai.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=AI Coding Helper
Comment=Ask for help with errors and code
Exec=xfce4-terminal --title="AI Coding Helper" --command="ai-assistant chat"
Icon=help-browser
Terminal=false
Categories=Development;Utility;
EOF
  chmod 644 /usr/share/applications/mld-code.desktop /usr/share/applications/mld-ai.desktop
  if have_cmd update-desktop-database; then update-desktop-database /usr/share/applications >/dev/null 2>&1 || true; fi
  chmod -R a+rX "$OPT"
}

main() {
  log_step "Provisioning Debian guest (profile: ${MLD_PROFILE})"
  if [ "${MLD_CONFIGS_ONLY:-0}" != "1" ]; then
    log_info "[1/5] Checking network access"
    check_network
    log_info "[2/5] Configuring apt for PRoot and mobile networks"
    configure_apt
    mld_apt_recover
    log_info "[3/5] Installing base packages"
    install_base
    log_info "[4/5] Configuring locale"
    configure_locale
    log_info "[5/5] Creating user '${MLD_USER}'"
    create_user
  fi
  install_configs
  install_launchers
  log_ok "Provisioning complete"
}

main "$@"
