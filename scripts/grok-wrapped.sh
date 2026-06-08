#!/usr/bin/env bash
# grok-wrapped — run the xAI Grok CLI confined to one project dir on NixOS.
#
# Runaway-agent containment (risk reduction, not a hard boundary):
#   * Host filesystem mounted READ-ONLY.
#   * Only the project dir (and an ephemeral $HOME) are writable.
#   * User/PID/IPC/UTS/cgroup namespaces unshared, all capabilities dropped.
#
# Nix stays fully usable: the daemon socket is bound in, so `nix develop`,
# `nix build`, etc. go through the HOST daemon (root, its own build sandbox)
# and land in the SHARED store.
#
# ~/.grok exposure — whole dir bound RW at its REAL path (GROK_HOME=
# $REAL_HOME/.grok) so absolute paths in config.toml, the leader.sock unix
# socket, and passwd-based home lookups always resolve correctly.
#
# Whole-dir RW (not granular file binds) is REQUIRED for correctness: Grok
# writes atomically (write temp file -> rename over target), rewrites
# config.toml, keeps sqlite DBs (sessions, worktrees.db), and opens a unix
# socket (leader.sock). Binding individual files over a tmpfs would put temp
# and target on different devices, so rename(2) returns EXDEV (the same failure
# codex hit as "batchWrite failed"). A single bind keeps everything on one
# device, so renames work — and the OAuth token in auth.json is never copied
# outside ~/.grok. See SPEC.md §5.
#   auth.json   -> RW  (OAuth `grok login` token refresh rewrites it)
#   config.toml -> RW  (persisted trust/dashboard/server-enabled state)
#   sessions / memory / worktrees.db / leader.sock / cache -> RW (persist)
# HOME stays /sbx so non-grok tooling (git cache, etc.) remains ephemeral.
#
# Grok's own inner FS sandbox (--sandbox / GROK_SANDBOX) is OFF by default and
# left off: nested user namespaces / Landlock inside --unshare-all are
# unreliable, and the outer bwrap is the real boundary. #ADJUST to restore it.
#
# Auth: XAI_API_KEY resolved host-side (env, else GNOME keyring) and injected
# via --setenv; OR OAuth via `grok-raw login` (writes auth.json, covered by the
# RW bind); OR api_key in ~/.grok/config.toml. The keyring is NEVER bound in.
#
# Usage:
#   grok-wrapped [PROJECT_DIR] [extra args passed to `grok`]
#   (defaults to $PWD)
#
# Likely first-run adjustment points are flagged with #ADJUST.
#
# Threat model, design rationale, and the rules every wrapper follows:
# see SPEC.md in this directory.

set -euo pipefail

# ---- args ---------------------------------------------------------------
if [ $# -gt 0 ] && [ "${1:0:1}" != "-" ]; then
  PROJECT="$(realpath "$1")"; shift
else
  PROJECT="$PWD"
fi
[ -d "$PROJECT" ] || { echo "grok-wrapped: not a directory: $PROJECT" >&2; exit 1; }

# ---- sanity -------------------------------------------------------------
command -v bwrap >/dev/null || { echo "grok-wrapped: bwrap not found (nix shell nixpkgs#bubblewrap)" >&2; exit 1; }
command -v grok  >/dev/null || { echo "grok-wrapped: grok (xAI Grok CLI) not on PATH" >&2; exit 1; }

GROK_BIN="$(command -v grok)"
GROK_REAL="$(realpath "$GROK_BIN")"

NIX_DAEMON_SOCK="/nix/var/nix/daemon-socket/socket"
[ -S "$NIX_DAEMON_SOCK" ] || echo "grok-wrapped: warn: no nix daemon socket; nix build/develop may fail" >&2

# Resolve store paths host-side so PATH entries are guaranteed under /nix/store.
SYS_SW="$(realpath /run/current-system/sw 2>/dev/null || echo /run/current-system/sw)"
CA="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"   #ADJUST if TLS fails
SBX_HOME="/sbx"
REAL_HOME="$HOME"            # host home (e.g. /home/steven) — captured before bwrap
GROK_DIR="$REAL_HOME/.grok"

# If Grok was NOT installed via Nix, bind its install tree read-only so it runs.
EXTRA=()
case "$GROK_REAL" in
  /nix/store/*) ;;                                   # already covered by store bind
  *)
    EXTRA+=(--ro-bind "$(dirname "$GROK_REAL")" "$(dirname "$GROK_REAL")")
    echo "grok-wrapped: note: grok is outside /nix/store; bound its install dir read-only" >&2
    ;;
esac

# ---- authentication -----------------------------------------------------
# Prefer env-injected, non-writable auth (SPEC §4 rule 5): resolve XAI_API_KEY
# host-side (env, else GNOME keyring) and inject it. OAuth (`grok login`) writes
# ~/.grok/auth.json and is covered by the whole-dir RW bind below — the token is
# never copied out of ~/.grok. api_key in config.toml is a third source.
if [ -z "${XAI_API_KEY:-}" ] && command -v secret-tool >/dev/null; then
  XAI_API_KEY="$(secret-tool lookup service xai account "$USER" 2>/dev/null || true)"
fi
[ -n "${XAI_API_KEY:-}" ] && EXTRA+=(--setenv XAI_API_KEY "$XAI_API_KEY")

# Fail fast (SPEC §3, §7.5) if no auth source is available at all.
if [ -z "${XAI_API_KEY:-}" ] && [ ! -s "$GROK_DIR/auth.json" ] \
   && ! grep -q '^[[:space:]]*api_key[[:space:]]*=' "$GROK_DIR/config.toml" 2>/dev/null; then
  echo "grok-wrapped: no auth found." >&2
  echo "  Use one of:" >&2
  echo "    export XAI_API_KEY=...                              (or)" >&2
  echo "    secret-tool store --label='xAI API key' service xai account \"$USER\"   (or)" >&2
  echo "    grok-raw login                                     (writes ~/.grok/auth.json)" >&2
  exit 1
fi

# Pass /nix/store/* PATH entries from the host (e.g. from `nix develop`) into
# the sandbox; strip everything else (home dirs, /run/wrappers) — not bound.
_STORE_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep '^/nix/store/' | tr '\n' ':' | sed 's/:$//')"
SANDBOX_PATH="${_STORE_PATH:+$_STORE_PATH:}$SYS_SW/bin:/nix/var/nix/profiles/default/bin:$SBX_HOME/.local/bin"

# Inherit the full calling environment — containment comes from namespaces,
# read-only binds, and dropped capabilities, not from clearing env.
# The explicit --setenv flags below override specific vars (HOME, PATH, etc.)
# on top of whatever the host (e.g. `nix develop`) already exported.
# --new-session intentionally omitted: setsid() detaches the controlling
# terminal so the agent never receives SIGWINCH on window resize, causing
# TUI distortion / stale repaints in Ghostty. Its sole purpose was blocking
# TIOCSTI terminal injection back into the parent shell — already disabled
# kernel-wide here (dev.tty.legacy_tiocsti=0). Deviation documented per §3.
exec bwrap \
  --unshare-all --share-net \
  --die-with-parent \
  --cap-drop ALL \
  --ro-bind /nix/store /nix/store \
  --ro-bind /nix/var/nix /nix/var/nix \
  --ro-bind-try /etc/nix /etc/nix \
  --ro-bind-try /bin/sh /bin/sh \
  --ro-bind-try /usr/bin/env /usr/bin/env \
  --ro-bind-try /etc/ssl /etc/ssl \
  --ro-bind-try /etc/static /etc/static \
  --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
  --ro-bind-try /etc/hosts /etc/hosts \
  --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
  --proc /proc \
  --dev /dev \
  --tmpfs /tmp \
  --tmpfs "$SBX_HOME" \
  --bind        "$GROK_DIR"              "$GROK_DIR" \
  --ro-bind-try "$REAL_HOME/.gitconfig"  "$SBX_HOME/.gitconfig" \
  --bind "$PROJECT" "$PROJECT" \
  --chdir "$PROJECT" \
  --setenv HOME "$SBX_HOME" \
  --setenv USER "${USER:-grok}" \
  --setenv LOGNAME "${USER:-grok}" \
  --setenv TERM "${TERM:-xterm-256color}" \
  ${COLORTERM:+--setenv COLORTERM "$COLORTERM"} \
  --setenv PATH "$SANDBOX_PATH" \
  --setenv NIX_REMOTE daemon \
  --setenv NIX_SSL_CERT_FILE "$CA" \
  --setenv SSL_CERT_FILE "$CA" \
  --setenv GROK_HOME "$GROK_DIR" \
  --setenv GROK_DISABLE_AUTOUPDATER 1 \
  "${EXTRA[@]}" \
  "$GROK_REAL" "$@"
