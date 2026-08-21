{
  perSystem =
    { pkgs-unstable, ... }:
    let
      # actionlint discovers its embedded linters via $PATH, and which
      # binaries land there is nixpkgs' packaging decision rather than
      # this repo's: the nixpkgs actionlint is itself a wrapper that
      # prepends its own shellcheck and pyflakes. Naming both paths here
      # makes the pairing this repo's own, so a nixpkgs change that drops
      # or repoints either one surfaces as a canary failure instead of as
      # embedded coverage silently going quiet. See
      # docs/actionlint-embedded-linters.md.
      actionlintWrapped = pkgs-unstable.writeShellScriptBin "actionlint" ''
        exec ${pkgs-unstable.actionlint}/bin/actionlint \
          -shellcheck=${pkgs-unstable.shellcheck}/bin/shellcheck \
          -pyflakes=${pkgs-unstable.python3Packages.pyflakes}/bin/pyflakes \
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
      #
      # `dontUsePytestCheck`: the override changes the derivation hash,
      # so this build is never substitutable from cache.nixos.org — any
      # binary-cache miss (e.g. cache.nixos.org rate-limiting under
      # CI's parallel job fan-out) falls back to building it from
      # source on the runner. Re-running upstream's ~700-test pytest
      # suite there adds no signal (the unmodified base package already
      # passed it in nixpkgs' own build) and a single flaky upstream
      # test can fail an unrelated CI job. Skipping the suite makes the
      # fallback rebuild deterministic and fast; a cache miss degrades
      # to a slowdown instead of a failure. (`dontUsePytestCheck`
      # rather than `doInstallCheck = false` because nixpkgs'
      # pytestCheckHook setup-hook force-sets `doInstallCheck=1` at
      # build time; the attr alone is silently ignored.
      # pythonImportsCheck still runs.)
      preCommitWrapped = pkgs-unstable.pre-commit.overrideAttrs (old: {
        dontUsePytestCheck = true;
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
