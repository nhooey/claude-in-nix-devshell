{
  description = "PATH-shim wrapper that routes `claude` through the current project's Nix devShell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # `agent-skill-flake` is the builder library, not a skill — it provides the
    # `flakeModules.devshellSkills` flake-parts module that wires the dev-shell
    # skill set in below. That module bundles numtide/devshell, so this flake
    # needs no `devshell` input of its own. The skill sources themselves are NOT
    # inputs here: they live only in the `skills-devshell/` sub-flake's lock,
    # which this dev shell invokes at RUNTIME (never as a root input), keeping
    # this flake a leaf with zero skill inputs.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      systems,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      imports = [
        # Bundles numtide/devshell + the whole dev-shell skills convention
        # (motd, install-skills startup, the ci/dev/maintenance command trio,
        # and the reap-skills/update-skills-devshell pair). Configured via the
        # `agent-skill-flake.devshellSkills` options block below.
        inputs.agent-skill-flake.flakeModules.devshellSkills
        inputs.treefmt-nix.flakeModule
      ];

      # The dev-shell skill set (all git-skills skills plus nix-flakes/
      # nix-garnix-ci from nix-skills) lives in the isolated `skills-devshell/`
      # sub-flake and is invoked at RUNTIME (not a root input), so this flake
      # keeps zero skill inputs and never drags the skill mesh into its lock.
      agent-skill-flake.devshellSkills = {
        name = "claude-in-nix-devshell";
      };

      perSystem =
        { pkgs, ... }:
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

          # The devshellSkills module (imported above) supplies this devShell's
          # name, motd, the install-skills startup, the ci/dev/maintenance
          # command trio (check / fmt / update-flake), and the skills commands
          # (reap-skills / update-skills-devshell). Only repo-specific packages
          # and commands are set here; both are list options, so they merge onto
          # the module's rather than replacing them. The module's ci/check and
          # dev/fmt already run `nix flake check` / `nix fmt`, so the local
          # duplicates were dropped.
          devshells.default = {
            packages = [ pkgs.bats ];

            commands = [
              {
                category = "dev";
                name = "build";
                help = "Build the package";
                command = "nix build";
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
