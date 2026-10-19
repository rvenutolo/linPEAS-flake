{ inputs, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      linpeas,
      ...
    }:
    {
      checks = {
        formatting = config.treefmt.build.check inputs.self;
        # `checks.pre-commit` is supplied by the flakeModule,
        # `checks.lint-shell-tools` by nix/devshell-lint.nix and
        # `checks.devshell-renderer-python` by nix/devshell.nix, each kept
        # next to the list it validates.
        # Wire the derivation builds into `nix flake check` so a
        # contributor running only the local check still exercises the
        # build path (fetchurl hash, shebang rewrite, install rules).
        # `linpeas-image` is intentionally excluded — slow and
        # network-heavy; CI's `image-smoke` job covers it.
        linpeas-build = linpeas;

        # Upstream writes linpeas.sh for a POSIX /bin/sh such as dash. Under
        # bash, strings like "\\$[a-zA-Z0-9_]" in its hashed-password regexes
        # parse as bash's `$[...]` arithmetic and abort the script.
        linpeas-runs-under-dash = pkgs.runCommand "linpeas-runs-under-dash" { } ''
          first_line="$(head --lines=1 ${linpeas}/bin/linpeas)"
          if [ "''${first_line}" != "#!${pkgs.dash}/bin/dash" ]; then
            echo "FAIL: linpeas interpreter line is ''${first_line} (want dash)" >&2
            exit 1
          fi
          touch "$out"
        '';

        # `-f` enables the regex searches, so a folder sweep exercises the
        # whole script, including the section a non-POSIX shell breaks.
        # `-n` keeps the sandboxed run offline.
        linpeas-folder-scan = pkgs.runCommand "linpeas-folder-scan" { } ''
          mkdir --parents fixture/etc fixture/root/.ssh
          echo fixture-host >fixture/etc/hostname
          echo '* * * * * root echo FIXTURE_CRON' >fixture/etc/crontab
          echo INERT_FIXTURE_KEY >fixture/root/.ssh/id_rsa
          status=0
          ${linpeas}/bin/linpeas -n -N -q -f "$PWD/fixture" >report.txt 2>&1 || status=$?
          if [ "''${status}" -ne 0 ]; then
            tail --lines=20 report.txt >&2
            echo "FAIL: linpeas -f exited ''${status}" >&2
            exit 1
          fi
          if grep --quiet 'value too great for base' report.txt; then
            grep 'value too great for base' report.txt >&2
            echo "FAIL: linpeas hit a shell arithmetic error" >&2
            exit 1
          fi
          if ! grep --quiet 'fixture/etc/crontab' report.txt; then
            echo "FAIL: report does not mention the fixture crontab" >&2
            exit 1
          fi
          touch "$out"
        '';
      };
    };
}
