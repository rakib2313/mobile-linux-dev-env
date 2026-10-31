#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# common.sh - shared helpers for mobile-linux-dev-env
#   * coloured logging (stderr + log file)   * spinner / progress steps
#   * arch + RAM detection and profile pick  * error / exit trapping
#   * safe .env loading and prompts (read from the real terminal)
# This file is meant to be sourced, never executed.
# =============================================================================

if [ -n "${MLD_COMMON_LOADED:-}" ]; then
  return 0
fi
MLD_COMMON_LOADED=1

MLD_VERSION="1.0.0"

# ---- colours ----------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

# ---- logging ----------------------------------------------------------------
MLD_LOG_FILE="${MLD_LOG_FILE:-${HOME}/.cache/mld/mld.log}"
if ! ( umask 077; mkdir -p "$(dirname "$MLD_LOG_FILE")" && : >>"$MLD_LOG_FILE" ) 2>/dev/null; then
  MLD_LOG_FILE=/dev/null
fi

_mld_emit() { # level colour message...
  local level="$1" colour="$2"
  shift 2
  printf '%s[%s]%s %s\n' "$colour" "$level" "$C_RESET" "$*" >&2
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$MLD_LOG_FILE" 2>/dev/null || true
}
log_info() { _mld_emit INFO "$C_BLUE" "$*"; }
log_ok()   { _mld_emit " OK " "$C_GREEN" "$*"; }
log_warn() { _mld_emit WARN "$C_YELLOW" "$*"; }
log_err()  { _mld_emit FAIL "$C_RED" "$*"; }
log_step() { printf '\n%s==> %s%s\n' "${C_BOLD}${C_CYAN}" "$*" "$C_RESET" >&2; }
die()      { log_err "$*"; exit 1; }

# ---- traps / cleanup --------------------------------------------------------
MLD_TMP_FILES=()

mld_cleanup() {
  local f
  for f in "${MLD_TMP_FILES[@]:-}"; do
    if [ -n "$f" ]; then
      rm -rf -- "$f"
    fi
  done
}

mld_on_err() {
  local rc=$? line="${BASH_LINENO[0]:-?}" src="${BASH_SOURCE[1]:-$0}"
  log_err "Unexpected error (exit ${rc}) at ${src##*/}:${line} -> ${BASH_COMMAND}"
  log_err "Full log: ${MLD_LOG_FILE}"
}

mld_enable_traps() {
  trap mld_on_err ERR
  trap mld_cleanup EXIT
  trap 'log_warn "Interrupted."; exit 130' INT TERM
}

# ---- environment detection --------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

mld_is_termux() {
  [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux/files/usr ]
}

mld_arch() {
  case "$(uname -m)" in
    aarch64|arm64)        echo aarch64 ;;
    armv7l|armv8l|arm)    echo arm ;;
    x86_64|amd64)         echo x86_64 ;;
    *)                    echo unsupported ;;
  esac
}

mld_deb_arch() {
  case "$(mld_arch)" in
    aarch64) echo arm64 ;;
    arm)     echo armhf ;;
    x86_64)  echo amd64 ;;
    *)       echo unknown ;;
  esac
}

mld_require_supported_arch() {
  if [ "$(mld_arch)" = "unsupported" ]; then
    die "Unsupported CPU architecture: $(uname -m) (need ARM64, ARM32 or x86_64)"
  fi
}

mld_ram_mb() {
  local kb
  kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
  if [ -n "$kb" ]; then
    echo $((kb / 1024))
  else
    echo 2048
  fi
}

# low: <= ~4 GB phones | mid: ~6 GB | high: 8 GB and up
mld_pick_profile() {
  local ram
  ram="$(mld_ram_mb)"
  if [ "$ram" -le 4608 ]; then
    echo low
  elif [ "$ram" -le 6656 ]; then
    echo mid
  else
    echo high
  fi
}

mld_free_mb() { # path
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024)}'
}

# True when the proot-distro container exists. Works with proot-distro v4
# (installed-rootfs/<name>) and v5+ (containers/<name>/rootfs) and falls back to
# asking proot-distro itself, so no storage layout is ever assumed.
mld_distro_installed() { # name
  local base="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro"
  if [ -d "$base/containers/$1/rootfs" ] || [ -d "$base/installed-rootfs/$1" ]; then
    return 0
  fi
  have_cmd proot-distro && proot-distro login "$1" -- /bin/true >/dev/null 2>&1
}

# ---- profile loading --------------------------------------------------------
mld_load_profile() { # file
  local f="$1"
  [ -r "$f" ] || die "Profile/config file not readable: $f"
  # shellcheck source=/dev/null
  . "$f"
}

# ---- safe .env loader (never executes the file) -----------------------------
mld_load_env_file() { # file
  local file="$1" line key val mode
  [ -f "$file" ] || return 0
  mode="$(stat -c '%a' "$file" 2>/dev/null || echo 600)"
  if [ "$mode" != "600" ]; then
    chmod 600 "$file" 2>/dev/null || true
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    key="${key//[[:space:]]/}"
    [[ "$key" =~ ^MLD_[A-Z0-9_]+$ ]] || continue
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    [ -n "$val" ] || continue
    if [ -z "${!key:-}" ]; then
      printf -v "$key" '%s' "$val"
      export "$key"
    fi
  done <"$file"
}

# ---- prompts (use the real terminal even when stdin is a pipe) --------------
mld_tty() {
  if [ -t 0 ]; then
    echo /dev/stdin
    return 0
  fi
  if [ -r /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
    echo /dev/tty
    return 0
  fi
  return 1
}

mld_confirm() { # question [default y|n]
  local q="$1" def="${2:-n}" ans in hint
  if [ "${MLD_ASSUME_YES:-0}" = "1" ]; then
    return 0
  fi
  if ! in="$(mld_tty)"; then
    [ "$def" = "y" ]
    return
  fi
  if [ "$def" = "y" ]; then hint="Y/n"; else hint="y/N"; fi
  printf '%s [%s] ' "$q" "$hint" >&2
  IFS= read -r ans <"$in" || ans=""
  ans="${ans:-$def}"
  case "$ans" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

mld_prompt() { # label default varname
  local in v
  if ! in="$(mld_tty)"; then
    printf -v "$3" '%s' "$2"
    return 0
  fi
  printf '%s%s: ' "$1" "${2:+ [$2]}" >&2
  IFS= read -r v <"$in" || v=""
  printf -v "$3" '%s' "${v:-$2}"
}

mld_prompt_secret() { # label varname
  local in v
  in="$(mld_tty)" || return 1
  printf '%s: ' "$1" >&2
  IFS= read -r -s v <"$in" || v=""
  printf '\n' >&2
  printf -v "$2" '%s' "$v"
}

# ---- retry + process helpers -------------------------------------------------
retry() { # attempts delay cmd...
  local attempts="$1" delay="$2" i=1
  shift 2
  until "$@"; do
    if [ "$i" -ge "$attempts" ]; then
      return 1
    fi
    log_warn "Command failed (attempt ${i}/${attempts}); retrying in ${delay}s: $1"
    sleep "$delay"
    i=$((i + 1))
  done
}

mld_file_size() { # path
  stat -c %s "$1" 2>/dev/null || echo 0
}

mld_kill_tree() { # pid [signal]
  local pid="$1" sig="${2:-TERM}" child
  if have_cmd pgrep; then
    # shellcheck disable=SC2046
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
      mld_kill_tree "$child" "$sig"
    done
  fi
  kill "-${sig}" "$pid" 2>/dev/null || true
}

# run_step "message" cmd...
#   * output goes to the log file; the spinner shows elapsed time + the last log line
#   * stdin is /dev/null, so nothing can ever sit waiting for keyboard input
#   * a stall warning appears after MLD_STALL_SECS (default 900) without new output
#   * a hard limit (MLD_STEP_TIMEOUT seconds, default 7200) kills the step instead of hanging
#   * MLD_VERBOSE=1 streams the output live instead of showing a spinner
run_step() {
  local msg="$1" pid rc=0 i=0 ticks=0 frames='|/-\' start="$SECONDS" elapsed=0
  local size last_size last_change limit="${MLD_STEP_TIMEOUT:-7200}" stall="${MLD_STALL_SECS:-900}"
  local timed_out=0 show=0 cols=80 line="" out
  shift
  printf '\n=== %s ===\n' "$msg" >>"$MLD_LOG_FILE" 2>/dev/null || true
  if [ "${MLD_VERBOSE:-0}" = "1" ]; then
    log_info "$msg"
    ( "$@" </dev/null 2>&1 | tee -a "$MLD_LOG_FILE" >&2 ) &
  elif [ -t 2 ]; then
    show=1
    "$@" </dev/null >>"$MLD_LOG_FILE" 2>&1 &
  else
    log_info "$msg"
    "$@" </dev/null >>"$MLD_LOG_FILE" 2>&1 &
  fi
  pid=$!
  last_size="$(mld_file_size "$MLD_LOG_FILE")"
  last_change="$SECONDS"
  if [ "$show" -eq 1 ]; then
    cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  fi
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    ticks=$((ticks + 1))
    elapsed=$((SECONDS - start))
    if [ $((ticks % 5)) -eq 0 ]; then
      size="$(mld_file_size "$MLD_LOG_FILE")"
      if [ "$size" != "$last_size" ]; then
        last_size="$size"
        last_change="$SECONDS"
      fi
      if [ "$show" -eq 1 ]; then
        line="$(tail -c 300 "$MLD_LOG_FILE" 2>/dev/null | tr '\r' '\n' | tail -n 1 | tr -c '[:print:]' ' ' || true)"
      fi
      if [ $((SECONDS - last_change)) -ge "$stall" ]; then
        if [ "$show" -eq 1 ]; then printf '\r\033[K' >&2; fi
        log_warn "No new output for $((stall / 60)) min during '${msg}' (a very slow download looks the same)."
        log_warn "Watch live from a second Termux session: tail -f ${MLD_LOG_FILE}"
        log_warn "If it never moves: press Ctrl+C, check your connection and re-run the installer (finished steps are reused)."
        last_size="$(mld_file_size "$MLD_LOG_FILE")"
        last_change="$SECONDS"
      fi
      if [ "$elapsed" -ge "$limit" ]; then
        timed_out=1
        break
      fi
    fi
    if [ "$show" -eq 1 ]; then
      i=$(( (i + 1) % 4 ))
      out="$(printf '  %s %s [%02d:%02d] %s' "${frames:$i:1}" "$msg" $((elapsed / 60)) $((elapsed % 60)) "$line")"
      printf '\r\033[K%s' "${out:0:$((cols - 1))}" >&2
    fi
  done
  if [ "$timed_out" -eq 1 ]; then
    if [ "$show" -eq 1 ]; then printf '\r\033[K' >&2; fi
    log_err "'${msg}' ran longer than ${limit}s - stopping it."
    mld_kill_tree "$pid" TERM
    sleep 3
    mld_kill_tree "$pid" KILL
  fi
  wait "$pid" 2>/dev/null || rc=$?
  if [ "$timed_out" -eq 1 ]; then
    rc=124
  fi
  if [ "$show" -eq 1 ]; then printf '\r\033[K' >&2; fi
  if [ "$rc" -eq 0 ]; then
    log_ok "${msg} ($((SECONDS - start))s)"
  else
    log_err "${msg} failed (exit ${rc}). Last log lines:"
    tail -n 15 "$MLD_LOG_FILE" 2>/dev/null >&2 || true
    return "$rc"
  fi
}

# ---- Debian / apt helpers (used inside the guest) -------------------------------
mld_noninteractive_env() {
  export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true DEBIAN_PRIORITY=critical
  export APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a UCF_FORCE_CONFFOLD=1
}

# Clear stale locks and finish half-configured packages left by an interrupted run.
mld_apt_recover() {
  rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock
  timeout -k 10 600 dpkg --force-confold --configure -a </dev/null >/dev/null 2>&1 || true
}

# apt-get with a hard time limit; repairs the package state if it fails or times out.
mld_apt() { # apt-get arguments...
  local rc=0
  timeout -k 30 "${MLD_APT_TIMEOUT:-3600}" apt-get "$@" </dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_warn "apt-get $1 failed or timed out (exit ${rc}); repairing package state"
    mld_apt_recover
  fi
  return "$rc"
}
