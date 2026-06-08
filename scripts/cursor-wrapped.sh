#!/usr/bin/env bash
# cursor-wrapped — run the Cursor CLI (cursor-agent) confined to one project dir on NixOS.
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
# Auth model: cursor-agent handles its own login UX. Use `cursor-agent-raw login`
# once to write ~/.config/cursor/auth.json; the wrapper binds that dir into the
# sandbox so the token persists across invocations. The keyring is NEVER bound in.
#
# Dotdir exposure (SPEC §7.6):
#   ~/.config/cursor   — whole-dir RW at real path (auth.json is written
#                        atomically via write-temp+renameSync; EXDEV exception
#                        per §5; token never copied out of its canonical path)
#   ~/.local/share/cursor-agent — whole-dir RW (thread history, resume state;
#                        same EXDEV constraint; persisted so ls/resume/--continue
#                        work across invocations)
#   ~/.cursor          — whole-dir RW (user agents/commands/rules + per-project state; cursor writes here)
#   Node compile cache — tmpfs-ephemeral under /sbx (ephemeral by design)
#
# No CURSOR_DISABLE_AUTOUPDATER equivalent is documented; the `update`
# subcommand writes into the persisted data dir. Use `cursor-agent-raw update`
# for upgrades. #ADJUST if Cursor adds an autoupdate env flag.
#
# Usage:
#   cursor-wrapped [PROJECT_DIR] [extra args passed to `cursor-agent`]
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
[ -d "$PROJECT" ] || { echo "cursor-wrapped: not a directory: $PROJECT" >&2; exit 1; }

# ---- sanity -------------------------------------------------------------
command -v bwrap        >/dev/null || { echo "cursor-wrapped: bwrap not found (nix shell nixpkgs#bubblewrap)" >&2; exit 1; }
command -v cursor-agent >/dev/null || { echo "cursor-wrapped: cursor-agent not on PATH" >&2; exit 1; }

CURSOR_BIN="$(command -v cursor-agent)"
CURSOR_REAL="$(realpath "$CURSOR_BIN")"

NIX_DAEMON_SOCK="/nix/var/nix/daemon-socket/socket"
[ -S "$NIX_DAEMON_SOCK" ] || echo "cursor-wrapped: warn: no nix daemon socket; nix build/develop may fail" >&2

# Resolve store paths host-side so PATH entries are guaranteed under /nix/store.
SYS_SW="$(realpath /run/current-system/sw 2>/dev/null || echo /run/current-system/sw)"
CA="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"   #ADJUST if TLS fails
SBX_HOME="/sbx"
REAL_HOME="$HOME"            # host home (e.g. /home/steven) — captured before bwrap

CONFIG_DIR="$REAL_HOME/.config/cursor"             # auth.json + cli-config.json (atomic writes -> whole-dir RW, §5)
DATA_DIR="$REAL_HOME/.local/share/cursor-agent"    # thread history / resume state (persisted)
USER_CURSOR_DIR="$REAL_HOME/.cursor"               # agents/commands/rules + per-project state (RW; cursor writes here)

# Ensure the RW dirs exist before bwrap tries to bind them.
mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$USER_CURSOR_DIR"

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
  --bind        "$CONFIG_DIR"            "$SBX_HOME/.config/cursor" \
  --bind        "$DATA_DIR"              "$SBX_HOME/.local/share/cursor-agent" \
  --bind        "$USER_CURSOR_DIR"       "$SBX_HOME/.cursor" \
  --ro-bind-try "$REAL_HOME/.gitconfig"  "$SBX_HOME/.gitconfig" \
  --bind "$PROJECT" "$PROJECT" \
  --chdir "$PROJECT" \
  --setenv HOME "$SBX_HOME" \
  --setenv USER "${USER:-cursor}" \
  --setenv LOGNAME "${USER:-cursor}" \
  --setenv TERM "${TERM:-xterm-256color}" \
  ${COLORTERM:+--setenv COLORTERM "$COLORTERM"} \
  --setenv PATH "$SANDBOX_PATH" \
  --setenv NIX_REMOTE daemon \
  --setenv NIX_SSL_CERT_FILE "$CA" \
  --setenv SSL_CERT_FILE "$CA" \
  --setenv NODE_COMPILE_CACHE "$SBX_HOME/.cache/cursor-compile-cache" \
  "$CURSOR_REAL" "$@"
