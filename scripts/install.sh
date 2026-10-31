#!/usr/bin/env bash
# =============================================================================
# install.sh - Master installer (runs in Termux on Android)
#   1. updates Termux          2. installs proot-distro + Debian
#   3. provisions Debian       4. installs XFCE4 / TigerVNC / browsers / dev tools
#   5. configures VNC + desktop shortcuts, sets permissions, installs `mld`
# One-liner:
#   pkg install -y curl && curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/mobile-linux-dev-env/main/scripts/install.sh | bash
# =============================================================================
set -Eeuo pipefail

MLD_REPO_URL="${MLD_REPO_URL:-https://github.com/YOUR_GITHUB_USERNAME/mobile-linux-dev-env.git}"
MLD_BRANCH="${MLD_BRANCH:-main}"

_self="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_self")" 2>/dev/null && pwd || true)"

# ---- Bootstrap when piped from curl (no local checkout) ---------------------
if [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/lib/common.sh" ]; then
  echo "[mld] No local checkout found - fetching ${MLD_REPO_URL} ..." >&2
  if ! command -v git >/dev/null 2>&1; then
    pkg install -y git >/dev/null 2>&1 || apt-get install -y git
  fi
  SRC="${HOME}/.mld-src"
  if [ -d "$SRC/.git" ]; then
    git -C "$SRC" pull --ff-only
  else
    rm -rf "$SRC"
    git clone --depth 1 --branch "$MLD_BRANCH" "$MLD_REPO_URL" "$SRC"
  fi
  if [ -t 0 ]; then
    exec bash "$SRC/scripts/install.sh" "$@"
  elif [ -r /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
    exec bash "$SRC/scripts/install.sh" "$@" </dev/tty
  else
    exec bash "$SRC/scripts/install.sh" "$@"
  fi
fi

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
mld_enable_traps

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
MLD_HOME="${MLD_HOME:-$HOME/.mld}"
MLD_DISTRO="debian"
MLD_USER="${MLD_USER:-dev}"
PROFILE_ARG=""
REFRESH=0
PROFILE="low"

usage() {
  cat <<'EOF'
Usage: install.sh [options]
  --profile low|mid|high|auto   Performance profile (default: auto-detect from RAM)
  -y, --yes                     Non-interactive: answer "yes" to confirmations
  -v, --verbose                 Stream live installer output instead of a spinner
  --refresh                     Only re-sync scripts/configs from this checkout
  -h, --help                    Show this help

Environment: MLD_USER, MLD_PROFILE, MLD_VNC_PASSWORD, MLD_REPO_URL, MLD_BRANCH
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        [ $# -ge 2 ] || die "--profile needs a value"
        PROFILE_ARG="$2"; shift 2 ;;
      --profile=*) PROFILE_ARG="${1#*=}"; shift ;;
      -y|--yes) export MLD_ASSUME_YES=1; shift ;;
      -v|--verbose) export MLD_VERBOSE=1; shift ;;
      --refresh) REFRESH=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
  done
}

resolve_profile() {
  local stored=""
  PROFILE="${PROFILE_ARG:-${MLD_PROFILE:-}}"
  if [ -z "$PROFILE" ] && [ "$REFRESH" = 1 ] && [ -r "$MLD_HOME/mld.env" ]; then
    stored="$( . "$MLD_HOME/mld.env" 2>/dev/null; printf '%s' "${MLD_PROFILE:-}" )"
    PROFILE="$stored"
  fi
  PROFILE="${PROFILE:-auto}"
  case "$PROFILE" in
    auto) PROFILE="$(mld_pick_profile)" ;;
    low|mid|high) ;;
    *) die "Invalid profile '$PROFILE' (use low, mid, high or auto)" ;;
  esac
  [ -f "$REPO_ROOT/configs/profiles/${PROFILE}.conf" ] || die "Missing profile file for '$PROFILE'"
  [[ "$MLD_USER" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || die "Invalid MLD_USER '$MLD_USER'"
}

banner() {
  printf '\n%s' "${C_BOLD}${C_CYAN}" >&2
  cat >&2 <<'EOF'
  __  __       _     _ _        _     _
 |  \/  | ___ | |__ (_) | ___  | |   (_)_ __  _   ___  __
 | |\/| |/ _ \| '_ \| | |/ _ \ | |   | | '_ \| | | \ \/ /
 | |  | | (_) | |_) | | |  __/ | |___| | | | | |_| |>  <
 |_|  |_|\___/|_.__/|_|_|\___| |_____|_|_| |_|\__,_/_/\_\
         Dev Environment for Android (Termux + PRoot)
EOF
  printf '%s\n' "$C_RESET" >&2
}

# Scripts/configs (and one-shot secrets) reach the guest through a bind mount at /mnt,
# so nothing here depends on proot-distro's internal storage layout (it changed in v5).
guest_root() { proot-distro login "$MLD_DISTRO" --shared-tmp --bind "${MLD_HOME}:/mnt" -- "$@"; }
guest_user() { proot-distro login "$MLD_DISTRO" --user "$MLD_USER" --shared-tmp --bind "${MLD_HOME}:/mnt" -- "$@"; }

preflight() {
  log_step "Pre-flight checks"
  mld_is_termux || die "This installer must run inside Termux on Android."
  [ "$(id -u)" -ne 0 ] || die "Do not run as root."
  mld_require_supported_arch
  local free ram
  ram="$(mld_ram_mb)"
  free="$(mld_free_mb "$PREFIX" || true)"
  log_info "Architecture: $(mld_arch) | RAM: ${ram} MB | Profile: ${PROFILE}"
  if [ -n "${free:-}" ]; then
    log_info "Free storage: ${free} MB"
    if [ "$free" -lt 3000 ]; then
      die "Not enough free storage (${free} MB). At least 3 GB is required, 5 GB recommended."
    elif [ "$free" -lt 5000 ]; then
      log_warn "Less than 5 GB free; installation may be tight."
    fi
  fi
  if [ ! -d "$HOME/.termux" ] && [ -z "${TERMUX_APP__PACKAGE_NAME:-}" ]; then
    log_info "Tip: use the F-Droid or GitHub build of Termux (Play Store build is outdated)."
  fi
}

termux_setup() {
  log_step "Preparing Termux"
  if have_cmd termux-wake-lock; then termux-wake-lock || true; fi
  run_step "Refreshing Termux package index" retry 3 3 pkg update -y
  run_step "Upgrading Termux packages" env DEBIAN_FRONTEND=noninteractive \
    apt-get -y -o Dpkg::Options::=--force-confold upgrade
  run_step "Installing proot-distro, curl, wget, git, openssl" \
    pkg install -y proot-distro curl wget git openssl
  run_step "Checking network access" curl -fsS -m 15 -o /dev/null https://deb.debian.org
}

distro_setup() {
  log_step "Setting up Debian (PRoot)"
  if mld_distro_installed "$MLD_DISTRO"; then
    log_info "Debian is already installed - reusing it."
  else
    run_step "Downloading and installing Debian (Docker Hub image 'debian')" \
      retry 2 5 proot-distro install "$MLD_DISTRO"
  fi
  mld_distro_installed "$MLD_DISTRO" \
    || die "The Debian container was not created. Run 'proot-distro install debian' to see the error."
}

sync_files() {
  log_step "Installing scripts and configs"
  [ "$REPO_ROOT" != "$MLD_HOME" ] || die "Run the installer from a checkout, not from $MLD_HOME"
  ( umask 077; mkdir -p "$MLD_HOME" )
  chmod 700 "$MLD_HOME"
  rm -rf "${MLD_HOME:?}/scripts" "${MLD_HOME:?}/configs"
  cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/configs" "$MLD_HOME/"
  chmod -R go-rwx "$MLD_HOME"
  find "$MLD_HOME/scripts" -type f -name '*.sh' -exec chmod 700 {} +

  guest_root sh /mnt/scripts/guest/sync-in.sh "$PROFILE"

  {
    printf 'MLD_DISTRO=%q\n' "$MLD_DISTRO"
    printf 'MLD_USER=%q\n' "$MLD_USER"
    printf 'MLD_PROFILE=%q\n' "$PROFILE"
    printf 'MLD_SRC=%q\n' "$REPO_ROOT"
  } >"$MLD_HOME/mld.env"
  chmod 600 "$MLD_HOME/mld.env"
  log_ok "Files synced (Termux: $MLD_HOME, guest: /opt/mld)"
}

install_launcher() {
  cp "$REPO_ROOT/scripts/mld.sh" "$PREFIX/bin/mld"
  chmod 700 "$PREFIX/bin/mld"
  log_ok "Installed the 'mld' command"
}

mld_kill_stale() {
  # Leftovers of an earlier, interrupted run would hold apt/dpkg locks and look like a hang.
  if have_cmd pkill; then
    pkill -f '/opt/mld/scripts/guest/' 2>/dev/null || true
  fi
}

provision() {
  log_step "Provisioning Debian"
  mld_kill_stale
  log_info "Live details: open a second Termux session and run: tail -f ${MLD_LOG_FILE}"
  run_step "Provisioning base system (apt, locale, user '${MLD_USER}')" \
    guest_root env MLD_USER="$MLD_USER" MLD_PROFILE="$PROFILE" bash /opt/mld/scripts/guest/provision.sh
}

install_apps() {
  log_step "Installing desktop and developer software (10-30 min)"
  MLD_STEP_TIMEOUT=14400 run_step "Installing XFCE4, TigerVNC, browsers, Node.js, Python, code-server" \
    guest_root env MLD_USER="$MLD_USER" MLD_PROFILE="$PROFILE" bash /opt/mld/scripts/guest/install-apps.sh
}

setup_desktop() {
  log_step "Configuring VNC and desktop for user '${MLD_USER}'"
  if [ -n "${MLD_VNC_PASSWORD:-}" ]; then
    ( umask 077; mkdir -p "$MLD_HOME/handoff"; printf '%s\n' "$MLD_VNC_PASSWORD" >"$MLD_HOME/handoff/vncpw" )
    unset MLD_VNC_PASSWORD
  fi
  guest_user env MLD_PROFILE="$PROFILE" bash /opt/mld/scripts/setup-vnc.sh setup
}

refresh() {
  log_step "Refreshing installed scripts"
  mld_distro_installed "$MLD_DISTRO" || die "Nothing to refresh - Debian is not installed."
  sync_files
  install_launcher
  run_step "Re-applying guest configs" \
    guest_root env MLD_USER="$MLD_USER" MLD_PROFILE="$PROFILE" MLD_CONFIGS_ONLY=1 \
    bash /opt/mld/scripts/guest/provision.sh
  log_ok "Refresh complete."
}

finish() {
  if have_cmd termux-wake-unlock; then termux-wake-unlock || true; fi
  cat >&2 <<EOF

${C_BOLD}${C_GREEN}Installation complete!${C_RESET}

  1. Install a VNC viewer app (RealVNC Viewer or bVNC).
  2. In Termux run:        ${C_BOLD}mld start${C_RESET}
  3. In the VNC viewer connect to:  ${C_BOLD}localhost:5901${C_RESET}
     and enter the password you just chose.

  Other commands:  mld stop | status | passwd | shell | ai | resolution | help
  Profile used:    ${PROFILE}     Log file: ${MLD_LOG_FILE}

EOF
}

main() {
  parse_args "$@"
  mld_load_env_file "$REPO_ROOT/.env"
  resolve_profile
  banner
  if [ "$REFRESH" = 1 ]; then
    refresh
    return 0
  fi
  preflight
  mld_confirm "Install the desktop environment now? (needs ~3 GB, 10-30 minutes)" y || die "Aborted by user."
  termux_setup
  distro_setup
  sync_files
  install_launcher
  provision
  install_apps
  setup_desktop
  finish
}

main "$@"
