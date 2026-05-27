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
                bash tests/integration.sh ./src/claude
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
              "tests/integration.sh"
              "tests/stub-claude"
              "tests/stub-nix"
            ];
          };

          devshells.default = {
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
                command = "bash tests/integration.sh ./src/claude";
              }
            ];
          };
        };
    };
}
