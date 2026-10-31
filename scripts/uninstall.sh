#!/usr/bin/env bash
# =============================================================================
# uninstall.sh - remove the Debian guest, the `mld` command and all state.
# Termux packages (proot-distro, git, ...) are left installed.
#   --yes / -y         skip the confirmation prompt
#   --keep-distro      keep the Debian rootfs (only remove launcher + state)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
mld_enable_traps

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
MLD_HOME="${MLD_HOME:-$HOME/.mld}"
MLD_DISTRO="debian"
KEEP_DISTRO=0

if [ -r "$MLD_HOME/mld.env" ]; then
  # shellcheck source=/dev/null
  . "$MLD_HOME/mld.env"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) export MLD_ASSUME_YES=1 ;;
    --keep-distro) KEEP_DISTRO=1 ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

mld_is_termux || die "Run this inside Termux."

log_warn "This will remove:"
printf '  - %s\n  - %s\n  - %s\n' \
  "$([ "$KEEP_DISTRO" = 1 ] && echo '(Debian rootfs kept)' || echo "Debian rootfs and ALL files inside it (including ~/projects)")" \
  "$PREFIX/bin/mld" "$MLD_HOME and ~/.mld-src" >&2

mld_confirm "Really uninstall?" n || die "Aborted - nothing was changed."

if command -v pkill >/dev/null 2>&1; then
  pkill -f 'setup-vnc.sh run' 2>/dev/null || true
  pkill -x Xtigervnc 2>/dev/null || true
fi

if [ "$KEEP_DISTRO" = 0 ]; then
  if have_cmd proot-distro && mld_distro_installed "$MLD_DISTRO"; then
    proot-distro remove "$MLD_DISTRO" || log_warn "proot-distro could not remove $MLD_DISTRO cleanly."
  fi
fi

rm -f "$PREFIX/bin/mld" "$HOME/.termux/boot/mld-start.sh"
rm -rf "${HOME:?}/.mld-src" "${MLD_HOME:?}"
if have_cmd termux-wake-unlock; then termux-wake-unlock || true; fi
log_ok "Uninstalled. Log file kept at: ${MLD_LOG_FILE}"
