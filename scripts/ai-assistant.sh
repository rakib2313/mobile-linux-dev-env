#!/usr/bin/env bash
# =============================================================================
# ai-assistant.sh - lightweight CLI coding helper for beginners
#   ai-assistant configure          choose provider/model, store API key (mode 600)
#   ai-assistant ask "question"     one-off question (or pipe text in)
#   ai-assistant chat               interactive conversation
#   ai-assistant fix <command...>   run a command and explain/fix its error
#   ai-assistant status             show current (non-secret) settings
# Providers: "anthropic" (Anthropic Messages API) or "openai" (any
# OpenAI-compatible /chat/completions endpoint, incl. local servers).
# The API key is never hardcoded: it is prompted for at runtime and stored in
# ~/.config/mld/ai.env, or taken from the MLD_AI_API_KEY environment variable.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
mld_enable_traps

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mld"
CONF_FILE="$CONF_DIR/ai.env"

SYSTEM_PROMPT="You are a friendly, concise coding mentor for beginner web developers who work on a small phone screen. Explain errors in plain language, give the exact fix as a short code block, and avoid long lectures. Prefer HTML, CSS, JavaScript, Node.js, Python and PHP examples. Never ask for or repeat secrets."

read -r -d '' PY_CLIENT <<'PYEOF' || true
import json
import os
import sys
import urllib.error
import urllib.request

provider = os.environ.get("MLD_AI_PROVIDER", "anthropic")
model = os.environ.get("MLD_AI_MODEL", "")
base = os.environ.get("MLD_AI_BASE_URL", "").rstrip("/")
key = os.environ.get("MLD_AI_API_KEY", "")
system = os.environ.get("MLD_AI_SYSTEM", "")
hist_path = sys.argv[1]

user_msg = sys.stdin.read().strip()
if not user_msg:
    sys.exit("Empty prompt.")

try:
    with open(hist_path, "r", encoding="utf-8") as fh:
        history = json.load(fh)
    if not isinstance(history, list):
        history = []
except (OSError, ValueError):
    history = []

history = history[-20:]
while history and history[0].get("role") != "user":
    history.pop(0)
history.append({"role": "user", "content": user_msg})

headers = {
    "content-type": "application/json",
    "user-agent": "mobile-linux-dev-env/1.0",
}
if provider == "anthropic":
    url = (base or "https://api.anthropic.com") + "/v1/messages"
    headers["x-api-key"] = key
    headers["anthropic-version"] = "2023-06-01"
    body = {"model": model, "max_tokens": 1024, "system": system, "messages": history}
else:
    url = (base or "https://api.openai.com/v1") + "/chat/completions"
    if key:
        headers["authorization"] = "Bearer " + key
    body = {"model": model, "messages": [{"role": "system", "content": system}] + history}

req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), headers=headers, method="POST")
try:
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.load(resp)
except urllib.error.HTTPError as exc:
    detail = exc.read().decode("utf-8", "replace")[:500]
    sys.exit("API error %s: %s" % (exc.code, detail))
except urllib.error.URLError as exc:
    sys.exit("Network error: %s" % (exc.reason,))
except (OSError, ValueError) as exc:
    sys.exit("Request failed: %s" % (exc,))

try:
    if provider == "anthropic":
        reply = "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
    else:
        reply = data["choices"][0]["message"]["content"]
except (KeyError, IndexError, TypeError):
    sys.exit("Unexpected API response format.")

history.append({"role": "assistant", "content": reply})
fd = os.open(hist_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(history, fh)

print(reply)
PYEOF

usage() {
  cat <<'EOF'
Usage: ai-assistant <command>
  configure          Choose provider/model and store your API key securely
  ask "question"     Ask one question (or: echo "..." | ai-assistant ask)
  chat               Interactive chat (/new, /help, /exit)
  fix <command...>   Run a command, then get a plain-language fix for its error
  status             Show current settings (the key is never printed)
EOF
}

is_local_base() {
  case "${MLD_AI_BASE_URL:-}" in
    http://localhost*|http://127.0.0.1*) return 0 ;;
    *) return 1 ;;
  esac
}

load_config() {
  mld_load_env_file "$CONF_FILE"
  export MLD_AI_PROVIDER="${MLD_AI_PROVIDER:-anthropic}"
  export MLD_AI_BASE_URL="${MLD_AI_BASE_URL:-}"
  export MLD_AI_API_KEY="${MLD_AI_API_KEY:-}"
  if [ "$MLD_AI_PROVIDER" = "anthropic" ]; then
    export MLD_AI_MODEL="${MLD_AI_MODEL:-claude-haiku-5-5}"
  else
    export MLD_AI_MODEL="${MLD_AI_MODEL:-}"
  fi
}

cmd_configure() {
  local provider model base key def_base def_model re_https re_local
  have_cmd python3 || die "python3 is required."
  mld_tty >/dev/null || die "configure needs an interactive terminal."
  re_https='^https://[^[:space:]]+$'
  re_local='^http://(localhost|127\.0\.0\.1)(:[0-9]+)?(/[^[:space:]]*)?$'
  mld_prompt "Provider (anthropic or openai-compatible: type 'openai')" "${MLD_AI_PROVIDER:-anthropic}" provider
  case "$provider" in
    anthropic) def_base="https://api.anthropic.com"; def_model="claude-haiku-5-5" ;;
    openai)    def_base="https://api.openai.com/v1"; def_model="${MLD_AI_MODEL:-gpt-4o-mini}" ;;
    *) die "Provider must be 'anthropic' or 'openai'." ;;
  esac
  mld_prompt "Model" "$def_model" model
  mld_prompt "API base URL" "$def_base" base
  if ! [[ "$base" =~ $re_https || "$base" =~ $re_local ]]; then
    die "Base URL must start with https:// (or http://localhost for a local server)."
  fi
  [ -n "$model" ] || die "A model name is required."
  mld_prompt_secret "API key (input hidden; leave empty only for a local server)" key || die "No terminal."
  if [ -z "$key" ] && ! [[ "$base" =~ $re_local ]]; then
    die "An API key is required for remote providers."
  fi
  ( umask 077; mkdir -p "$CONF_DIR" )
  chmod 700 "$CONF_DIR"
  (
    umask 077
    {
      printf '# Managed by ai-assistant configure. Never commit this file.\n'
      printf 'MLD_AI_PROVIDER=%s\n' "$provider"
      printf 'MLD_AI_MODEL=%s\n' "$model"
      printf 'MLD_AI_BASE_URL=%s\n' "$base"
      printf 'MLD_AI_API_KEY=%s\n' "$key"
    } >"$CONF_FILE"
  )
  chmod 600 "$CONF_FILE"
  key=""
  log_ok "Saved to $CONF_FILE (mode 600)."
}

ensure_ready() {
  have_cmd python3 || die "python3 is required."
  load_config
  if [ -z "$MLD_AI_API_KEY" ] && ! is_local_base; then
    if mld_tty >/dev/null; then
      log_info "The AI assistant is not configured yet - let's set it up."
      cmd_configure
      load_config
    else
      die "Not configured. Run: ai-assistant configure   (or set MLD_AI_API_KEY)"
    fi
  fi
  [ -n "$MLD_AI_MODEL" ] || die "No model set. Run: ai-assistant configure"
}

ai_call() { # history_file ; prompt on stdin
  MLD_AI_SYSTEM="$SYSTEM_PROMPT" python3 -c "$PY_CLIENT" "$1"
}

new_history() {
  local f
  f="$(mktemp)"
  MLD_TMP_FILES+=("$f")
  : >"$f"
  printf '%s' "$f"
}

cmd_ask() {
  local prompt hist
  if [ $# -gt 0 ]; then
    prompt="$*"
  elif [ ! -t 0 ]; then
    prompt="$(cat)"
  else
    die "Usage: ai-assistant ask \"your question\""
  fi
  ensure_ready
  hist="$(mktemp)"
  MLD_TMP_FILES+=("$hist")
  : >"$hist"
  printf '%s' "$prompt" | ai_call "$hist"
}

cmd_chat() {
  local hist line
  mld_tty >/dev/null || die "chat needs an interactive terminal."
  ensure_ready
  hist="$(mktemp)"
  MLD_TMP_FILES+=("$hist")
  : >"$hist"
  printf '%sAI coding helper%s (%s / %s) - /new, /help, /exit\n' \
    "$C_BOLD" "$C_RESET" "$MLD_AI_PROVIDER" "$MLD_AI_MODEL" >&2
  while :; do
    IFS= read -r -e -p 'you> ' line || break
    case "$line" in
      '') continue ;;
      /exit|/quit|exit|quit) break ;;
      /new) : >"$hist"; log_info "Started a new conversation."; continue ;;
      /help) printf 'Commands: /new  /exit.  Paste code or error messages freely.\n' >&2; continue ;;
    esac
    if ! printf '%s' "$line" | ai_call "$hist"; then
      log_warn "That request failed - check your connection or run: ai-assistant configure"
    fi
  done
}

cmd_fix() {
  [ $# -gt 0 ] || die "Usage: ai-assistant fix <command> [args...]"
  local out rc=0 hist prompt
  out="$("$@" 2>&1)" || rc=$?
  printf '%s\n' "$out" | tail -n 40
  if [ "$rc" -eq 0 ]; then
    log_ok "The command succeeded (exit 0) - nothing to fix."
    return 0
  fi
  ensure_ready
  log_info "Exit code ${rc}. Sending the last lines of output to '${MLD_AI_PROVIDER}' for analysis ..."
  prompt="I ran this command: $*
Exit code: ${rc}
Output (last lines):
$(printf '%s\n' "$out" | tail -n 60 | cut -c1-400)

Explain what went wrong in simple terms and give the exact fix."
  hist="$(mktemp)"
  MLD_TMP_FILES+=("$hist")
  : >"$hist"
  printf '%s' "$prompt" | ai_call "$hist"
}

cmd_status() {
  load_config
  printf 'provider : %s\nmodel    : %s\nbase url : %s\nkey set  : %s\nconfig   : %s\n' \
    "$MLD_AI_PROVIDER" "${MLD_AI_MODEL:-<unset>}" "${MLD_AI_BASE_URL:-<default>}" \
    "$([ -n "$MLD_AI_API_KEY" ] && echo yes || echo no)" "$CONF_FILE"
}

main() {
  local cmd="${1:-}"
  if [ $# -gt 0 ]; then shift; fi
  case "$cmd" in
    configure) cmd_configure ;;
    ask)       cmd_ask "$@" ;;
    chat|"")
      if [ -z "$cmd" ] && ! mld_tty >/dev/null; then usage; exit 1; fi
      cmd_chat ;;
    fix)       cmd_fix "$@" ;;
    status)    cmd_status ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
