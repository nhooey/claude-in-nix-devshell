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

    # `agent-skill-flake` is the builder library, not a skill — it provides the
    # `devshellSkillsHook` that wires the dev-shell skill set in below. The skill
    # sources themselves are NOT inputs here: they live only in the
    # `skills-devshell/` sub-flake's lock, which this dev shell invokes at
    # RUNTIME (never as a root input), keeping this flake a leaf with zero skill
    # inputs.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      systems,
      agent-skill-flake,
      ...
    }:
    let
      # Root-side wiring for the `skills-devshell/` sub-flake: the dev-shell
      # skill set (all skills-git skills plus nix-flakes/nix-garnix-ci from
      # skills-nix) is defined in the isolated `skills-devshell/` sub-flake and
      # invoked here at RUNTIME (not a root input), so this flake keeps zero
      # skill inputs and never drags the skill mesh into its lock.
      devshellSkills = agent-skill-flake.lib.devshellSkillsHook { };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      imports = [
        inputs.devshell.flakeModule
        inputs.treefmt-nix.flakeModule
      ];

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

          devshells.default = {
            packages = [ pkgs.bats ];

            # Auto-reconcile the dev-shell skill set at project scope on
            # `nix develop`: every skills-git skill plus nix-flakes/
            # nix-garnix-ci from skills-nix, merged into one combination that a
            # single reconcile owner converges — declarative + idempotent. The
            # skills-devshell sub-flake's reconcile app is invoked at RUNTIME by
            # this hook (`nix run "$PRJ_ROOT/skills-devshell#reconcile"`), so the
            # skill sources never become root inputs.
            devshell.startup.install-skills.text = devshellSkills.startup;

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
            ]
            ++ devshellSkills.commands;
          };
        };
    };
}
