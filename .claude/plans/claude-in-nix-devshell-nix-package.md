# `claude-in-nix-devshell`: a Nix-packaged Claude Code wrapper that auto-routes through the project's devShell and prompts to restart on devShell change

## Context

Any **Claude Code** session — whether started from a terminal, the JetBrains "Claude Code [beta]" plugin, an IDE Run configuration, a script, cron, or an MCP-driven invocation — runs in whatever environment its caller provides. For projects with a Nix `flake.nix` defining a default devShell, that means flake-provided tools (formatters, language toolchains, project-local scripts) and any `shellHook` side effects are absent from the Claude session.

This plan delivers a **standalone Nix-packaged application** (proposed name: `claude-in-nix-devshell`) that any user can install via `nix profile install`, Home Manager, or a manual symlink. The package's primary output is a PATH-shim binary named `claude` that intercepts every Claude Code invocation, decides whether the current directory's flake has a usable devShell, and either routes through `nix develop` or passes through to the real `claude` unchanged.

The package also provides a companion `UserPromptSubmit` hook script. When the hook detects that the devShell's content has changed since the session began, it prints a clearly-formatted red-background warning on the terminal and a system reminder into Claude's context, telling the user *exactly* what will happen on `/exit` and how the conversation will be preserved. A session-scoped restart flag and explicit `--resume <session-id>` ensure two parallel sessions in the same project don't trample each other.

This plan packages and distributes the wrapper; it does not modify any specific project's `flake.nix`, project-scoped skill discovery, or the global `~/.claude/skills/` directory.

## Approach

### Project layout

A new flake-parts-based repository, neutral to any user or org:

```
claude-in-nix-devshell/
├── flake.nix              # flake-parts; exposes packages.default and apps.default
├── flake.lock
├── package.nix            # callPackage-style derivation
├── src/
│   ├── claude              # the PATH-shim wrapper (renamed at install time)
│   └── prompt-hook         # the UserPromptSubmit hook
├── examples/
│   └── settings.json       # snippet showing how to register the hook
├── README.md
└── treefmt.toml            # shfmt + nixfmt
```

The flake uses `flake-parts.lib.mkFlake` with `nix-systems/default` for system iteration, `numtide/devshell` for its own dev environment, and `numtide/treefmt-nix` for formatting (matches the `nix-flakes` skill conventions: input order `nixpkgs → flake-parts → systems → …alphabetical`, multi-attr inputs as nested attrsets, etc.).

### What the package builds

```
$out/
├── bin/
│   └── claude              # the PATH shim (executable)
└── libexec/
    └── claude-in-nix-devshell/
        └── prompt-hook     # the UserPromptSubmit hook (executable)
```

The shim is wrapped at build time with `makeWrapper`, prefixing `PATH` with `coreutils`, `gnugrep`, `gawk`, `util-linux` (for `uuidgen`), and `nix` (so the wrapper's logic uses pinned versions, not whatever happens to be ambient). The hook is wrapped the same way, plus `git`.

### Install model

Users install via one of:

- `nix profile install <flake-url>` — shim lands at `~/.nix-profile/bin/claude`, hook at `~/.nix-profile/libexec/claude-in-nix-devshell/prompt-hook`.
- A Home Manager module reference: `home.packages = [ inputs.claude-in-nix-devshell.packages.${system}.default ];`.
- Manual: `nix build` then symlink `result/bin/claude` and `result/libexec/claude-in-nix-devshell/prompt-hook` into the user's preferred locations.

For all three, the install location must come earlier on `$PATH` than wherever the real `claude` lives. Verified by `which -a claude` (the shim should be first; the real binary should appear further down).

To register the hook, the user adds a snippet to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "command": "${HOME}/.nix-profile/libexec/claude-in-nix-devshell/prompt-hook" }
    ]
  }
}
```

The exact JSON shape should match Claude Code's hook contract at the time of release. The `examples/settings.json` file in the repo carries the up-to-date snippet.

### Locating the real claude binary

At startup, the shim strips its own directory from `$PATH` and resolves `claude` via `command -v` against the remaining path. That absolute path is used for every subsequent invocation — both for the plain-claude fallback and inside `nix develop --command "$REAL_CLAUDE"`. Using the absolute path inside `nix develop` is necessary because the devShell may export its own `$PATH` (which could still include the shim directory), and that would cause infinite recursion.

If the real binary is not found, the shim exits with code 127 and a clear error directing the user to install Claude Code via npm or their preferred channel.

### Detecting a usable devShell

A `flake.nix` may exist without defining `devShells.<system>.default`. The shim pre-flights `nix develop --command true` — the probe enters the shell, runs `true`, exits 0 iff the devShell evaluates and is usable. A missing flake, missing `devShells` output, or eval error all fall through to plain `claude`.

### Tracking the devShell

Mtime is unreliable. The hook captures a per-session baseline of two independent signals on the first prompt:

- **HEAD SHA** — `git rev-parse HEAD`, when the project is inside a git work tree. Empty otherwise.
- **Content hash** — `sha256sum` of `flake.nix` and `flake.lock` concatenated.

On every subsequent prompt it recomputes both and compares against the baseline. Either signal changing counts as devShell drift. HEAD movement indicates a commit-level change (a pull, a checkout, a new local commit); content change without HEAD movement indicates uncommitted edits to `flake.nix` or `flake.lock`. Both signals are independently surfaced in the warning so the user can tell which kind of change triggered the prompt.

Per-session baseline lives at `${XDG_RUNTIME_DIR:-/tmp}/claude-in-nix-devshell-baseline-<session-id>` and stores both values as `head=…` / `content=…` lines. The session-scoped restart flag lives alongside it at `…-restart-<session-id>`. Both are cleaned up by an `EXIT` trap in the wrapper and on each successful resume.

**Upstream input drift is intentionally not tracked.** The `nixpkgs` channel moving forward, an input's GitHub branch getting new commits — those changes are invisible to the wrapper by design. Detecting them would require network calls per prompt, which is too expensive for the prompt-submit hot path. To surface upstream drift, the user runs `nix flake update` (or `nix flake update <input>`); that bumps `flake.lock`, which the existing content-hash detection picks up immediately on the next prompt.

### The red-background warning

When the hook detects a hash change, it does three things:

1. **Writes the restart flag** for *this* session — so two parallel sessions can't interfere.
2. **Prints a red-background, white-text ANSI-formatted warning to stderr** so terminal callers and the JetBrains plugin (which surfaces hook stderr) see it directly.
3. **Injects a system reminder via the hook's stdout JSON** so Claude relays the same message in its response, covering callers whose UI doesn't render stderr ANSI.

The stderr layout has two stacked blocks. The red block carries the headline and the step-by-step "what /exit will do". A dim block below it carries the full hashes for copy-paste.

```
[red bg + bold white]
  ⚠  devShell drift detected

  flake.nix / flake.lock changed since this Claude Code session started.
  The session is still running in the OLD devShell.

      HEAD at start:    abc1234       (line omitted if not in a git repo)
      HEAD now:         def5678       (line omitted if HEAD did not move)
      content at start: 1a2b3c4
      content now:      5e6f7g8

  When you type  /exit  this wrapper will:
    1. See the session-scoped restart flag at <flag-path>.
    2. Clean up the session's tmp files.
    3. Re-evaluate the new devShell via `nix develop --command true`.
    4. Relaunch `claude --resume <session-id>` inside the new devShell.
    5. Your conversation transcript is preserved — no messages are lost.

  Type  /exit  when ready. To skip the wrapper entirely on the next launch,
  set  CLAUDE_NIX_BYPASS=1  in the environment.
[reset]

[dim]
  full hashes:
    HEAD at start:    abc1234567890abcdef1234567890abcdef12345         (omitted if N/A)
    HEAD now:         def5678901234abcdef1234567890abcdef67890         (omitted if N/A)
    content at start: 1a2b3c4d5e6f7890abcd...   (64-char sha256)
    content now:      5e6f7g8h9i0j1k2l3m4n...   (64-char sha256)
[reset]
```

ANSI codes: red background + bold bright white via `\033[41;1;97m`; dim via `\033[2m`; reset via `\033[0m`. If `NO_COLOR` is set in the env or stderr is not a TTY, both blocks render plain text (no ANSI), with the headline replaced by `!!! devShell drift detected !!!` so the urgency still reads at a glance.

### Hash format in the warning

Both formats are shown together (per user decision):

- **Short SHAs** — first 7 chars, git-style — on the headline lines inside the red block. Optimized for at-a-glance scanning on narrow terminals.
- **Full hashes** — 40 chars for git HEAD, 64 chars for sha256 content — in the dim block below, for copy-paste and unambiguous reference.

The HEAD-related lines are elided entirely when not applicable (project isn't git, or HEAD didn't move) so the user isn't shown redundant or empty fields.

### Session ID, resume, and bypass

These behave as in the prior plan iteration:

- The shim assigns a UUID via `claude --session-id <uuid>` at launch (if the CLI supports session assignment up front; otherwise via transcript-directory diff).
- If the user passed `--resume <id>` or `--continue` directly, the shim does not inject its own session ID — it captures `--resume <id>` if present and uses that for the session-scoped flag/baseline paths so the auto-restart loop still works.
- On restart, the wrapper does `claude --resume <session-id>` (never `--continue`) to avoid resuming a different parallel session's most-recent transcript.
- `CLAUDE_NIX_BYPASS=1 claude …` skips the devShell logic entirely and execs the real `claude` with the original args.

### Why a PATH shim rather than per-caller wiring

Per-caller wiring (JetBrains plugin setting, shell aliases, per-tool launchers) requires N configurations and breaks the moment a new caller is added. The PATH shim is one install that intercepts every caller at the resolution layer. It also degrades gracefully — outside a git repo, in a directory with no `flake.nix`, or when the devShell probe fails, the shim exec's the real `claude` directly so callers see no behavior change.

### Wrapper sketch

Path-neutral; `$HOME` and runtime probes only.

```bash
#!/usr/bin/env bash
set -eu

# 1. Locate the real claude binary, avoiding self-recursion.
self_dir=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
clean_path=$(echo "$PATH" | tr ':' '\n' | grep -vxF "$self_dir" | paste -sd: -)
real_claude=$(PATH="$clean_path" command -v claude) || {
  echo "claude-in-nix-devshell: real claude binary not found on PATH (excluding $self_dir)" >&2
  echo "  install Claude Code first (npm, Homebrew, official installer, …) and ensure" >&2
  echo "  it appears on PATH after $self_dir." >&2
  exit 127
}

# 2. Escape hatch.
if [ "${CLAUDE_NIX_BYPASS:-}" = "1" ]; then
  exec "$real_claude" "$@"
fi

# 3. Anchor to the git toplevel; outside any repo, pass through.
root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$root" ]; then
  exec "$real_claude" "$@"
fi
cd "$root"

# 4. Honor user-supplied session flags; otherwise allocate.
session_id=""
inject_session=true
for arg in "$@"; do
  case "$arg" in
    --continue|-c) inject_session=false; break;;
    --resume) inject_session=false;;
  esac
done
if $inject_session; then
  session_id=$(uuidgen | tr 'A-Z' 'a-z')
  set -- --session-id "$session_id" "$@"
fi

state_dir="${XDG_RUNTIME_DIR:-/tmp}"
export CLAUDE_NIX_SESSION_ID="${session_id:-unknown}"
export CLAUDE_NIX_FLAG="$state_dir/claude-in-nix-devshell-restart-$CLAUDE_NIX_SESSION_ID"
export CLAUDE_NIX_BASELINE="$state_dir/claude-in-nix-devshell-baseline-$CLAUDE_NIX_SESSION_ID"
trap 'rm -f "$CLAUDE_NIX_FLAG" "$CLAUDE_NIX_BASELINE"' EXIT

# 5. Restart loop.
while :; do
  if [ -e "$root/flake.nix" ] && nix develop --command true >/dev/null 2>&1; then
    nix develop --command "$real_claude" "$@" || rc=$?
  else
    "$real_claude" "$@" || rc=$?
  fi
  if [ -e "$CLAUDE_NIX_FLAG" ]; then
    rm -f "$CLAUDE_NIX_FLAG" "$CLAUDE_NIX_BASELINE"
    set -- --resume "$CLAUDE_NIX_SESSION_ID"
    continue
  fi
  exit "${rc:-0}"
done
```

### Hook sketch

Path-neutral; reads paths and the session ID from env; tracks both HEAD and content; emits short SHAs in the red block and full hashes in the dim block.

```bash
#!/usr/bin/env bash
set -eu

[ -n "${CLAUDE_NIX_SESSION_ID:-}" ] || exit 0  # not under the wrapper

root=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$root" ] || root=$(pwd)
[ -e "$root/flake.nix" ] || exit 0

# Current state.
head_current=""
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  head_current=$(git -C "$root" rev-parse HEAD 2>/dev/null || true)
fi
content_current=$(cat "$root/flake.nix" "$root/flake.lock" 2>/dev/null \
  | sha256sum | cut -d' ' -f1)

# First prompt of the session: record baseline and exit silently.
if [ ! -e "$CLAUDE_NIX_BASELINE" ]; then
  {
    printf 'head=%s\n' "$head_current"
    printf 'content=%s\n' "$content_current"
  } > "$CLAUDE_NIX_BASELINE"
  exit 0
fi

head_baseline=$(grep '^head=' "$CLAUDE_NIX_BASELINE" | cut -d= -f2-)
content_baseline=$(grep '^content=' "$CLAUDE_NIX_BASELINE" | cut -d= -f2-)

if [ "$head_current" = "$head_baseline" ] && \
   [ "$content_current" = "$content_baseline" ]; then
  exit 0  # no drift
fi

# Drift. Set the flag.
touch "$CLAUDE_NIX_FLAG"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  esc=$'\033'
  red="${esc}[41;1;97m"; dim="${esc}[2m"; reset="${esc}[0m"
else
  red=""; dim=""; reset=""
fi

short() { printf '%s' "${1:0:7}"; }
head_moved=false
[ -n "$head_current" ] && [ "$head_current" != "$head_baseline" ] && head_moved=true

{
  printf '%s\n' "$red"
  if [ -n "$red" ]; then
    printf '  ⚠  devShell drift detected\n\n'
  else
    printf '  !!! devShell drift detected !!!\n\n'
  fi
  printf '  flake.nix / flake.lock changed since this Claude Code session started.\n'
  printf '  The session is still running in the OLD devShell.\n\n'
  if [ -n "$head_baseline" ]; then
    printf '      HEAD at start:    %s\n' "$(short "$head_baseline")"
  fi
  if $head_moved; then
    printf '      HEAD now:         %s\n' "$(short "$head_current")"
  fi
  printf '      content at start: %s\n'   "$(short "$content_baseline")"
  printf '      content now:      %s\n\n' "$(short "$content_current")"
  printf '  When you type  /exit  this wrapper will:\n'
  printf '    1. See the session-scoped restart flag at %s\n' "$CLAUDE_NIX_FLAG"
  printf '    2. Clean up the session tmp files.\n'
  printf '    3. Re-evaluate the new devShell via `nix develop --command true`.\n'
  printf '    4. Relaunch `claude --resume %s` inside the new devShell.\n' \
    "$CLAUDE_NIX_SESSION_ID"
  printf '    5. Your conversation transcript is preserved — no messages are lost.\n\n'
  printf '  Type  /exit  when ready. To skip the wrapper entirely on the next launch,\n'
  printf '  set  CLAUDE_NIX_BYPASS=1  in the environment.\n'
  printf '%s\n\n' "$reset"

  printf '%s' "$dim"
  printf '  full hashes:\n'
  [ -n "$head_baseline" ] && printf '    HEAD at start:    %s\n' "$head_baseline"
  $head_moved              && printf '    HEAD now:         %s\n' "$head_current"
  printf '    content at start: %s\n' "$content_baseline"
  printf '    content now:      %s\n' "$content_current"
  printf '%s\n' "$reset"
} >&2

# Inject equivalent text as a system reminder via stdout JSON so Claude relays it.
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"devShell drift detected. content_at_start=$(short "$content_baseline") content_now=$(short "$content_current")$($head_moved && printf ' HEAD %s->%s' "$(short "$head_baseline")" "$(short "$head_current")"). When the user types /exit, the wrapper will: (1) see the restart flag, (2) clean up tmp files, (3) re-evaluate the new devShell via nix develop --command true, (4) relaunch claude --resume $CLAUDE_NIX_SESSION_ID inside the new devShell, (5) preserve the conversation transcript. Tell the user this clearly once, then continue with their prompt."}}
EOF
```

JSON shape must be verified against the current Claude Code hook contract at implementation time.

## Critical files

The new repo's source tree:

- `flake.nix` — flake-parts skeleton: inputs, `perSystem.packages.default`, `apps.default`, `treefmt`.
- `package.nix` — derivation that installs the shim and hook, wrapped with their runtime deps.
- `src/claude` — the PATH-shim wrapper (script above).
- `src/prompt-hook` — the `UserPromptSubmit` hook (script above).
- `examples/settings.json` — registration snippet, kept current with Claude Code's hook contract.
- `README.md` — install paths, prerequisites, escape hatches, troubleshooting.
- `treefmt.toml` — `shfmt` + `nixfmt-rfc-style`.

## Verification

1. **Build the package.** `nix build` from the repo root succeeds and produces `result/bin/claude` plus `result/libexec/claude-in-nix-devshell/prompt-hook`.
2. **Treefmt clean.** `nix flake check` passes (treefmt + any other added checks).
3. **Shim is found first.** After install, `which -a claude` lists the shim first and at least one other claude binary further down.
4. **GUI apps see the shim.** Launch a GUI-only app, open a terminal inside it, run `which claude`. Should be the shim.
5. **Terminal + devShell.** `cd` into a project with a working `devShells.<system>.default`, run `claude`. Inside the session run `echo $IN_NIX_SHELL` — devShell env present.
6. **JetBrains plugin path.** Open the same project in the JetBrains IDE; behavior matches #5.
7. **No flake / non-flake repo / outside any repo.** Plain `claude` launches in all three cases — no errors, no Nix calls.
8. **Flake without devShell.** The probe fails silently; plain `claude` launches.
9. **Uncommitted edit triggers restart.** In #5, mid-session, edit `flake.nix` and save (no commit). Send a prompt — expect the red-background warning on stderr citing `content at start` / `content now` only (no HEAD lines, since HEAD did not move). Type `/exit`; wrapper relaunches with `--resume <same-id>`; transcript intact; new content reflected in the devShell.
10. **HEAD move triggers restart.** In #5, in a separate terminal `git commit` a change to `flake.nix`, then `cd back` to the working tree. Send a prompt — expect the warning citing both HEAD-at-start, HEAD-now, content-at-start, content-now.
11. **Upstream drift is invisible (intentional).** Without touching the project, do nothing locally but let an upstream input (e.g., a tracked nixpkgs branch) move forward. Expect no warning. Then run `nix flake update`; on the next prompt the warning fires (`flake.lock` content changed).
12. **Full hashes block.** Confirm the dim block below the red block contains the full SHAs (40-char HEAD, 64-char sha256), copy-pastable.
13. **Color suppression.** Set `NO_COLOR=1` (or redirect stderr to a file). Warning still prints, now without ANSI escapes; headline becomes `!!! devShell drift detected !!!`.
14. **Two parallel sessions.** Two windows on the same project. Each gets a distinct session ID. Trigger a devShell change. Each window's hook writes only its own flag; each `/exit` resumes that window's session.
15. **Hash precision.** `touch flake.nix` without content change — no restart prompt. Comment-only edit — restart prompt (acceptable false positive, documented).
16. **User-supplied resume.** `claude --continue` and `claude --resume <id>` pass through cleanly. For `--resume`, the captured ID is used for flag/baseline paths.
17. **Bypass.** `CLAUDE_NIX_BYPASS=1 claude` exec's the real claude with no flake handling.
18. **Real-binary missing.** Uninstall the real claude. Shim exits 127 with a clear error pointing at how to install it.
