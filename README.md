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

## Prerequisites

### Nix with flakes enabled

Flakes must be enabled in your Nix configuration:

```nix
# /etc/nix/nix.conf  or  ~/.config/nix/nix.conf
experimental-features = nix-command flakes
```

Or pass the flag ad-hoc:

```bash
nix develop --extra-experimental-features "nix-command flakes"
```

On NixOS, the canonical way is:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

### Linux with unprivileged user namespaces (bubblewrap requirement)

Bubblewrap requires unprivileged user namespaces. **This sandboxing is Linux-only.**
macOS is not supported by these wrappers. Windows users can run this via NixOS-WSL — see
[WSL setup](#wsl-windows-subsystem-for-linux) below. macOS users see
[macOS isolation options](#macos-ai-agent-isolation-options) below.

On NixOS (default since 22.05):

```nix
security.unprivilegedUsernsClone = true;  # enabled by default
```

On other Linux distributions, verify:

```bash
# Should print 1
cat /proc/sys/kernel/unprivileged_userns_clone
# or (newer kernels)
sysctl user.max_user_namespaces   # should be > 0
```

If it's 0, enable it:

```bash
sudo sysctl -w kernel.unprivileged_userns_clone=1
# Make permanent:
echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/unprivileged-namespaces.conf
```

### `allowUnfree`

The wrappers pull in unfree CLIs. Where `allowUnfree` needs to be set depends on which
consumption path you use:

| Path | `allowUnfree` required from you? |
|---|---|
| `nix develop` | **No** — already set inside this flake's `nixpkgs` import |
| `packages.${system}.*` as a flake input | **No** — same reason |
| `overlays.default` | **Yes** — builds against your `pkgs`, so your nixpkgs must allow it |
| `homeManagerModules.default` | **Yes** — same |
| Inline let-block (`home.nix`) | **Yes** — same |

### Host-specific knobs

See the [`#ADJUST` table](#host-specific-knobs-adjust-markers) lower in this file for
daemon socket paths, TLS cert bundle locations, `SBX_HOME`, and other knobs that differ
between NixOS and generic Linux setups.

---

## WSL (Windows Subsystem for Linux)

The sandboxes require a real Linux kernel. The easiest path on Windows is
[NixOS-WSL](https://github.com/nix-community/NixOS-WSL), which gives you a
full NixOS instance inside WSL2 with user namespaces already enabled.

**One-time setup:**

```powershell
# 1. Download the latest NixOS-WSL release tarball from
#    https://github.com/nix-community/NixOS-WSL/releases
#    then import it:
wsl --import NixOS $env:USERPROFILE\NixOS nixos-wsl.tar.gz
wsl -d NixOS
```

Inside the NixOS-WSL shell, enable flakes and rebuild:

```bash
# /etc/nixos/configuration.nix  — add these two lines
#   nix.settings.experimental-features = [ "nix-command" "flakes" ];
#   nix.settings.trusted-users = [ "root" "@wheel" ];
sudo nixos-rebuild switch

# Verify
nix --version   # should show 2.x with flakes
```

Then clone and develop as normal:

```bash
git clone https://github.com/stshow/coding-agent-wrappers
cd coding-agent-wrappers
nix develop
```

User namespaces are enabled by default in NixOS-WSL, so bubblewrap works
out of the box. If you hit `bwrap: setting up uid map: Permission denied`,
double-check that WSL2 (not WSL1) is active:

```powershell
wsl --set-version NixOS 2
```

---

## macOS AI Agent Isolation Options

> **Provisional.** I have not yet had a chance to fully review or validate the tools
> listed here — treat this as a starting point, not a security endorsement. Native Nix
> on macOS wrapper support may follow in a future release (no ETA).

The bubblewrap sandboxes in this repo are Linux-only. If you're on macOS, the options
below offer varying degrees of isolation for AI coding agents until a native Nix path
exists.

### Native / non-microVM: [`ai-jail`](https://github.com/akitaonrails/ai-jail)

Use [`ai-jail`](https://github.com/akitaonrails/ai-jail) when you want a practical,
lightweight wrapper around macOS sandboxing for AI coding agents.

Recommended defensive posture:
- Use a private `$HOME`.
- Mask secrets and sensitive paths.
- Do not expose the Docker socket.
- Do not expose display/session sockets unless required.
- Use lockdown mode for untrusted code review.

`ai-jail` is useful as a multi-agent policy wrapper, but it is not a VM boundary. On
macOS it relies on native sandboxing controls — treat it as containment hardening, not
full isolation.

### Local microVM: [Shuru](https://shuru.run/) / [GitHub](https://github.com/superhq-ai/shuru)

Use [Shuru](https://shuru.run/) when you want stronger local isolation on Apple Silicon
Macs.

Shuru runs untrusted AI agents in ephemeral Linux microVMs, with host-side secret
handling, opt-in networking, read-only mounts by default, and checkpointed reuse when
state is needed. This is the stronger default choice when the agent may execute
unfamiliar code and you want isolation closer to a dedicated machine boundary.

### Docker-heavy / team workflows: [Docker AI Sandboxes](https://docs.docker.com/ai/sandboxes/)

Use [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) when the workflow is
already Docker-centered or needs team/admin governance.

The key advantage is that the agent can build images, install packages, and run
containers inside an isolated microVM without exposing the host Docker daemon. This may
be the better operational choice for teams, CI-like workflows, or projects that already
depend heavily on Docker.

### Practical default

| Situation | Recommendation |
|---|---|
| Casual local agent use | [`ai-jail`](https://github.com/akitaonrails/ai-jail) |
| Untrusted code execution | [Shuru](https://shuru.run/) |
| Docker-native / team-managed | [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) |

---

## Quick start — test-drive with `nix develop`

The fastest way to try everything without modifying your system config:

```bash
# From the root of the cloned coding-agent-wrappers repository:
nix develop
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

## Integrating into your own flake

### Which option should I use?

> **Use the `packages` output (Option 1) unless you have a specific reason not to.**
> The overlay and HM module are for when you want the wrappers built against *your*
> nixpkgs rather than this flake's pin. The inline copy is for when you want no flake
> input at all.

### Option 1 — Reference the built packages directly (recommended)

Add this flake as an input and reference `packages.${system}.default` wherever you put
packages. This works with any Nix setup — no home-manager required, no overlay side
effects, and `allowUnfree` is already baked in.

```nix
# your flake.nix
inputs.agent-wrappers.url = "github:stshow/coding-agent-wrappers";
```

Then reference the packages from the input:

```nix
# NixOS — system-wide
environment.systemPackages = [ inputs.agent-wrappers.packages.${system}.default ];

# home-manager — user profile
home.packages = [ inputs.agent-wrappers.packages.${system}.default ];
```

Or install ad-hoc without touching your config:

```bash
nix profile install github:stshow/coding-agent-wrappers
```

Individual wrappers are also available:

```nix
inputs.agent-wrappers.packages.${system}.claude-wrapped
inputs.agent-wrappers.packages.${system}.codex-wrapped
inputs.agent-wrappers.packages.${system}.grok-wrapped
inputs.agent-wrappers.packages.${system}.cursor-wrapped
```

**Pinning:** this path is fully hermetic — the CLIs are built against the nixpkgs pins
recorded in this flake's `flake.lock`. To update to newer CLI versions:

```bash
nix flake update agent-wrappers
```

### Option 2 — Home Manager module

Use this if you want home-manager to manage the packages declaratively as a module
(e.g. you're already composing many HM modules and want this to be one of them). Note:
your nixpkgs must have `allowUnfree = true` because this path builds against your
`pkgs`.

**Standalone home-manager** (`homeManagerConfiguration`):

```nix
# your flake.nix
inputs.agent-wrappers.url = "github:stshow/coding-agent-wrappers";

home-manager.lib.homeManagerConfiguration {
  pkgs = nixpkgs.legacyPackages.${system};   # required
  modules = [
    inputs.agent-wrappers.homeManagerModules.default
    # your other modules …
  ];
};
```

**home-manager as a NixOS module** (the more common pattern):

```nix
# inside your nixosConfigurations.*.modules:
{ inputs, ... }: {
  home-manager.users.<youruser>.imports = [
    inputs.agent-wrappers.homeManagerModules.default
  ];
}
```

The module adds all four wrapped packages to `home.packages` automatically.

### Option 3 — Overlay

Use this if you want the wrappers injected into `pkgs` as named attributes so you can
mix them with other `pkgs.*` references. Builds against **your** nixpkgs, so your
nixpkgs must have `allowUnfree = true`.

As a **NixOS or home-manager module option** (most common):

```nix
nixpkgs.overlays = [ inputs.agent-wrappers.overlays.default ];
```

Or when **manually instantiating nixpkgs** in your flake's `let` block:

```nix
pkgs = import nixpkgs {
  inherit system;
  config.allowUnfree = true;
  overlays = [ inputs.agent-wrappers.overlays.default ];
};
```

Then in your packages list:

```nix
home.packages = [         # or environment.systemPackages
  pkgs.claude-wrapped
  pkgs.codex-wrapped
  pkgs.grok-wrapped
  pkgs.cursor-agent-wrapped   # note: cursor uses cursor-agent-wrapped here
];
```

**nixpkgs-master note:** the overlay still imports this flake's pinned `nixpkgs-master`
for the CLI binaries (`claude-code`, `codex`, `cursor-cli`). Only the wrapper tooling
(`bubblewrap`, `coreutils`, `callPackage`) comes from your nixpkgs.

### Option 4 — Copy the `let`-block inline

Use this if you want zero flake inputs and full local control. Copy the wrapper
machinery into your own `home.nix`. See [`home.nix`](home.nix) in this repo for the
complete, copy-pasteable block.

> **⚠ Path layout is load-bearing.** `home.nix` uses `builtins.readFile ./scripts/*`
> and `pkgs.callPackage ./packages/*`, resolved **relative to `home.nix`'s own
> location**. You must copy `scripts/` and `packages/` at the same relative depth as
> your `home.nix`, or the eval will fail with `path does not exist`.

Files to copy alongside your `home.nix`:
- `scripts/claude-wrapped.sh`
- `scripts/codex-wrapped.sh`
- `scripts/grok-wrapped.sh`
- `scripts/cursor-wrapped.sh`
- `packages/cursor-cli/default.nix`
- `packages/grok-build-cli/default.nix`

Your nixpkgs must have `allowUnfree = true`, and your flake must declare
`inputs.nixpkgs-master.url = "github:NixOS/nixpkgs/master"` (referenced from
`home.nix` as `inputs.nixpkgs-master`).

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
# Run from the repository root
./scripts/update-cursor-cli.sh
# Rewrites packages/cursor-cli/default.nix with new version + hashes.
# Commit the result and rebuild.
```

### Grok CLI (fully local)

```bash
# Run from the repository root
./scripts/update-grok-build-cli.sh
# Rewrites packages/grok-build-cli/default.nix with new version + hashes.
# Commit the result and rebuild.
```

---

## Host-specific knobs (`#ADJUST` markers)

The scripts are designed for a NixOS system with a GNOME keyring (`secret-tool`)
and a modern kernel. Search each script for `#ADJUST` to find the lines most
likely to need changing on your host. See also [Prerequisites](#prerequisites) for
user-namespace setup and `allowUnfree` guidance.

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
