#!/usr/bin/env bash
# codex-wrapped — run OpenAI Codex CLI confined to one project dir on NixOS.
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
# ~/.codex exposure — whole dir bound RW at its REAL path (CODEX_HOME=
# $REAL_HOME/.codex) so absolute paths in config.toml and passwd-based home
# lookups always resolve correctly.
#
# Whole-dir RW (not granular file binds) is REQUIRED for correctness: Codex
# writes atomically (write temp file -> rename over target). Binding individual
# files over a tmpfs put temp and target on different devices, so rename(2)
# returned EXDEV and Codex surfaced it as "batchWrite failed" (trust decisions
# for new dirs could never persist). A single bind keeps everything on one
# device, so renames work — and the OAuth token is never copied outside ~/.codex.
#   auth.json   -> RW  (OAuth token refresh must persist; no env-injection path)
#   config.toml -> RW  (trust permissions / approved dirs must persist)
#   sessions / memories / history / sqlite / cache -> now persist too (was tmpfs)
# HOME stays /sbx so non-codex tooling (git cache, etc.) remains ephemeral.
#
# Codex's own inner FS sandbox is relaxed (--sandbox danger-full-access injected
# by default) because the outer bwrap is the real boundary; nested user namespaces
# inside --unshare-all are unreliable. #ADJUST if you want inner-sandbox restored.
#
# Usage:
#   codex-wrapped [PROJECT_DIR] [extra args passed to `codex`]
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
[ -d "$PROJECT" ] || { echo "codex-wrapped: not a directory: $PROJECT" >&2; exit 1; }

# ---- sanity -------------------------------------------------------------
command -v bwrap >/dev/null || { echo "codex-wrapped: bwrap not found (nix shell nixpkgs#bubblewrap)" >&2; exit 1; }
command -v codex >/dev/null || { echo "codex-wrapped: codex (OpenAI Codex CLI) not on PATH" >&2; exit 1; }

CODEX_BIN="$(command -v codex)"
CODEX_REAL="$(realpath "$CODEX_BIN")"

NIX_DAEMON_SOCK="/nix/var/nix/daemon-socket/socket"
[ -S "$NIX_DAEMON_SOCK" ] || echo "codex-wrapped: warn: no nix daemon socket; nix build/develop may fail" >&2

# Resolve store paths host-side so PATH entries are guaranteed under /nix/store.
SYS_SW="$(realpath /run/current-system/sw 2>/dev/null || echo /run/current-system/sw)"
CA="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"   #ADJUST if TLS fails
SBX_HOME="/sbx"
REAL_HOME="$HOME"            # host home (e.g. /home/steven) — captured before bwrap
CODEX_DIR="$REAL_HOME/.codex"

# If Codex was NOT installed via Nix (npm/native installer lives in $HOME,
# which we don't bind), bind its install tree read-only so it can run inside.
EXTRA=()
case "$CODEX_REAL" in
  /nix/store/*) ;;                                   # already covered by store bind
  *)
    EXTRA+=(--ro-bind "$(dirname "$CODEX_REAL")" "$(dirname "$CODEX_REAL")")
    echo "codex-wrapped: note: codex is outside /nix/store; bound its install dir read-only" >&2
    ;;
esac

# ---- authentication -----------------------------------------------------
# Codex uses chatgpt OAuth (auth_mode=chatgpt, tokens refreshed in auth.json).
# There is no env-injection path for this auth mode — unlike claude's
# CLAUDE_CODE_OAUTH_TOKEN, Codex refreshes tokens by writing auth.json.
# Therefore auth.json is bound RW (the only unavoidable write to ~/.codex).
#
# To log in: run `codex-raw login` once on the host, then auth.json is populated
# for all subsequent sandboxed runs.
if [ ! -s "$CODEX_DIR/auth.json" ]; then
  echo "codex-wrapped: no auth found (~/.codex/auth.json missing or empty)." >&2
  echo "  Run: codex-raw login  — then retry." >&2
  exit 1
fi

# ---- inner sandbox injection --------------------------------------------
# Relax Codex's own FS sandbox so nested user namespaces inside bwrap don't
# fail. The outer bwrap (--unshare-all, --cap-drop ALL, host RO) is the real
# confinement boundary. Approval prompts are left fully intact. #ADJUST
_has_sandbox_flag=0
for _arg in "$@"; do
  case "$_arg" in
    --sandbox|-s|--dangerously-bypass-approvals-and-sandbox) _has_sandbox_flag=1; break ;;
  esac
done
if [ "$_has_sandbox_flag" -eq 0 ]; then
  set -- --sandbox danger-full-access "$@"
fi
unset _has_sandbox_flag _arg

# Pass /nix/store/* PATH entries from the host (e.g. from `nix develop`) into
# the sandbox — those paths are already accessible via --ro-bind /nix/store.
# Strip everything else (home dirs, /run/wrappers, etc.) since they aren't bound.
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
  --bind        "$CODEX_DIR"             "$CODEX_DIR" \
  --ro-bind-try "$REAL_HOME/.gitconfig"  "$SBX_HOME/.gitconfig" \
  --bind "$PROJECT" "$PROJECT" \
  --chdir "$PROJECT" \
  --setenv HOME "$SBX_HOME" \
  --setenv USER "${USER:-codex}" \
  --setenv LOGNAME "${USER:-codex}" \
  --setenv TERM "${TERM:-xterm-256color}" \
  ${COLORTERM:+--setenv COLORTERM "$COLORTERM"} \
  --setenv PATH "$SANDBOX_PATH" \
  --setenv NIX_REMOTE daemon \
  --setenv NIX_SSL_CERT_FILE "$CA" \
  --setenv SSL_CERT_FILE "$CA" \
  --setenv CODEX_HOME "$CODEX_DIR" \
  "${EXTRA[@]}" \
  "$CODEX_REAL" "$@"
