{ inputs, ... }:
{
  perSystem =
    {
      pkgs,
      pkgs-unstable,
      pin,
      linpeas,
      ...
    }:
    let
      linpeas-image = pkgs.dockerTools.buildLayeredImage {
        name = "rvenutolo/linpeas";
        tag = pin.version;

        # `buildLayeredImage` takes image contents via `contents`. Wrap
        # inputs in a `buildEnv` so `pathsToLink` controls the /bin layering
        # explicitly. `Entrypoint` (set below) uses the absolute store path
        # of linpeas, unambiguous regardless of /bin layering.
        contents = pkgs.buildEnv {
          name = "image-root";
          # linpeas invokes grep/sed/awk/find/ps internally for most of its
          # checks. Ship them so the image is actually useful for its
          # intended use cases (container audit, CI image scanning,
          # forensics on mounted captured filesystems, and host audit when
          # launched with host namespaces + bind mount). See
          # docs/install/docker.md for the use-case framing.
          paths = [
            pkgs.bashInteractive
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.gawk
            pkgs.findutils
            # Override drops libsystemd from procps, which in turn
            # drops systemd-minimal-libs and libcap from the image
            # closure. linpeas enumerates processes via plain
            # `ps -e` / `ps auxf` and does not read systemd
            # unit-name columns, so the lost functionality is
            # irrelevant here; the win is a smaller OCI attack
            # surface (no libsystemd/libcap CVE exposure).
            (pkgs.procps.override { withSystemd = false; })
            linpeas
          ];
          pathsToLink = [ "/bin" ];
        };

        config = {
          # Entrypoint (not Cmd) so `docker run <img> <args>` appends to
          # linpeas rather than replacing it. The image-smoke CI job
          # runs `docker run --rm <img> -h` and expects -h to reach
          # linpeas.
          Entrypoint = [ "${linpeas}/bin/linpeas" ];
          Labels = {
            "org.opencontainers.image.source" = "https://github.com/rvenutolo/linPEAS-flake";
            "org.opencontainers.image.description" = "LinPEAS — Linux Privilege Escalation Awesome Script";
            "org.opencontainers.image.licenses" = "MIT";
            "org.opencontainers.image.version" = pin.version;
            # Wrapper-repo commit SHA at build time. Build-provenance
            # attestation already binds the image to this commit, but
            # the label is readable via `docker inspect` without
            # `gh attestation verify` round-tripping. Falls back to
            # `dirtyRev` for uncommitted local builds.
            "org.opencontainers.image.revision" = inputs.self.rev or inputs.self.dirtyRev or "unknown";
          };
        };
      };

      site = pkgs-unstable.stdenv.mkDerivation {
        pname = "linpeas-flake-site";
        inherit (pin) version;
        src = ../.;
        nativeBuildInputs = with pkgs-unstable.python3Packages; [
          mkdocs-material
          mkdocs-macros
        ];
        buildPhase = ''
          runHook preBuild
          if [ ! -f docs/_data/dashboard.yml ]; then
            echo "ERROR: docs/_data/dashboard.yml missing. Run 'just site-data' first or use 'just site-dev'." >&2
            exit 1
          fi
          mkdocs build --strict --site-dir $out/share/site
          runHook postBuild
        '';
        dontInstall = true;
      };
    in
    {
      packages = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
        inherit linpeas-image site;
      };
    };
}
