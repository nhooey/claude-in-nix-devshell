#!/usr/bin/env bash
# Integration tests for the claude-in-nix-devshell shim.
#
# Drives src/claude with a controlled PATH containing two stubs:
#   - stub-claude:  records argv + IN_NIX_SHELL to $STUB_CLAUDE_LOG.
#   - stub-nix:     mocks `nix develop --command CMD ARGS` so the shim's
#                   devshell branch is exercisable in any environment
#                   (including the Nix build sandbox where real
#                   nix-in-nix is not viable).
set -eu

shim_arg=${1:?usage: integration.sh <path-to-src/claude>}
shim=$(cd "$(dirname "$shim_arg")" && pwd)/$(basename "$shim_arg")
tests_dir=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bin=$tmp/bin
mkdir -p "$bin"
install -m 755 "$tests_dir/stub-claude" "$bin/claude"
install -m 755 "$tests_dir/stub-nix" "$bin/nix"

export PATH="$bin:$PATH"
export HOME=$tmp
export GIT_CONFIG_NOSYSTEM=1
export STUB_CLAUDE_LOG=$tmp/log

pass=0
fail=0
expect() {
  if printf '%s' "$3" | grep -qF -- "$2"; then
    pass=$((pass + 1))
    echo "ok: $1"
  else
    fail=$((fail + 1))
    {
      echo "FAIL: $1"
      echo "  expected to contain: $2"
      echo "  got:"
      printf '%s\n' "$3" | sed 's/^/    /'
    } >&2
  fi
}
reject() {
  if printf '%s' "$3" | grep -qF -- "$2"; then
    fail=$((fail + 1))
    {
      echo "FAIL: $1"
      echo "  expected NOT to contain: $2"
      echo "  got:"
      printf '%s\n' "$3" | sed 's/^/    /'
    } >&2
  else
    pass=$((pass + 1))
    echo "ok: $1"
  fi
}

# Fixture: git repo with a flake.nix.
repo=$tmp/repo
mkdir -p "$repo"
(cd "$repo" && git init -q && touch flake.nix)

# --- Test 1: CLAUDE_NIX_DISABLE=1 takes the passthrough branch.
: >"$STUB_CLAUDE_LOG"
(cd "$repo" && CLAUDE_NIX_DISABLE=1 bash "$shim" --version) >/dev/null
out=$(cat "$STUB_CLAUDE_LOG")
expect "disable: argv passes through bare" "argv: --version" "$out"
reject "disable: nix-develop not entered" "IN_NIX_SHELL=impure" "$out"

# --- Test 2: CLAUDE_NIX_EXECUTABLE + flake repo → devshell branch fires.
alt=$tmp/alt-claude
cat >"$alt" <<EOF
#!$(command -v bash)
{
  echo "argv: \$*"
  echo "IN_NIX_SHELL=\${IN_NIX_SHELL:-<unset>}"
} >>"$STUB_CLAUDE_LOG"
EOF
chmod +x "$alt"
: >"$STUB_CLAUDE_LOG"
(cd "$repo" && CLAUDE_NIX_EXECUTABLE=$alt bash "$shim" --version) >/dev/null
out=$(cat "$STUB_CLAUDE_LOG")
expect "executable: alt invoked under devshell" "IN_NIX_SHELL=impure" "$out"
expect "executable: session-id injected" "--session-id" "$out"

# --- Test 3: CLAUDE_NIX_EXECUTABLE pointing at a non-executable path → exit 127.
set +e
out=$(CLAUDE_NIX_EXECUTABLE=/does/not/exist bash "$shim" --version 2>&1)
rc=$?
set -e
if [ "$rc" = "127" ]; then
  pass=$((pass + 1))
  echo "ok: bad executable exits 127"
else
  fail=$((fail + 1))
  echo "FAIL: bad executable expected exit 127, got $rc" >&2
fi
expect "bad executable: error message" "is not executable" "$out"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = "0" ]
