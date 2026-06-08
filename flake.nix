{
  description = "Bubblewrap sandboxes for coding-agent CLIs (Claude, Codex, Grok, Cursor)";

  inputs = {
    nixpkgs.url         = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-master.url  = "github:NixOS/nixpkgs/master";
    flake-utils.url     = "github:numtide/flake-utils";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-master, flake-utils, home-manager }:
    let
      # ---------------------------------------------------------------------------
      # Shared builder: given pkgs (unstable) and pkgs-master, produce the four
      # wrapped packages.  This function is the canonical source of the wrapper
      # logic — devShells, packages, overlays, and the HM module all call it.
      # ---------------------------------------------------------------------------
      makeWrappers = pkgs: pkgs-master:
        let
          # ---- CLI binaries -------------------------------------------------------
          # claude-code and codex come straight from nixpkgs-master (no custom pkg).
          claudeCode  = pkgs-master.claude-code;
          codexCli    = pkgs-master.codex;

          # cursor-cli overrides the upstream version/src to pin a specific release.
          # update-cursor-cli.sh rewrites packages/cursor-cli/default.nix to bump it.
          # Depends on pkgs-master.cursor-cli; the custom package is an overrideAttrs.
          cursorCli   = pkgs.callPackage ./packages/cursor-cli { cursor-cli = pkgs-master.cursor-cli; };

          # grok-build-cli is fully self-contained (fetchurl + autoPatchelfHook).
          # update-grok-build-cli.sh rewrites packages/grok-build-cli/default.nix.
          grokCli     = pkgs.callPackage ./packages/grok-build-cli { };

          # ---- Wrapper pattern ---------------------------------------------------
          # Each wrapper is:
          #   1. writeShellScriptBin "<cmd>" — prepends a PATH preamble so
          #      `command -v <cmd>` inside the script resolves to the store binary
          #      (not this wrapper), avoiding recursion. makeWrapper is deliberately
          #      NOT used: it would create a .<cmd>-wrapped sibling in bin/ that
          #      would land on PATH.
          #   2. symlinkJoin — exposes <cmd>, a short alias, and <cmd>-raw
          #      (the real, unconfined binary for auth/admin tasks).
          # -----------------------------------------------------------------------

          claudeSandbox = pkgs.writeShellScriptBin "claude" (''
            export PATH="${pkgs.lib.makeBinPath [ claudeCode pkgs.bubblewrap pkgs.coreutils ]}''${PATH:+:$PATH}"
          '' + builtins.readFile ./scripts/claude-wrapped.sh);

          claudeWrapped = pkgs.symlinkJoin {
            name = "claude-sandbox-cmds";
            paths = [ claudeSandbox ];
            postBuild = ''
              ln -s claude $out/bin/cw
              ln -s ${claudeCode}/bin/claude $out/bin/claude-raw
            '';
          };

          codexSandbox = pkgs.writeShellScriptBin "codex" (''
            export PATH="${pkgs.lib.makeBinPath [ codexCli pkgs.bubblewrap pkgs.coreutils ]}''${PATH:+:$PATH}"
          '' + builtins.readFile ./scripts/codex-wrapped.sh);

          codexWrapped = pkgs.symlinkJoin {
            name = "codex-sandbox-cmds";
            paths = [ codexSandbox ];
            postBuild = ''
              ln -s codex $out/bin/cx
              ln -s ${codexCli}/bin/codex $out/bin/codex-raw
            '';
          };

          grokSandbox = pkgs.writeShellScriptBin "grok" (''
            export PATH="${pkgs.lib.makeBinPath [ grokCli pkgs.bubblewrap pkgs.coreutils pkgs.gnugrep ]}''${PATH:+:$PATH}"
          '' + builtins.readFile ./scripts/grok-wrapped.sh);

          grokWrapped = pkgs.symlinkJoin {
            name = "grok-sandbox-cmds";
            paths = [ grokSandbox ];
            postBuild = ''
              ln -s grok $out/bin/gw
              ln -s ${grokCli}/bin/grok $out/bin/grok-raw
            '';
          };

          cursorSandbox = pkgs.writeShellScriptBin "cursor-agent" (''
            export PATH="${pkgs.lib.makeBinPath [ cursorCli pkgs.bubblewrap pkgs.coreutils pkgs.gnugrep ]}''${PATH:+:$PATH}"
          '' + builtins.readFile ./scripts/cursor-wrapped.sh);

          cursorWrapped = pkgs.symlinkJoin {
            name = "cursor-sandbox-cmds";
            paths = [ cursorSandbox ];
            postBuild = ''
              ln -s cursor-agent $out/bin/ca
              ln -s ${cursorCli}/bin/cursor-agent $out/bin/cursor-agent-raw
            '';
          };

        in {
          inherit claudeWrapped codexWrapped grokWrapped cursorWrapped;
        };

    in
    # ---------------------------------------------------------------------------
    # Per-system outputs: packages, devShells
    # ---------------------------------------------------------------------------
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        pkgs-master = import nixpkgs-master {
          inherit system;
          config.allowUnfree = true;
        };
        wrappers = makeWrappers pkgs pkgs-master;
      in
      {
        # -----------------------------------------------------------------------
        # packages — build individual wrappers or the full suite at once.
        #
        #   nix build .#claude-wrapped
        #   nix build .#default          # all four combined
        #   nix profile install .        # installs everything
        # -----------------------------------------------------------------------
        packages = {
          claude-wrapped  = wrappers.claudeWrapped;
          codex-wrapped   = wrappers.codexWrapped;
          grok-wrapped    = wrappers.grokWrapped;
          cursor-wrapped  = wrappers.cursorWrapped;

          # default: all four wrappers joined so `nix run`/`nix profile install .`
          # puts every command on PATH at once.
          default = pkgs.symlinkJoin {
            name = "coding-agent-wrappers";
            paths = builtins.attrValues wrappers;
          };
        };

        # -----------------------------------------------------------------------
        # devShells.default — PRIMARY test-drive path.
        #
        #   nix develop
        #
        # Drops into a shell with all eight commands on PATH:
        #   claude / cw / claude-raw
        #   codex  / cx / codex-raw
        #   grok   / gw / grok-raw
        #   cursor-agent / ca / cursor-agent-raw
        #
        # Auth is still required before an agent will actually connect — see the
        # "Auth setup" section in README.md and SPEC.md §4.
        # -----------------------------------------------------------------------
        devShells.default = pkgs.mkShell {
          packages = builtins.attrValues wrappers;

          shellHook = ''
            echo ""
            echo "  Coding-agent wrappers loaded."
            echo "  Commands available (all run sandboxed via bubblewrap):"
            echo ""
            echo "    claude / cw         — Claude Code (Anthropic)"
            echo "    codex  / cx         — Codex CLI   (OpenAI)"
            echo "    grok   / gw         — Grok CLI    (xAI)"
            echo "    cursor-agent / ca   — Cursor CLI  (Cursor)"
            echo ""
            echo "  -raw variants bypass the sandbox (use for login/setup only):"
            echo "    claude-raw | codex-raw | grok-raw | cursor-agent-raw"
            echo ""
            echo "  Auth setup (once per agent) — see README.md for details:"
            echo "    Claude:  claude-raw setup-token  (or export ANTHROPIC_API_KEY=...)"
            echo "    Codex:   codex-raw login"
            echo "    Grok:    grok-raw login  (or export XAI_API_KEY=...)"
            echo "    Cursor:  cursor-agent-raw login"
            echo ""
          '';
        };
      }
    )

    //

    # ---------------------------------------------------------------------------
    # System-independent outputs: overlay, homeManagerModules
    # ---------------------------------------------------------------------------
    {
      # -------------------------------------------------------------------------
      # overlays.default — inject all four wrapped packages into a consumer's pkgs.
      #
      # In your flake:
      #   inputs.agent-wrappers.url = "github:you/dotconfig?dir=documentation/coding-agent-wrappers";
      #   nixpkgs.overlays = [ inputs.agent-wrappers.overlays.default ];
      #   # then in home.packages: pkgs.claude-wrapped, pkgs.codex-wrapped, ...
      # -------------------------------------------------------------------------
      overlays.default = final: prev:
        let
          pkgs-master = import nixpkgs-master {
            inherit (prev.stdenv.hostPlatform) system;
            config.allowUnfree = true;
          };
          wrappers = makeWrappers prev pkgs-master;
        in {
          claude-wrapped       = wrappers.claudeWrapped;
          codex-wrapped        = wrappers.codexWrapped;
          grok-wrapped         = wrappers.grokWrapped;
          cursor-agent-wrapped = wrappers.cursorWrapped;
        };

      # -------------------------------------------------------------------------
      # homeManagerModules.default — drop-in HM module that adds all four wrappers.
      #
      # In your home-manager flake:
      #   inputs.agent-wrappers.url = "...";
      #   home-manager.lib.homeManagerConfiguration {
      #     modules = [ inputs.agent-wrappers.homeManagerModules.default ];
      #   };
      # -------------------------------------------------------------------------
      homeManagerModules.default = { pkgs, lib, ... }:
        let
          pkgs-master = import nixpkgs-master {
            inherit (pkgs.stdenv.hostPlatform) system;
            config.allowUnfree = true;
          };
          wrappers = makeWrappers pkgs pkgs-master;
        in {
          home.packages = [
            wrappers.claudeWrapped  # exposes: claude, cw (sandbox), claude-raw (unconfined)
            wrappers.codexWrapped   # exposes: codex, cx (sandbox), codex-raw (unconfined)
            wrappers.grokWrapped    # exposes: grok,  gw (sandbox), grok-raw  (unconfined)
            wrappers.cursorWrapped  # exposes: cursor-agent, ca (sandbox), cursor-agent-raw (unconfined)
          ];
        };
    };
}
