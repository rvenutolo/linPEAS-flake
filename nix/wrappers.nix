{
  perSystem =
    { pkgs-unstable, ... }:
    let
      # actionlint discovers embedded shellcheck via $PATH. Hook
      # invocations from a shell that has not entered the devShell
      # (fresh checkout without direnv, CI step that forgot
      # `nix develop`) silently degrade: actionlint exits 0 with
      # shellcheck coverage disabled. Pinning the binary path here
      # makes discovery deterministic at flake evaluation. See
      # docs/actionlint-embedded-linters.md.
      actionlintWrapped = pkgs-unstable.writeShellScriptBin "actionlint" ''
        exec ${pkgs-unstable.actionlint}/bin/actionlint \
          -shellcheck=${pkgs-unstable.shellcheck}/bin/shellcheck \
          "$@"
      '';

      # Wrap the bundled pre-commit binary to scrub PYTHONPATH before
      # exec. pre-commit's Python launcher uses `site.addsitedir`, which
      # APPENDS its bundled site-packages to sys.path — so any older
      # `pre_commit` module reachable via an externally-inherited
      # PYTHONPATH (a stale direnv profile, a parent shell that left
      # `python3Packages.pre-commit` on the path, etc.) wins over the
      # bundled one. When the inherited version pre-dates pre-commit
      # 4.4.0 it rejects `language: unsupported` (the post-4.4 default
      # emitted by git-hooks.nix) and every `git commit` fails before
      # any hook runs.
      #
      # Override via `overrideAttrs` rather than a separate wrapper
      # derivation so the upstream hook-tmpl resource (which has
      # `$out/bin/pre-commit` substituted at build time and ends up
      # baked into every `.git/hooks/pre-commit`) keeps pointing at the
      # binary committers actually run. A separate writeShellScriptBin
      # wrapper would not be reached by `pre-commit install` — only
      # `nix develop`-time invocations would see it.
      preCommitWrapped = pkgs-unstable.pre-commit.overrideAttrs (old: {
        postFixup = (old.postFixup or "") + ''
          mv "$out/bin/pre-commit" "$out/bin/.pre-commit-real"
          cat > "$out/bin/pre-commit" <<EOF
          #!${pkgs-unstable.bash}/bin/bash
          unset PYTHONPATH
          exec "$out/bin/.pre-commit-real" "\$@"
          EOF
          chmod +x "$out/bin/pre-commit"
        '';
      });
    in
    {
      _module.args = { inherit actionlintWrapped preCommitWrapped; };
    };
}
