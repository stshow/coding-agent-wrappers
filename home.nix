# home.nix — minimal wrapper example (inline copy-paste path)
#
# This is the "inline" consumption alternative to importing the flake's
# homeManagerModules.default.  Copy the let-block into your own home.nix
# and add the four *Wrapped packages to home.packages.
#
# Prerequisites in your consuming flake:
#   inputs.nixpkgs-master.url = "github:NixOS/nixpkgs/master";
#   home-manager.lib.homeManagerConfiguration {
#     extraSpecialArgs = { inherit inputs; };
#     modules = [ ./home.nix ];
#   };
#
# This file is NOT imported by flake.nix — it is a standalone reference.
# nix-instantiate --parse home.nix   should succeed (syntax check only;
# it won't evaluate because `inputs` is unbound in a raw parse context).

{ config, pkgs, lib, inputs, ... }:

let
  pkgs-master = import inputs.nixpkgs-master {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };

  # ---- CLI binaries ---------------------------------------------------------
  # claude-code and codex come straight from nixpkgs-master (no custom pkg).
  claudeCode = pkgs-master.claude-code;
  codexCli   = pkgs-master.codex;

  # cursor-cli overrides the upstream version/src — requires nixpkgs-master.
  # Run scripts/update-cursor-cli.sh to bump the pinned version + hashes.
  cursorCli  = pkgs.callPackage ./packages/cursor-cli { cursor-cli = pkgs-master.cursor-cli; };

  # grok-build-cli is fully self-contained (fetchurl + autoPatchelfHook).
  # Run scripts/update-grok-build-cli.sh to bump the pinned version + hashes.
  grok-build-cli = pkgs.callPackage ./packages/grok-build-cli { };

  # ---- Wrapper pattern -------------------------------------------------------
  # writeShellScriptBin prepends a PATH preamble so `command -v <cmd>` resolves
  # to the real store binary (not this wrapper) — avoiding recursion.
  # makeWrapper is deliberately NOT used: it creates a .<cmd>-wrapped sibling in
  # bin/ which would land on PATH.  symlinkJoin then exposes the short alias and
  # <cmd>-raw (unconfined, for login/admin tasks).

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
    export PATH="${pkgs.lib.makeBinPath [ grok-build-cli pkgs.bubblewrap pkgs.coreutils pkgs.gnugrep ]}''${PATH:+:$PATH}"
  '' + builtins.readFile ./scripts/grok-wrapped.sh);

  grokWrapped = pkgs.symlinkJoin {
    name = "grok-sandbox-cmds";
    paths = [ grokSandbox ];
    postBuild = ''
      ln -s grok $out/bin/gw
      ln -s ${grok-build-cli}/bin/grok $out/bin/grok-raw
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
in
{
  home.packages = [
    claudeWrapped  # exposes: claude, cw (sandbox), claude-raw (unconfined)
    codexWrapped   # exposes: codex, cx (sandbox), codex-raw (unconfined)
    grokWrapped    # exposes: grok,  gw (sandbox), grok-raw  (unconfined)
    cursorWrapped  # exposes: cursor-agent, ca (sandbox), cursor-agent-raw (unconfined)
  ];
}
