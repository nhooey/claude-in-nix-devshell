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
}:

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
        --prefix PATH : ${shimPath}

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
