{
  lib,
  stdenvNoCC,
  makeWrapper,
  bash,
  coreutils,
  gawk,
  git,
  gnugrep,
  nix,
  util-linux,
  # Optional build-time pin of the real `claude` binary. Either an
  # absolute path string or a derivation exposing `mainProgram = "claude"`
  # (or a `bin/claude`). When set, the wrapper exports
  # CLAUDE_NIX_EXECUTABLE to this path via `--set-default`, so the shim
  # finds the real binary without depending on the caller's PATH — useful
  # for GUI-launched IDEs (e.g. JetBrains) where PATH is minimal.
  # Runtime `CLAUDE_NIX_EXECUTABLE=…` still wins. Null falls back to the
  # original PATH-lookup behavior.
  realClaude ? null,
}:

let
  realClaudePath =
    if realClaude == null then
      null
    else if lib.isDerivation realClaude then
      lib.getExe realClaude
    else
      toString realClaude;
in

stdenvNoCC.mkDerivation {
  pname = "claude-in-nix-devshell";
  version = "0.1.0";

  src = ./src;

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 claude $out/bin/claude
    install -Dm755 prompt-hook $out/libexec/claude-in-nix-devshell/prompt-hook

    # Patch the shebang so the scripts use the bash we pin, not a host bash.
    patchShebangs $out/bin/claude $out/libexec/claude-in-nix-devshell/prompt-hook

    runHook postInstall
  '';

  postFixup =
    let
      shimPath = lib.makeBinPath [
        coreutils
        gawk
        git
        gnugrep
        nix
        util-linux
      ];
      hookPath = lib.makeBinPath [
        coreutils
        gawk
        git
        gnugrep
        nix
        util-linux
      ];
    in
    ''
      wrapProgram $out/bin/claude \
        --prefix PATH : ${shimPath} ${
          lib.optionalString (
            realClaudePath != null
          ) ''--set-default CLAUDE_NIX_EXECUTABLE "${realClaudePath}"''
        }

      wrapProgram $out/libexec/claude-in-nix-devshell/prompt-hook \
        --prefix PATH : ${hookPath}
    '';

  meta = {
    description = "PATH-shim wrapper that routes `claude` through the current project's Nix devShell";
    homepage = "https://github.com/nhooey/claude-in-nix-devshell";
    license = lib.licenses.mit;
    mainProgram = "claude";
    platforms = lib.platforms.unix;
  };
}
