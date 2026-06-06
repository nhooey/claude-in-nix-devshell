{
  description = "claude-in-nix-devshell dev-shell skill set — an isolated sub-flake invoked at RUNTIME by the root devShell, never a root input. The skill sources (all git-skills skills plus nix-flakes/nix-garnix-ci from nix-skills) live only in THIS flake's lock, so the root claude-in-nix-devshell stays a leaf with zero skill inputs and transitive consumers never drag the skill mesh in.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    # `agent-skill-flake` is the builder library, not a skill — it provides
    # `mkDevshellSkillsFlake`. Followed by every skill source below so the
    # whole tree shares one evaluation.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Every input below this divider is a skill source.

    # All of git-skills's skills (git hygiene, GitHub policy, PR lifecycle).
    git-skills = {
      url = "github:nhooey/git-skills";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        agent-skill-flake.follows = "agent-skill-flake";
      };
    };

    # nix-skills: only the nix-flakes and nix-garnix-ci skills are cherry-picked
    # below; the source is pulled whole and the subset is selected in the
    # combination's `sources` entry. Its builder input is followed onto our
    # `agent-skill-flake` node so the builder collapses to one evaluation;
    # nix-skills's own dev shell is never on our evaluation path (we consume
    # only its skill packages).
    nix-skills = {
      url = "github:nhooey/nix-skills";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        agent-skill-flake.follows = "agent-skill-flake";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      agent-skill-flake,
      git-skills,
      nix-skills,
      ...
    }@inputs:
    agent-skill-flake.lib.mkDevshellSkillsFlake {
      inherit nixpkgs;
      systems = import inputs.systems;
      name = "claude-in-nix-devshell-skills";
      sources = [
        { source = git-skills; }
        {
          source = nix-skills;
          skills = [
            "nix-flakes"
            "nix-garnix-ci"
          ];
        }
      ];
    };
}
