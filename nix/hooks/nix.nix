{
  pkgs-unstable,
  inputs,
  ...
}:
{
  nixfmt = {
    enable = true;
    description = "Nix file formatting.";
  };
  deadnix = {
    enable = true;
    description = "Unused Nix bindings.";
  };
  statix = {
    enable = true;
    description = "Nix anti-pattern lint.";
  };
  # nixpkgs-hammering complements statix: statix catches anti-patterns
  # (with-scope abuse, redundant let), hammering catches nixpkgs idiom
  # misuse on derivations (meta fields, fetcher idioms, build phases).
  # Scoped `files:` so hammer only fires when the flake derivation or
  # its inputs change — hammer evaluates a full nixpkgs overlay and is
  # not cheap.
  nixpkgs-hammering = {
    enable = true;
    name = "nixpkgs-hammering";
    description = "nixpkgs idiom checker for the linpeas derivation.";
    # NIX_PATH exports the pinned nixpkgs store path so the shim can
    # `import <nixpkgs>` without network access — critical for running
    # inside `nix flake check`'s sandbox where github.com is unreachable.
    entry = "${pkgs-unstable.writeShellScript "nixpkgs-hammering-hook" ''
      export NIX_PATH="nixpkgs=${inputs.nixpkgs}"
      exec ${pkgs-unstable.nixpkgs-hammering}/bin/nixpkgs-hammer \
        -f nix/hammer-shim.nix linpeas
    ''}";
    files = "^(flake\\.nix|flake\\.lock|linpeas-pin\\.json|nix/linpeas\\.nix|nix/hammer-shim\\.nix)$";
    pass_filenames = false;
    language = "system";
  };
}
