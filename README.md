# Coding Agent Sandbox Wrappers

Bubblewrap-confined NixOS wrappers for four coding-agent CLIs.

Each wrapper runs its agent confined to a **single project directory** with the
host filesystem read-only and capabilities fully dropped. They are **risk
reduction, not a hard security boundary** — see [SPEC.md](SPEC.md) for the
honest threat model.

---

## Project breakdown

```
coding-agent-wrappers/
├── README.md                       # this file
├── SPEC.md                         # threat model, design rationale, all four agents
├── flake.nix                       # standalone consumable flake
│                                   #   nix develop → test-drive all wrappers
│                                   #   packages, overlays, homeManagerModules
├── home.nix                        # minimal inline example (not a flake input)
├── scripts/
│   ├── claude-wrapped.sh           # Claude Code (Anthropic) — granular dotdir
│   ├── codex-wrapped.sh            # Codex CLI (OpenAI) — whole-dir dotdir (EXDEV)
│   ├── grok-wrapped.sh             # Grok CLI (xAI) — whole-dir dotdir (EXDEV)
│   ├── cursor-wrapped.sh           # Cursor CLI — whole-dir dotdir (EXDEV)
│   ├── update-cursor-cli.sh        # bump cursor-cli version + hashes in-place
│   └── update-grok-build-cli.sh    # bump grok-build-cli version + hashes in-place
└── packages/
    ├── cursor-cli/default.nix      # pinned overrideAttrs on nixpkgs cursor-cli
    └── grok-build-cli/default.nix  # fully local fetchurl + autoPatchelfHook
```

---

## The four agents at a glance

| Agent | CLI | Nix source | Dotdir | Auth model | Commands |
|---|---|---|---|---|---|
| Claude Code | `claude-code` | nixpkgs-master (no custom pkg) | `~/.claude` | subscription login (`claude-raw auth login`, creds RW); keyring token fallback (inference-only); `CLAUDE_WRAPPED_PERSIST_CREDS=0` for RO | `claude` / `cw` / `claude-raw` |
| Codex CLI | `codex` | nixpkgs-master (no custom pkg) | `~/.codex` | `auth.json` via `codex-raw login` (OAuth) | `codex` / `cx` / `codex-raw` |
| Grok CLI | `grok` | `packages/grok-build-cli` (fully local) | `~/.grok` | `XAI_API_KEY` (env/keyring) or `grok-raw login` | `grok` / `gw` / `grok-raw` |
| Cursor CLI | `cursor-agent` | `packages/cursor-cli` (pinned override) | `~/.config/cursor` + `~/.local/share/cursor-agent` + `~/.cursor` | `cursor-agent-raw login` (OAuth) | `cursor-agent` / `ca` / `cursor-agent-raw` |

The `-raw` commands bypass the sandbox. Use them only for login/auth setup and
CLI updates.

---

## Quick start — test-drive with `nix develop`

The fastest way to try everything without modifying your system config:

```bash
cd documentation/coding-agent-wrappers   # or wherever you cloned this
nix develop                              # builds all four wrappers; drops into a shell
```

Inside the shell every command is available:

```
claude / cw / claude-raw
codex  / cx / codex-raw
grok   / gw / grok-raw
cursor-agent / ca / cursor-agent-raw
```

Authenticate first (once, per agent — see [Auth setup](#auth-setup)), then run
any agent from inside a project directory:

```bash
cd ~/my-project
claude          # sandboxed to ~/my-project
```

---

## Three ways to consume in your own Nix build

### Option 1 — Home Manager module (recommended for permanent installs)

Add the flake as an input and import the module:

```nix
# your flake.nix
inputs.agent-wrappers.url =
  "github:youruser/dotconfig?dir=documentation/coding-agent-wrappers";

home-manager.lib.homeManagerConfiguration {
  modules = [
    inputs.agent-wrappers.homeManagerModules.default
    # your other modules …
  ];
};
```

The module adds the four wrapped packages to `home.packages` automatically.

### Option 2 — Overlay

If you prefer to control exactly which packages go into `home.packages`:

```nix
# your flake.nix
nixpkgs.overlays = [ inputs.agent-wrappers.overlays.default ];

# then in home.nix:
home.packages = [
  pkgs.claude-wrapped
  pkgs.codex-wrapped
  pkgs.grok-wrapped
  pkgs.cursor-agent-wrapped
];
```

### Option 3 — Copy the `let`-block inline

If you want full control without a flake input, copy the wrapper machinery
directly into your own `home.nix`. See [`home.nix`](home.nix) in this directory
for the complete, copy-pasteable block. The key snippet:

```nix
{ config, pkgs, lib, inputs, ... }:
let
  pkgs-master = import inputs.nixpkgs-master {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  claudeCode  = pkgs-master.claude-code;
  codexCli    = pkgs-master.codex;
  cursorCli   = pkgs.callPackage ./packages/cursor-cli { cursor-cli = pkgs-master.cursor-cli; };
  grok-build-cli = pkgs.callPackage ./packages/grok-build-cli { };
  # … wrapper definitions (see home.nix for the full let-block) …
in
{
  home.packages = [ claudeWrapped codexWrapped grokWrapped cursorWrapped ];
}
```

You also need to copy `packages/cursor-cli/` and `packages/grok-build-cli/`
alongside your `home.nix`, and the four `scripts/*-wrapped.sh` files.

---

## Auth setup

Do this once per agent **before** running the sandboxed command. The `-raw`
escape hatch bypasses the sandbox, so login flows with browser redirects work.

### Claude Code

```bash
# Option A (recommended) — subscription login; credentials auto-refreshed inside sandbox:
claude-raw auth login
# Writes ~/.claude/.credentials.json. The sandbox binds it read-write so
# background token refreshes persist. Full-scope; supports Remote Control.

# Option B — inference-only token via GNOME keyring (fallback when no creds file):
claude-raw setup-token
# Follow the prompts, then store the token:
secret-tool store --label='Claude Code OAuth' service claude-code account "$USER"
# The wrapper reads it automatically. Remote Control is NOT available with this token.

# Option C — API key (pay-per-token, takes precedence over OAuth):
export ANTHROPIC_API_KEY=sk-ant-...
# Or persist it: secret-tool store --label='Anthropic API Key' service anthropic account "$USER"

# Lock down credentials to read-only (one-shot runs, no token mutation):
CLAUDE_WRAPPED_PERSIST_CREDS=0 claude ...
```

### Codex CLI

```bash
codex-raw login     # browser OAuth flow; writes ~/.codex/auth.json
# All subsequent `codex` / `cx` invocations reuse auth.json automatically.
```

### Grok CLI

```bash
# Option A — API key via environment or GNOME keyring:
export XAI_API_KEY=xai-...
# Or store it:
secret-tool store --label='xAI API key' service xai account "$USER"

# Option B — OAuth login:
grok-raw login      # writes ~/.grok/auth.json
```

### Cursor CLI

```bash
cursor-agent-raw login    # browser OAuth flow; writes ~/.config/cursor/auth.json
# All subsequent `cursor-agent` / `ca` invocations reuse auth automatically.
```

---

## Keeping CLIs current

### Claude Code + Codex

These come straight from `nixpkgs-master` — no custom package. Pin
`nixpkgs-master` to a newer commit in your flake's `flake.lock`:

```bash
nix flake update nixpkgs-master
```

### Cursor CLI (pinned override)

```bash
cd documentation/coding-agent-wrappers
bash scripts/update-cursor-cli.sh
# Rewrites packages/cursor-cli/default.nix with new version + hashes.
# Commit the result and rebuild.
```

### Grok CLI (fully local)

```bash
cd documentation/coding-agent-wrappers
bash scripts/update-grok-build-cli.sh
# Rewrites packages/grok-build-cli/default.nix with new version + hashes.
# Commit the result and rebuild.
```

---

## Host-specific knobs (`#ADJUST` markers)

The scripts are designed for a NixOS system with a GNOME keyring (`secret-tool`)
and a modern kernel. Search each script for `#ADJUST` to find the lines most
likely to need changing on your host.

| Knob | Where | Default | Change if… |
|---|---|---|---|
| `SBX_HOME` | all wrappers | `/sbx` | That path is in use on your system. Any writable tmpfs path works. |
| `CA` (TLS cert bundle) | all wrappers | `$NIX_SSL_CERT_FILE` → `/etc/ssl/certs/ca-certificates.crt` | Your cert store lives elsewhere (e.g. `/etc/ssl/cert.pem` on macOS). |
| Keyring service names | `claude-wrapped.sh` | `service claude-code account $USER` | You stored the token under a different label. |
| Keyring service names | `grok-wrapped.sh` | `service xai account $USER` | You stored XAI_API_KEY under a different label. |
| `--new-session` | all wrappers (omitted) | omitted — see §6 of SPEC.md | Add it back if your kernel has `dev.tty.legacy_tiocsti=1` (pre-5.18). |
| Nix daemon socket | all wrappers | `/nix/var/nix/daemon-socket/socket` | Non-NixOS systems with a different daemon socket path. |
| `/run/current-system/sw` | all wrappers | NixOS system profile | Non-NixOS: replace with `$HOME/.nix-profile` or similar. |
| Codex inner sandbox | `codex-wrapped.sh` | `--sandbox danger-full-access` injected | Remove the injection if nested user namespaces work reliably on your kernel. |

---

## Design notes

- **No `makeWrapper`.** Using `pkgs.makeWrapper` would create a `.<cmd>-wrapped`
  sibling binary in `bin/`, landing on PATH and confusing users. The manual PATH
  preamble approach keeps the real store binary reachable from inside the wrapper
  without ever surfacing `.claude-wrapped` etc.

- **EXDEV and whole-dir binds.** Codex, Grok, and Cursor all write config
  atomically (`write-temp → rename`). Binding individual files over a tmpfs puts
  temp and target on different devices, causing `rename(2)` to fail with `EXDEV`.
  The fix is binding the entire dotdir read-write so everything stays on one
  device. Claude is the exception: it supports granular binds because
  `.credentials.json` is bound at its exact canonical path (no tmpfs underneath
  it), so atomic rename succeeds on a single device.

- **`--new-session` removed.** All wrappers previously used `--new-session`
  (`setsid`) to block `TIOCSTI` terminal injection. It was removed after it was
  found to suppress `SIGWINCH` delivery, causing TUI corruption on window resize.
  `TIOCSTI` is already disabled kernel-wide on modern Linux via
  `dev.tty.legacy_tiocsti=0`. Full analysis in [SPEC.md §6](SPEC.md#6-the---new-session--sigwinch-hazard-recorded-finding).

See [SPEC.md](SPEC.md) for the full threat model, all design decisions, and the
checklist for adding new wrappers.
