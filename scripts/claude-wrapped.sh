#!/usr/bin/env bash
# claude-wrapped — run Claude Code confined to one project dir on NixOS.
#
# Runaway-agent containment (risk reduction, not a hard boundary):
#   * Host filesystem mounted READ-ONLY.
#   * Only the project dir (and an ephemeral $HOME) are writable.
#   * User/PID/IPC/UTS/cgroup namespaces unshared, all capabilities dropped.
#
# Nix stays fully usable: the daemon socket is bound in, so `nix develop`,
# `nix build`, etc. go through the HOST daemon (root, its own build sandbox)
# and land in the SHARED store. Fixes you make to flake.nix/flake.lock live
# in the writable project dir, so after the agent exits your own `nix develop`
# in that dir hits a warm store and a fixed flake -> working environment.
#
# ~/.claude exposure — granular, not whole-dir (RW whole-dir is an antipattern):
#   projects/      -> RW  (session transcripts; --continue / --resume)
#   sessions/      -> RW  (session index for resume picker)
#   history.jsonl  -> RW  (up-arrow prompt recall)
#   .claude.json   -> RW  (project registry, prefs)
#   .credentials.json -> RO by default; RW if CLAUDE_WRAPPED_PERSIST_CREDS=1
#   settings.json, CLAUDE.md, skills/, agents/, plugins/ -> RO
#   everything else (cache, debug, file-history, session-env, tmp) -> tmpfs
#
# Usage:
#   claude-wrapped [PROJECT_DIR] [extra args passed to `claude`]
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
[ -d "$PROJECT" ] || { echo "claude-wrapped: not a directory: $PROJECT" >&2; exit 1; }

# ---- sanity -------------------------------------------------------------
command -v bwrap  >/dev/null || { echo "claude-wrapped: bwrap not found (nix shell nixpkgs#bubblewrap)" >&2; exit 1; }
command -v claude >/dev/null || { echo "claude-wrapped: claude (Claude Code) not on PATH" >&2; exit 1; }

CLAUDE_BIN="$(command -v claude)"
CLAUDE_REAL="$(realpath "$CLAUDE_BIN")"

NIX_DAEMON_SOCK="/nix/var/nix/daemon-socket/socket"
[ -S "$NIX_DAEMON_SOCK" ] || echo "claude-wrapped: warn: no nix daemon socket; nix build/develop may fail" >&2

# Resolve store paths host-side so PATH entries are guaranteed under /nix/store.
SYS_SW="$(realpath /run/current-system/sw 2>/dev/null || echo /run/current-system/sw)"
CA="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"   #ADJUST if TLS fails
SBX_HOME="/sbx"

# If Claude Code was NOT installed via Nix (npm/native installer lives in $HOME,
# which we don't bind), bind its install tree read-only so it can run inside.
EXTRA=()
case "$CLAUDE_REAL" in
  /nix/store/*) ;;                                   # already covered by store bind
  *)
    EXTRA+=(--ro-bind "$(dirname "$CLAUDE_REAL")" "$(dirname "$CLAUDE_REAL")")
    EXTRA+=(--ro-bind-try "$HOME/.claude/local" "$HOME/.claude/local")   #ADJUST native installer tree
    echo "claude-wrapped: note: claude is outside /nix/store; bound its install dir read-only" >&2
    ;;
esac

# ---- authentication -----------------------------------------------------
# Pick ONE of these so you stay logged in:
#
#  (1) RECOMMENDED: long-lived token, no writable creds.
#        host$ claude setup-token        # once, mints CLAUDE_CODE_OAUTH_TOKEN
#      export it in your shell/secrets (NOT in the project dir) and it's
#      forwarded below. No file writes, no refresh dance.
#
#  (2) Normal subscription login that persists: run with
#        CLAUDE_WRAPPED_PERSIST_CREDS=1 claude-wrapped
#      which binds ~/.claude/.credentials.json READ-WRITE so the background
#      token refresh can write through to your host file.
#
# Note: if ANTHROPIC_API_KEY is also set it takes precedence over the OAuth
# token, so don't set both unless you mean to use the API (pay-per-token).
#
# Pull the token from the GNOME keyring (Seahorse) host-side if not already in
# the env. This runs BEFORE bwrap, so it has D-Bus/keyring access; the sandbox
# never does. Only the resolved value crosses in, via --setenv below.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && command -v secret-tool >/dev/null; then
  CLAUDE_CODE_OAUTH_TOKEN="$(secret-tool lookup service claude-code account "$USER" 2>/dev/null || true)"
fi
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && EXTRA+=(--setenv CLAUDE_CODE_OAUTH_TOKEN "$CLAUDE_CODE_OAUTH_TOKEN")
[ -n "${ANTHROPIC_API_KEY:-}" ]       && EXTRA+=(--setenv ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY")

# Guard: fail early with a clear message rather than silently dropping into
# an interactive re-login loop when no auth source is available.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] \
   && [ ! -s "$HOME/.claude/.credentials.json" ]; then
  echo "claude-wrapped: no auth found (CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_API_KEY unset," >&2
  echo "  keyring lookup empty, no ~/.claude/.credentials.json)." >&2
  echo "  Run: claude setup-token  — then store it in the keyring:" >&2
  echo "    secret-tool store --label='Claude Code OAuth' service claude-code account \"\$USER\"" >&2
  echo "  Alternatively unlock your login keyring before running, then retry." >&2
  exit 1
fi

# Credentials file: read-only by default; read-write if persistence requested.
if [ "${CLAUDE_WRAPPED_PERSIST_CREDS:-0}" = "1" ]; then
  EXTRA+=(--bind-try    "$HOME/.claude/.credentials.json" "$SBX_HOME/.claude/.credentials.json")
else
  EXTRA+=(--ro-bind-try "$HOME/.claude/.credentials.json" "$SBX_HOME/.claude/.credentials.json")
fi

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
  --tmpfs "$SBX_HOME/.claude" \
  --ro-bind-try "$HOME/.claude/settings.json"      "$SBX_HOME/.claude/settings.json" \
  --ro-bind-try "$HOME/.claude/CLAUDE.md"          "$SBX_HOME/.claude/CLAUDE.md" \
  --ro-bind-try "$HOME/.claude/skills"             "$SBX_HOME/.claude/skills" \
  --ro-bind-try "$HOME/.claude/agents"             "$SBX_HOME/.claude/agents" \
  --ro-bind-try "$HOME/.claude/plugins"            "$SBX_HOME/.claude/plugins" \
  --bind-try    "$HOME/.claude/projects"           "$SBX_HOME/.claude/projects" \
  --bind-try    "$HOME/.claude/sessions"           "$SBX_HOME/.claude/sessions" \
  --bind-try    "$HOME/.claude/history.jsonl"      "$SBX_HOME/.claude/history.jsonl" \
  --bind-try    "$HOME/.claude.json"               "$SBX_HOME/.claude.json" \
  --ro-bind-try "$HOME/.gitconfig"                 "$SBX_HOME/.gitconfig" \
  --bind "$PROJECT" "$PROJECT" \
  --chdir "$PROJECT" \
  --setenv HOME "$SBX_HOME" \
  --setenv USER "${USER:-claude}" \
  --setenv LOGNAME "${USER:-claude}" \
  --setenv TERM "${TERM:-xterm-256color}" \
  ${COLORTERM:+--setenv COLORTERM "$COLORTERM"} \
  --setenv PATH "$SANDBOX_PATH" \
  --setenv NIX_REMOTE daemon \
  --setenv NIX_SSL_CERT_FILE "$CA" \
  --setenv SSL_CERT_FILE "$CA" \
  --setenv SANDBOX 1 \
  --setenv DISABLE_AUTOUPDATER 1 \
  "${EXTRA[@]}" \
  "$CLAUDE_REAL" "$@"
