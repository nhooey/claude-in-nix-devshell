#!/usr/bin/env bats
# Integration tests for the claude-in-nix-devshell shim.
#
# Drives the shim with a controlled PATH containing two stubs:
#   - stub-claude:  records argv + IN_NIX_SHELL to $STUB_CLAUDE_LOG;
#                   short-circuits `--version` so the shim's lookup probe
#                   resolves without polluting the argv log.
#   - stub-nix:     mocks `nix develop --command CMD ARGS` so the shim's
#                   devshell branch is exercisable in any environment
#                   (including the Nix build sandbox where real
#                   nix-in-nix is not viable).
#
# Invoke as:  CLAUDE_SHIM=./src/claude bats tests/integration.bats

bats_require_minimum_version 1.5.0

setup() {
  shim_arg=${CLAUDE_SHIM:?CLAUDE_SHIM not set (e.g. CLAUDE_SHIM=./src/claude bats tests/integration.bats)}
  shim=$(cd "$(dirname "$shim_arg")" && pwd)/$(basename "$shim_arg")
  tests_dir=$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)

  tmp=$(mktemp -d)
  bin=$tmp/bin
  mkdir -p "$bin"
  install -m 755 "$tests_dir/stub-claude" "$bin/claude"
  install -m 755 "$tests_dir/stub-nix" "$bin/nix"

  export PATH="$bin:$PATH"
  export HOME=$tmp
  export GIT_CONFIG_NOSYSTEM=1
  export STUB_CLAUDE_LOG=$tmp/log
  # If bats was invoked from inside a `nix develop`, IN_NIX_SHELL=impure
  # leaks into every child process and would confuse the
  # "didn't enter devshell" assertion. The stub-nix mock re-sets it
  # when the shim's devshell branch fires, so unsetting it here lets
  # the log distinguish the two branches cleanly.
  unset IN_NIX_SHELL

  repo=$tmp/repo
  mkdir -p "$repo"
  (cd "$repo" && git init -q && touch flake.nix)
}

teardown() {
  rm -rf "$tmp"
}

@test "CLAUDE_NIX_DISABLE=1 takes the passthrough branch" {
  cd "$repo"
  : >"$STUB_CLAUDE_LOG"
  run env CLAUDE_NIX_DISABLE=1 bash "$shim" --integration-arg
  [ "$status" -eq 0 ]

  log=$(cat "$STUB_CLAUDE_LOG")
  [[ "$log" == *"argv: --integration-arg"* ]]
  [[ "$log" != *"IN_NIX_SHELL=impure"* ]]
}

@test "CLAUDE_NIX_EXECUTABLE + flake repo invokes devshell branch" {
  alt=$tmp/alt-claude
  cat >"$alt" <<EOF
#!$(command -v bash)
if [ "\$#" = 1 ] && [ "\$1" = "--version" ]; then
  echo "2.0.0-alt"
  exit 0
fi
{
  echo "argv: \$*"
  echo "IN_NIX_SHELL=\${IN_NIX_SHELL:-<unset>}"
} >>"$STUB_CLAUDE_LOG"
EOF
  chmod +x "$alt"
  cd "$repo"
  : >"$STUB_CLAUDE_LOG"
  run env CLAUDE_NIX_EXECUTABLE="$alt" bash "$shim" --integration-arg
  [ "$status" -eq 0 ]

  log=$(cat "$STUB_CLAUDE_LOG")
  [[ "$log" == *"IN_NIX_SHELL=impure"* ]]
  [[ "$log" == *"--session-id"* ]]
}

@test "stale pinned path falls back to PATH scan with warning" {
  run --separate-stderr env CLAUDE_NIX_EXECUTABLE=/does/not/exist bash "$shim" --integration-arg
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"failed --version probe"* ]]
  [[ "$stderr" == *"[src: PATH]"* ]]
}

@test "no claude on PATH exits 127 with descriptive error" {
  # Build a PATH that retains system bins (bash, readlink, etc.) but
  # excludes every dir containing a `claude` executable.
  no_claude_path=""
  IFS=: read -ra parts <<<"$PATH"
  for d in "${parts[@]}"; do
    [ -z "$d" ] && continue
    [ -e "$d/claude" ] && continue
    no_claude_path=${no_claude_path:+$no_claude_path:}$d
  done

  run -127 env PATH="$no_claude_path" bash "$shim" --integration-arg
  [[ "$output" == *"claude-in-nix-devshell"* ]]
  [[ "$output" == *"install Claude Code"* ]]
}

@test "success log surfaces version and source on stderr" {
  run --separate-stderr env CLAUDE_NIX_DISABLE=1 bash "$shim" --integration-arg
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"wrapping "* ]]
  [[ "$stderr" == *"1.0.0-stub"* ]]
  [[ "$stderr" == *"[src: "* ]]
}

@test "CLAUDE_NIX_QUIET=1 silences the wrapping log line" {
  run --separate-stderr env CLAUDE_NIX_QUIET=1 CLAUDE_NIX_DISABLE=1 bash "$shim" --integration-arg
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"wrapping "* ]]
}
