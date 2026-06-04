{
  description = "PATH-shim wrapper that routes `claude` through the current project's Nix devShell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";

    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Source of `lib.mkCombination`, which builds the dev-shell skill set
    # (`devshellSkills` in `outputs`). Infrastructure-only — no packages.
    flake-skills = {
      url = "github:nhooey/flake-skills";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ---------------------------------------------------------------------
    # Dev-shell skill sources (inlined — consumed only by `devshells` below)
    # ---------------------------------------------------------------------
    # The project dev shell installs one curated skill set: the git/GitHub
    # pack plus the nix-flakes / nix-garnix-ci skills from skills-nix —
    # combined via flake-skills' `mkCombination` in `outputs` (`devshellSkills`).
    # These were previously isolated in a `skills-devshell/` sub-flake, but a
    # same-repo sub-flake can only be addressed by a relative `path:` input
    # (which sandboxed/transitive consumers reject) or a brittle self-URL
    # (which breaks on any repo/owner/host rename), so they are inlined here.
    #
    # Both `follows` only the parent `nixpkgs` — NOT `flake-skills`. Forcing
    # `flake-skills.follows` would make the combination's transitive sources
    # resolve against this root's owner-namespacing flake-skills and trip a
    # strict null-owner check; following only nixpkgs and letting each source
    # keep its own flake-skills is the proven working pattern.
    skills-git = {
      url = "github:nhooey/skills-git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    skills-nix = {
      url = "github:nhooey/skills-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      nixpkgs,
      flake-parts,
      flake-skills,
      systems,
      ...
    }:
    let
      # The project dev-shell skill set, combined from the inlined skill
      # sources (the git/GitHub pack plus nix-flakes / nix-garnix-ci from
      # skills-nix). `reconcileScript` is a `system -> string` function the
      # dev shell splices into a startup hook.
      devshellSkills = flake-skills.lib.mkCombination {
        inherit nixpkgs;
        name = "claude-in-nix-devshell-devshell";
        envName = "agent-skills-claude-in-nix-devshell-devshell";
        packagePrefix = "agent-skill-";
        sources = [
          { source = inputs.skills-git; }
          {
            source = inputs.skills-nix;
            skills = [
              "nix-flakes"
              "nix-garnix-ci"
            ];
          }
        ];
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      imports = [
        inputs.devshell.flakeModule
        inputs.treefmt-nix.flakeModule
      ];

      perSystem =
        { pkgs, system, ... }:
        {
          packages.default = pkgs.callPackage ./package.nix { };

          apps.default = {
            type = "app";
            program = "${pkgs.callPackage ./package.nix { }}/bin/claude";
          };

          checks.integration =
            pkgs.runCommand "integration-test"
              {
                nativeBuildInputs = with pkgs; [
                  bash
                  bats
                  coreutils
                  gawk
                  git
                  gnugrep
                  util-linux
                ];
              }
              ''
                cp -r ${./src} src
                cp -r ${./tests} tests
                chmod -R u+w src tests
                patchShebangs src tests
                export HOME=$TMPDIR
                CLAUDE_SHIM=./src/claude bats tests/integration.bats
                touch $out
              '';

          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              shfmt.enable = true;
            };
            settings.formatter.shfmt.includes = [
              "src/claude"
              "src/prompt-hook"
              "tests/stub-claude"
              "tests/stub-nix"
            ];
          };

          # Auto-reconcile the dev-shell skill set (git/GitHub pack +
          # nix-flakes / nix-garnix-ci from skills-nix) at project scope on
          # `nix develop`. `devshellSkills.reconcileScript` yields the reconcile
          # one-liner per system; this just splices it in.
          devshells.default = {
            packages = [ pkgs.bats ];
            devshell.startup.install-skills.text = ''
              ${devshellSkills.reconcileScript system}
            '';
            commands = [
              {
                category = "dev";
                name = "build";
                help = "Build the package";
                command = "nix build";
              }
              {
                category = "dev";
                name = "check";
                help = "Run flake checks (treefmt + build + integration)";
                command = "nix flake check";
              }
              {
                category = "dev";
                name = "fmt";
                help = "Format source with treefmt";
                command = "nix fmt";
              }
              {
                category = "dev";
                name = "tests";
                help = "Run integration tests against ./src/claude";
                command = "CLAUDE_SHIM=./src/claude bats tests/integration.bats";
              }
            ];
          };
        };
    };
}
