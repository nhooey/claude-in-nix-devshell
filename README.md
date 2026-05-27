# claude-in-nix-devshell

[![Built with Garnix](https://img.shields.io/endpoint?url=https://garnix.io/api/badges/nhooey/claude-in-nix-devshell)](https://garnix.io)

A Nix-packaged wrapper that routes every invocation of the
[Claude Code](https://docs.claude.com/en/docs/claude-code) CLI through the
current project's `nix develop` shell. Adds a `UserPromptSubmit` hook that
detects changes to `flake.nix` / `flake.lock` mid-session and prompts you to
`/exit` so the wrapper can relaunch the session inside the new devShell with
the transcript preserved.

## What it does

Any Claude Code session — whether started from a terminal, the JetBrains
"Claude Code [beta]" plugin, an IDE Run configuration, a script, cron, or an
MCP-driven invocation — runs in whatever environment its caller provides.
For projects with a Nix `flake.nix` defining a `devShells.<system>.default`,
the flake-provided tools and `shellHook` side effects are absent from the
Claude session by default.

This package installs a `claude` PATH-shim that:

1. Locates the real `claude` binary on the user's `$PATH` (excluding itself).
2. Anchors to the git toplevel; outside any repo, passes through unchanged.
3. Pre-flights `nix develop --command true`; if it fails, passes through.
4. Otherwise launches `nix develop --command <real-claude>` with the user's
   args, so the Claude session inherits the devShell's environment.
5. Watches a session-scoped restart flag set by the prompt hook on devShell
   drift, and relaunches `claude --resume <session-id>` inside the new
   devShell when the user types `/exit`.

## Install

### Nix profile

```sh
nix profile install github:nhooey/claude-in-nix-devshell
```

The shim lands at `~/.nix-profile/bin/claude`, the hook at
`~/.nix-profile/libexec/claude-in-nix-devshell/prompt-hook`.

### Home Manager

```nix
{ inputs, pkgs, ... }: {
  home.packages = [
    inputs.claude-in-nix-devshell.packages.${pkgs.system}.default
  ];
}
```

### Manual build + symlink

```sh
nix build github:nhooey/claude-in-nix-devshell
ln -sf "$PWD/result/bin/claude" ~/bin/claude
ln -sf "$PWD/result/libexec/claude-in-nix-devshell/prompt-hook" ~/bin/claude-prompt-hook
```

In every case, the install location must come earlier on `$PATH` than the
real `claude` binary. Verify with `which -a claude`: the shim should be
first; the real binary further down.

## Register the hook

Add the snippet in [`examples/settings.json`](examples/settings.json) to
`~/.claude/settings.json` (or merge it into your existing config).

The hook is what detects `flake.nix` / `flake.lock` drift and prints the
red-background warning. Without it the shim still routes through the
devShell on launch, but won't notice mid-session drift.

## Escape hatches

- `CLAUDE_NIX_DISABLE=1 claude …` — skip the devShell logic entirely
  and exec the real `claude` with the original args.
- `CLAUDE_NIX_EXECUTABLE=/path/to/claude claude …` — invoke this
  executable instead of searching `$PATH`. Useful for testing the shim
  against a stub.
- Run from a directory that isn't inside any git work tree — the shim
  passes through.
- Remove the project's `flake.nix`, or make `nix develop --command true`
  fail — the shim passes through.

## Detection model

On the first prompt of a session the hook records a **content hash** —
`sha256sum` of `flake.nix` and `flake.lock` concatenated. On every
subsequent prompt it re-computes the hash and compares against the
baseline; any change counts as drift, regardless of whether it came from a
pull, a checkout, a new commit, or an uncommitted edit. HEAD movement on
its own does not trigger drift — if the flake files are byte-identical
across the checkout, the resulting devShell is identical too.

Upstream input drift (a tracked branch moving forward, the `nixpkgs` channel
advancing) is **not** detected — that would require network calls on the
prompt-submit hot path. To surface upstream drift, run `nix flake update`;
that bumps `flake.lock`, which the content hash picks up on the next prompt.

## Hacking on this package

```sh
nix develop          # enter the dev shell
nix fmt              # treefmt: nixfmt + shfmt
nix flake check      # treefmt check + build
nix build            # build into ./result
```
