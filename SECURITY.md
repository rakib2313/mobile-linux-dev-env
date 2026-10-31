# Security Policy

## Supported versions

Only the latest release on `main` receives security fixes.

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's
*"Report a vulnerability"* (Security tab -> Advisories) on this repository. Include steps to
reproduce, affected version and impact. You will get an acknowledgement within 7 days.

## Secret-handling protocol

| Rule | How it is enforced |
|------|--------------------|
| No hardcoded secrets | Nothing in the repo contains passwords, tokens or API keys; CI greps for common token formats. |
| Runtime prompting | VNC and AI credentials are prompted with hidden input (`read -s`) from the real terminal. |
| Templates only | `.env.example` documents settings; the real `.env` is git-ignored and auto-set to mode `600`. |
| Safe parsing | `.env` is **parsed, never `source`d**; only `MLD_[A-Z0-9_]+` keys are accepted. |
| Strict permissions | `~/.mld` = `700`, installer copies = `700`, `~/.vnc/passwd`, `ai.env`, code-server `config.yaml` = `600`. |
| Short-lived handoff | A non-interactive VNC password is passed via a `0600` file that is deleted after one use - never via command-line arguments. |
| Generated secrets | The code-server password is random (`openssl rand`), created at install time on the device. |
| Git hygiene | `.gitignore` excludes logs, caches, keys, `.env`, runtime state and build archives. |

If you ever commit a secret by accident: **revoke/rotate it immediately**, then purge history.

## Design decisions and threat model

* **VNC is bound to `127.0.0.1` only.** Other devices on your Wi-Fi cannot reach it. VNC uses
  an obfuscated 8-character password and no transport encryption - never expose it publicly
  (`MLD_VNC_LAN=1` exists but is discouraged; tunnel over SSH/VPN instead).
* **code-server binds to `127.0.0.1:8080` with password auth.** Android apps share the loopback
  interface, so a password is required.
* **Browsers run with their sandboxes disabled.** PRoot has no user namespaces or seccomp
  support, so Chromium needs `--no-sandbox` and Firefox's content sandbox is off. The Android
  app sandbox is your outer boundary. Only browse sites you trust inside this environment and
  keep high-value logins (banking, primary email) on your phone's normal browser.
* **No root desktop session.** Applications run as the unprivileged user `dev`
  (password-locked). Root is only used by the installer inside the PRoot guest.
* **Supply chain.** Packages come from Termux and Debian repositories (signature-verified by
  apt). code-server is downloaded over HTTPS from its official GitHub releases. The one-line
  installer is `curl | bash`: if you prefer, clone the repo, read the scripts and run
  `bash scripts/install.sh` instead.
* **AI assistant.** Prompts (and, for `fix`, the last lines of a command's output) are sent to
  the provider you configure. Do not paste secrets into it.

## Hardening checklist for contributors

- Run `shellcheck -x -S warning` on every script you touch.
- Quote all expansions; use `set -Eeuo pipefail`; avoid `eval`.
- Never put secrets in argv, environment dumps or logs.
- Validate any user-controlled value before using it in a path, regex or command.
