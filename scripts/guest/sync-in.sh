#!/bin/sh
# =============================================================================
# sync-in.sh - copy the staged scripts/configs into the guest (runs as root, in PRoot).
# The Termux side bind-mounts ~/.mld at /mnt; this copies /mnt/{scripts,configs} to /opt/mld
# and selects the active performance profile.   Usage: sh sync-in.sh low|mid|high
# =============================================================================
set -eu

PROFILE="${1:-low}"
case "$PROFILE" in
  low|mid|high) ;;
  *) echo "sync-in: invalid profile '$PROFILE'" >&2; exit 1 ;;
esac

if [ ! -d /mnt/scripts ] || [ ! -d /mnt/configs ]; then
  echo "sync-in: staged files not found in /mnt (bind mount missing?)" >&2
  exit 1
fi

rm -rf /opt/mld/scripts /opt/mld/configs
mkdir -p /opt/mld
cp -R /mnt/scripts /mnt/configs /opt/mld/
find /opt/mld -type d -exec chmod 755 {} +
find /opt/mld -type f -exec chmod 644 {} +
find /opt/mld/scripts -type f -name '*.sh' -exec chmod 755 {} +
chmod 755 /opt/mld/configs/vnc/xstartup
cp "/opt/mld/configs/profiles/${PROFILE}.conf" /opt/mld/configs/profiles/active.conf
echo "sync-in: files installed to /opt/mld (profile: ${PROFILE})"
