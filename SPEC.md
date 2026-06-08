# Coding Agent Sandbox Wrappers — Specification & Threat Model

Normative spec for the `*-wrapped` family of scripts in this directory that run
coding agents (Claude Code, OpenAI Codex, xAI Grok, Cursor) confined to a
single project directory on NixOS via
[bubblewrap](https://github.com/containers/bubblewrap).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY**
are used per [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

In scope: `claude-wrapped.sh`, `codex-wrapped.sh`, `grok-wrapped.sh`,
`cursor-wrapped.sh`.

---

## 1. Purpose

These agents execute arbitrary shell commands on the user's behalf, can be
steered by untrusted content (prompt injection from files, web pages, tool
output), and occasionally go off the rails on their own. Run unconfined, a
single bad turn can `rm -rf` outside the project, read every secret in `$HOME`,
or rewrite shell rc files.

The wrappers exist to **reduce that risk**. They are **not** a hard security
boundary and **MUST NOT** be described as one. The honest framing, which every
wrapper's header comment already uses, is *"risk reduction, not a hard
boundary."* Concretely, the goals are to:

- **Limit blast radius** — a runaway or hijacked agent can write to the project
  dir and an ephemeral `$HOME`, and nothing else.
- **Eliminate destructive traversal of the host** — the rest of the filesystem
  is read-only or absent, so the agent cannot delete, encrypt, or corrupt the
  user's wider system.
- **Slow an attacker down** — dropped capabilities, unshared namespaces, and a
  scrubbed environment raise the cost and noise of any escalation attempt.
- **Preserve functionality** — Nix, git, network, and per-tool auth/resume must
  keep working, or users disable the wrapper and we get nothing.

This is a balance, not a proof. It is not perfect; it is what we have. Every
rule below is a point on the safety↔functionality trade-off, and the rationale
is recorded so future wrappers don't silently give back ground.

---

## 2. Threat model

### Defended against (in-scope threats)
- **Accidental destructive commands** outside the project (`rm -rf ~`, writing
  to dotfiles, clobbering `/etc`, etc.).
- **Prompt-injection-driven host traversal** — reading arbitrary secrets under
  `$HOME` (SSH keys, browser data, other tools' tokens), or tampering with
  user config to gain persistence.
- **Privilege escalation via Linux capabilities** — `CAP_*`-dependent attacks
  (mounting, ptrace of other processes, raw sockets, setuid abuse).
- **Credential sprawl** — secrets the agent doesn't need being mounted, or live
  tokens being copied to weakly-protected locations.

### Explicitly NOT defended against (accepted residual risk)
- **Destruction within the project dir.** It is bound read-write by design; the
  agent can trash the very thing you asked it to work on. Use version control.
- **Network exfiltration.** Egress is unrestricted (`--share-net`); an agent can
  POST your project source anywhere. We do not run an egress proxy.
- **A determined attacker escaping the user namespace.** bwrap's unprivileged
  user namespaces are not a security boundary against kernel-level exploits, and
  nested user namespaces are unreliable (see §7). Treat the outer bwrap as
  defense-in-depth, not a jail.
- **Abuse of the shared Nix daemon/store.** Builds run through the host daemon
  (its own root build sandbox) into the shared store. A malicious derivation is
  the daemon's problem, not the wrapper's, but the store is shared state.

If a wrapper weakens any in-scope defense, that **MUST** be called out in its
header comment with the reason (an `#ADJUST`-style marker), not done silently.

---

## 3. Confinement invariants (apply to every wrapper)

Every wrapper **MUST** establish the following via `bwrap`. These are the load-
bearing controls; deviating from any of them requires an explicit, commented
justification in that script.

| Control | Flag(s) | Why |
|---|---|---|
| Unshare all namespaces but network | `--unshare-all --share-net` | Isolate PID/IPC/UTS/cgroup/user/mount; keep net so the agent and Nix work. |
| Die with parent | `--die-with-parent` | No orphaned agent surviving the launching shell. |
| Drop all capabilities | `--cap-drop ALL` | Removes the entire `CAP_*` escalation surface. |
| Host filesystem read-only | `--ro-bind` of `/nix/store`, `/nix/var/nix`, minimal `/etc/*` only | Agent can read what it needs to run; can destroy nothing. |
| Ephemeral `$HOME` | `--tmpfs /sbx` + `--setenv HOME /sbx` | Non-tool state (caches, stray writes) evaporates; nothing leaks to the real home. |
| Ephemeral `/tmp` | `--tmpfs /tmp` | No cross-run residue. |
| Only the project is writable | `--bind "$PROJECT" "$PROJECT"` + `--chdir "$PROJECT"` | The single intended write target. |
| Scrubbed `PATH` | only `/nix/store/*` + system `sw/bin` + `/sbx/.local/bin` | Strips host-home and wrapper paths the sandbox can't see anyway. |
| No keyring/secret-store binds | (omission) | D-Bus / GNOME keyring / secret-service **MUST NOT** be bound into the sandbox. |

Additional requirements:

- The host's secret store (keyring, `secret-tool`, D-Bus) **MUST** be accessed
  only *before* `bwrap`, host-side; only the resolved secret value crosses the
  boundary via `--setenv`. The sandbox **MUST NOT** have a path back to the
  keyring.
- Wrappers **MUST** fail fast with an actionable message when no auth source is
  available, rather than dropping the user into an interactive re-login loop
  inside the sandbox.
- The inner, agent-native sandbox (e.g. Codex's `--sandbox`) **MAY** be relaxed
  *only* because the outer bwrap is the real boundary, and that decision **MUST**
  be commented where it is made.

> **Reference host specifics.** The scripts use `/sbx` as the ephemeral sandbox
> home (`SBX_HOME`), `secret-tool` (GNOME Seahorse) for keyring access, and
> assume a NixOS system layout (`/run/current-system/sw`, `/nix/store`). If your
> host differs, adjust the `#ADJUST`-marked lines; see the README for the full
> list of knobs.

---

## 4. Credential & dotdir exposure

Each agent keeps state under a home dotdir (`~/.claude`, `~/.codex`, etc.). How
much of it is exposed, and read-only vs read-write, is the most security-
sensitive choice each wrapper makes.

### Rules

1. **Least exposure.** A wrapper **MUST** bind only the dotdir contents the agent
   actually needs. Read-only is the default; read-write is granted only to the
   specific files/dirs that genuinely require persistence (auth refresh, session
   resume, history, prompt recall).

2. **Granular binds are preferred (default).** The preferred shape is a
   `--tmpfs` over the dotdir with individual `--ro-bind`/`--bind` entries layered
   on top — code the agent executes (`settings`, `skills`, `agents`, `plugins`)
   read-only, mutable state read-write, everything else ephemeral.
   `claude-wrapped.sh` is the reference implementation.

3. **Whole-dir read-write is a documented exception, never the default.**
   Binding an entire dotdir read-write widens the writable surface and **MUST
   NOT** be done for convenience. It is permitted *only* when a tool's write
   semantics make granular binds incorrect (see §5, EXDEV). When used, the bind
   **MUST** be scoped to the tool's own dotdir and no broader, and the header
   comment **MUST** explain the constraint that forced it.
   `codex-wrapped.sh` is the reference implementation of this exception.

4. **Never copy live credentials to a weaker location.** A wrapper **MUST NOT**
   copy a refresh/OAuth token out of its canonical dotdir path into a temp dir,
   staging area, or any location with a different (or harder-to-reason-about)
   lifetime and permission story. See §5 for why this was explicitly rejected.

5. **Prefer env-injected, non-writable auth.** Where a tool supports a long-lived
   token via environment variable (e.g. `CLAUDE_CODE_OAUTH_TOKEN`), that **SHOULD**
   be the default path: no writable credential file, no on-disk refresh dance.
   Writable credential persistence **SHOULD** be opt-in (e.g. an env flag).
   Where a tool *only* refreshes by writing a file (e.g. Codex `auth.json`), that
   file's directory is bound read-write at its real path and the token is never
   duplicated elsewhere.

   > **Exception — Claude Code subscription credentials (permanent, intentional).**
   > The primary motivation is **Remote Control**: Claude Code's Remote Control
   > feature requires a live, refreshable subscription credential (`credentials.json`)
   > and does not work with an env-injected setup token. Because the sandbox must
   > support Remote Control, `~/.claude/.credentials.json` is bound read-write
   > **by default** so that OAuth refreshes that happen inside the sandbox persist
   > back to the host. The env-token path (`CLAUDE_CODE_OAUTH_TOKEN`, via keyring) is
   > retained as an **inference-only fallback** activated only when no credentials
   > file is present; it does not support Remote Control. Set
   > `CLAUDE_WRAPPED_PERSIST_CREDS=0` to revert credentials to read-only for
   > one-shot agent runs where Remote Control is not needed and token mutation is
   > undesirable. This arrangement still satisfies rule 4: the token never leaves its
   > canonical path — it is bound at `~/.claude/.credentials.json`, not copied to a
   > staging location.

---

## 5. The EXDEV hazard (recorded finding)

**Symptom.** Codex failed to persist folder-trust decisions, surfacing
`config/batchWrite failed in TUI`.

**Root cause.** Codex writes config atomically: write to a temp file, then
`rename(2)` it over the target. The hardened layout mounted the dotdir as a
`--tmpfs` while binding individual files (`config.toml`, `auth.json`) at their
real host-filesystem paths. The temp file therefore landed on the tmpfs and the
rename target on the host fs — **different `st_dev`** — so `rename(2)` returned
`EXDEV` (cross-device link). Codex reported this as a generic "batchWrite
failed." Any agent that uses atomic write-then-rename will hit this whenever the
working directory and the destination file are on different mounts.

**Why this matters for security, not just correctness.** The two ways to fix it
pull in opposite directions on the trade-off:

- **Rejected fix — single-device staging copy.** Copy `auth.json`/`config.toml`
  into a `mktemp -d` staging dir (one device, so renames work), run, then sync
  back. This was rejected by review: it **duplicates a live OAuth refresh token
  onto disk outside the canonical dotdir**. `mktemp -d`'s `0700` helps, but the
  copy survives a `SIGKILL`/OOM/crash (the cleanup `trap` does not catch
  `SIGKILL`), and can be captured by `/tmp` or home snapshots/backups —
  precisely the credential-sprawl threat §2 defends against.

- **Accepted fix — whole-dir read-write bind.** Bind the tool's own dotdir
  read-write as a single mount. Everything is then on one device, atomic renames
  succeed, and the **token never leaves its canonical path** (no copy at all).
  The cost is a wider writable surface *within that one dotdir* (sessions,
  history, sqlite now persist instead of being tmpfs-ephemeral) — a hygiene cost,
  not a host-traversal risk, since the bind is still confined to the dotdir.

**Normative rule.** For an agent with atomic write-then-rename semantics, a
wrapper **MUST** keep temp and target on the same device by binding the tool's
own dotdir read-write (§4 rule 3), and **MUST NOT** resolve EXDEV by copying
credentials to a staging location (§4 rule 4). Prefer granular binds for any
tool that does not exhibit this constraint.

---

## 6. The `--new-session` / SIGWINCH hazard (recorded finding)

**Symptom.** Claude Code and Cursor Agent TUIs distorted and stopped repainting
after running for a while under `bwrap` — never when launched raw. The breakage
was triggered by any terminal window resize that occurred after the agent started.

**Root cause.** Every wrapper originally passed `--new-session` to `bwrap`.
That flag calls `setsid(2)`, which creates a new session with **no controlling
terminal**. Once the process is in a new session, it is no longer a member of
the pty's foreground process group, so the kernel **never delivers `SIGWINCH`**
to it. The agent's TUI captured terminal dimensions at startup and never learned
they had changed, producing corrupted frames that wouldn't repaint. Running raw
preserved the controlling terminal and the signal, which is why that worked.

**The original rationale for `--new-session`.** Its only stated purpose (§3)
was defeating `TIOCSTI` terminal injection — an attack where a process with an
fd to the terminal uses the `TIOCSTI` ioctl to push characters into the parent
shell's input buffer as if the user typed them.

**Resolution.** `--new-session` was dropped from all wrappers. `TIOCSTI` is
already disabled globally on modern Linux hosts by the kernel sysctl
`dev.tty.legacy_tiocsti=0` (Linux ≥5.18-era default, including CachyOS). With
the sysctl at `0`, `TIOCSTI` fails unconditionally regardless of session
membership, so `--new-session` was purely redundant while actively breaking
`SIGWINCH`.

**Normative rule for new wrappers.** Do **not** add `--new-session` unless you
have a concrete reason to need session isolation that overrides TUI correctness.
Verify `dev.tty.legacy_tiocsti` before assuming `TIOCSTI` needs a wrapper-level
guard — on modern kernels it does not.

> **Host-specific assumption.** The wrappers assume `dev.tty.legacy_tiocsti=0`.
> If you are on an older kernel (pre-5.18) where this is not the default, add
> back `--new-session` and accept that terminal resize will break TUI rendering.
> Check with: `sysctl dev.tty.legacy_tiocsti`

---

## 7. Nix packaging methods

Three strategies are used depending on the agent's availability in nixpkgs and
the need to pin a specific version.

### 7.1 Upstream as-is (claude-code, codex)

Some CLIs are already packaged in nixpkgs. Use the upstream package directly:

```nix
claudeCode = pkgs-master.claude-code;
codexCli   = pkgs-master.codex;
```

No custom package file; the CLI tracks whatever nixpkgs-master ships. To get a
specific version, pin `nixpkgs-master` to a specific commit.

**When to use:** the upstream package exists and tracks releases fast enough.

### 7.2 Pinned override (cursor-cli)

When the nixpkgs package exists but doesn't track fast enough (or you need a
specific build), override only the `version` and `src` attrs:

```nix
# packages/cursor-cli/default.nix
{ cursor-cli, fetchurl, stdenv }:
cursor-cli.overrideAttrs (old: {
  version = "0-unstable-2026-06-04";
  src = fetchurl { url = "..."; hash = "sha256-..."; };
  ...
})
```

Called from the consumer:
```nix
cursorCli = pkgs.callPackage ./packages/cursor-cli { cursor-cli = pkgs-master.cursor-cli; };
```

The custom package **depends on the upstream** (`cursor-cli`) for the rest of the
derivation (build inputs, install phase, etc.). `update-cursor-cli.sh` rewrites
`packages/cursor-cli/default.nix` in place via a heredoc whenever a new release
is pinned.

**When to use:** upstream package exists but you need a specific pinned release.

### 7.3 Fully local (grok-build-cli)

When no nixpkgs package exists, build entirely from scratch:

```nix
# packages/grok-build-cli/default.nix
{ lib, stdenv, fetchurl, autoPatchelfHook }:
stdenv.mkDerivation {
  pname = "grok-build-cli";
  version = "0.2.32";
  src = fetchurl { url = "..."; hash = "sha256-..."; };
  nativeBuildInputs = [ autoPatchelfHook ];
  dontUnpack = true;
  installPhase = ''install -Dm755 "$src" "$out/bin/grok"'';
  ...
}
```

No dependency on any upstream package. `update-grok-build-cli.sh` rewrites
`packages/grok-build-cli/default.nix` in place via a heredoc.

**When to use:** no upstream nixpkgs package; CLI ships pre-built ELF binaries.
`autoPatchelfHook` patches the binary's RPATH/interpreter for the Nix store.

---

## 8. The wrapper composition pattern

All four wrappers follow the same Nix-side pattern:

### 8.1 `writeShellScriptBin` + PATH preamble

```nix
claudeSandbox = pkgs.writeShellScriptBin "claude" (''
  export PATH="${pkgs.lib.makeBinPath [ claudeCode pkgs.bubblewrap pkgs.coreutils ]}''${PATH:+:$PATH}"
'' + builtins.readFile ./scripts/claude-wrapped.sh);
```

The PATH preamble ensures `command -v claude` **inside the wrapper script**
resolves to the real store binary (e.g. `/nix/store/…-claude-code-…/bin/claude`),
not the wrapper itself — avoiding infinite recursion.

**Why not `makeWrapper`?** `makeWrapper` creates a `.<cmd>-wrapped` sibling
binary in `bin/`. When both `claude` (the wrapper) and `.claude-wrapped` (the
real binary) land in `bin/`, `.claude-wrapped` becomes visible on PATH and is
confusing. The manual PATH-preamble approach keeps the real binary reachable from
inside the wrapper without ever exposing `.claude-wrapped` to users.

### 8.2 `symlinkJoin` for commands + alias + `-raw`

```nix
claudeWrapped = pkgs.symlinkJoin {
  name = "claude-sandbox-cmds";
  paths = [ claudeSandbox ];
  postBuild = ''
    ln -s claude $out/bin/cw          # short alias for sandboxed
    ln -s ${claudeCode}/bin/claude $out/bin/claude-raw  # unconfined escape hatch
  '';
};
```

Exposed commands per agent:

| Agent | Sandboxed | Short alias | Unconfined |
|---|---|---|---|
| Claude Code | `claude` | `cw` | `claude-raw` |
| Codex CLI | `codex` | `cx` | `codex-raw` |
| Grok CLI | `grok` | `gw` | `grok-raw` |
| Cursor CLI | `cursor-agent` | `ca` | `cursor-agent-raw` |

The `-raw` escape hatch is intentional: `codex-raw login`, `grok-raw login`,
`cursor-agent-raw login` need to run unconfined to complete browser auth flows.

---

## 9. Update scripts

Both pinned packages must be kept current by their update scripts, which
**rewrite their `default.nix` in place** via an escaped heredoc. This approach
was chosen over `sed` substitutions because a full-file heredoc is self-
documenting and cannot partially corrupt the file.

**Heredoc escaping convention:** Nix `${...}` interpolations that must survive
into the generated file are written as `\${...}` in the heredoc. Only the shell
variables for the version and hashes are left unescaped for bash to substitute.

```bash
cat > "$NIX_FILE" <<EOF
  src = fetchurl { url = "\${baseUrl}/grok-${version}-linux-x86_64"; hash = "${hash_x86_64}"; };
EOF
```

Here `\${baseUrl}` and `\${version}` are Nix interpolations (survive to the
file); `${version}` and `${hash_x86_64}` are bash variables (expanded now).

**Normative rule.** An update script **MUST** rewrite its `default.nix` in
place (not just print to stdout). A script that only prints is incomplete —
the maintainer is left to manually paste values, which is error-prone.

---

## 10. Known limitations (be honest)

- **bwrap user namespaces are not a hard jail.** Against a kernel-level exploit
  the outer sandbox is defense-in-depth, not containment.
- **Nested user namespaces are unreliable** inside `--unshare-all`, which is why
  a tool's *inner* sandbox may be relaxed (the outer bwrap is the real boundary).
- **Network egress is open.** No exfiltration protection.
- **The project dir is fully writable.** The agent can still destroy your work;
  the wrapper protects the rest of the system, not the project. Use git.
- **Shared Nix store/daemon** is shared mutable state reachable via the bound
  daemon socket.

A wrapper that cannot honor a §3 invariant **MUST** degrade loudly (warn or
fail), never silently.

---

## 11. Per-wrapper status

| Wrapper | Status | Dotdir | Auth model | Dotdir exposure |
|---|---|---|---|---|
| `claude-wrapped.sh` | shipped | `~/.claude` | subscription login (`~/.credentials.json`) RW by default; keyring token fallback (env, inference-only, no creds file); `CLAUDE_WRAPPED_PERSIST_CREDS=0` for RO | **granular** (reference) |
| `codex-wrapped.sh` | shipped | `~/.codex` | `auth.json` RW at real path (OAuth refresh writes it; no env path) | **whole-dir RW** (EXDEV exception, §5) |
| `grok-wrapped.sh` | shipped | `~/.grok` | env/keyring `XAI_API_KEY` (host-side) + OAuth `auth.json` RW + `config.toml api_key` | **whole-dir RW** (EXDEV exception, §5) |
| `cursor-wrapped.sh` | shipped | `~/.config/cursor` + `~/.local/share/cursor-agent` + `~/.cursor` | OAuth `auth.json` RW (atomic write → §5) | **whole-dir RW** on config + data (EXDEV exception, §5); compile-cache tmpfs |

---

## 12. Checklist for a new wrapper

When adding a wrapper, it **MUST**:

1. Establish every §3 confinement invariant, or document each deviation inline.
2. Resolve auth host-side (§4 rule 5); never bind the keyring into the sandbox.
3. Expose the tool's dotdir with least privilege — granular binds by default
   (§4 rule 2); whole-dir RW only under a documented write-semantics constraint
   (§4 rule 3); never copy credentials to a temp location (§4 rule 4).
4. Determine the tool's write semantics up front. **If it uses atomic
   write-then-rename, apply the §5 rule** to avoid EXDEV.
5. **Do not use `--new-session`** unless you have a specific reason that overrides
   TUI correctness. Check `dev.tty.legacy_tiocsti` — if `0`, TIOCSTI is already
   blocked and `--new-session` is unnecessary. See §6.
6. Fail fast with an actionable message when auth is missing.
7. Carry a header comment stating, per tool: the auth model, which dotdir paths
   are RO vs RW vs tmpfs, and any relaxed inner sandbox with its justification.
8. Keep Nix usable (daemon socket reachable, `NIX_REMOTE=daemon`, store RO-bound)
   so `nix develop`/`nix build` work from inside.
9. Choose the correct **Nix packaging method** (§7): upstream as-is, pinned
   override, or fully local — and write or link the corresponding update script.
10. Follow the **wrapper composition pattern** (§8): PATH-preamble +
    `writeShellScriptBin` + `symlinkJoin` with short alias and `-raw` escape hatch.
