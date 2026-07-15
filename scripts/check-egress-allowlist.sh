#!/usr/bin/env bash
# scripts/check-egress-allowlist.sh
#
# @description Lint: every job's harden-runner `allowed-endpoints` list
# carries the hosts its tool inventory actually reaches, carries a complete
# sigstore host set if it carries any sigstore host at all, and carries no
# denylisted host.

# Binds each job's `allowed-endpoints` list to what the job's tooling actually
# reaches. Hand-authored allowlists rot silently: a tool version bumps, a URL
# changes, or a fallback path activates, and the list is not updated. The
# resulting failure is latent — it surfaces only when the blocked path is
# finally exercised, which can be months later. A `connection refused` against
# a healthy public host is harden-runner's block signature, not an outage.
#
# Three assertions per job:
#
#   1. Forward rules, keyed on `uses:` and on `run:` text:
#        github/codeql-action/init  -> release-assets.githubusercontent.com
#          (the bundle falls back to a release asset when the toolcache misses,
#           and a github.com release-download URL 302s there unconditionally)
#        aquasecurity/trivy-action  -> mirror.gcr.io AND ghcr.io
#          (ghcr.io is the documented DB fallback; without it a mirror.gcr.io
#           outage fails the scan instead of degrading)
#        a `releases/download` URL  -> release-assets.githubusercontent.com
#        anchore/sbom-action        -> raw.githubusercontent.com AND get.anchore.io
#          (the syft-install path reaches raw.githubusercontent.com
#           non-deterministically across arches; get.anchore.io serves the
#           install script)
#        a `gh release upload` run  -> uploads.github.com
#          (asset bytes POST to the uploads host, not the REST API host)
#        DeterminateSystems/flakehub-cache-action -> banned outright
#
#      GENERAL HAZARD this rule table only partially covers: a redirect to
#      ANY unlisted host is the defect class, not just the GitHub
#      release-asset case above. The same bug bit this repo twice more —
#      github.com/.../releases/download 302s to release-assets.githubusercontent.com
#      (covered above, exact and mechanical), and nixos.org/manual 302s to
#      nix.dev (NOT covered — nixos.org is a lychee link-check target host,
#      not a tool host this lint has a rule for). Extending this table to a
#      new redirecting host needs the same treatment: pin both the source
#      URL pattern and the host it lands on, not just the source.
#
#   2. Sigstore host-set consistency. Any job whose allowlist carries ANY
#      sigstore host, OR whose `run:` text invokes cosign, must carry a
#      COMPLETE set for what it does:
#        signing (`cosign sign` / `cosign sign-blob`):
#          fulcio + rekor + tuf-repo-cdn + timestamp, all required.
#          cosign 3.x requests an RFC3161 timestamp when producing a bundle.
#        verifying (`cosign verify` / `cosign verify-blob`) and not signing:
#          tuf-repo-cdn required. fulcio/rekor are NOT required — a
#          `.sigstore` bundle embeds the signing cert and tlog entry, so
#          verification only needs the TUF root refresh to validate the
#          bundle offline. `timestamp.sigstore.dev` MUST NOT be present:
#          the TSA is signing-only, and demanding it on a verify job would
#          force an unjustified host into the allowlist.
#        neither detected (the blind-spot case — cosign reached indirectly
#        via `scripts/*.sh` or `just`):
#          fulcio + rekor + tuf-repo-cdn required, as the conservative
#          floor. This is what catches a job that actually signs but whose
#          allowlist was never given any sigstore host at all — the real
#          `manifest` job bug, which shipped with a partial (zero-of-three)
#          sigstore set while its four signing siblings each carried three.
#
#   3. Reverse check: a denylist of hosts nothing in this repo justifies.
#      Junk entries defeat allowlist review.
#
# KNOWN BLIND SPOT: detection reads the workflow file only, one level deep. A
# job that reaches cosign through `scripts/*.sh` or `just` is invisible to the
# `run:`-text sign/verify rules. Assertion 2's "neither detected" branch
# covers that case regardless of detection, so an approximate call-graph
# resolver would buy false confidence, not coverage.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 clean, 1 on any drift, 2 if yq is missing.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_DIR=".github/workflows"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"

readonly FULCIO="fulcio.sigstore.dev"
readonly REKOR="rekor.sigstore.dev"
readonly TUF="tuf-repo-cdn.sigstore.dev"
readonly TIMESTAMP="timestamp.sigstore.dev"
readonly RELEASE_ASSETS="release-assets.githubusercontent.com"

# Hosts nothing in this repo justifies. Patterns are matched with `==` glob.
readonly -a DENYLIST=(
  'cafe.github.com'
  'magic-nix-cache*.amazonaws.com'
  'api.flakehub.com'
  'cache.flakehub.com'
  'flakehub.com'
  'install.determinate.systems'
)

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

failed=0

function fail() {
  printf '%s\n' "$1" >&2
  failed=$((failed + 1))
}

# Is host $2 present in the newline-separated endpoint list $1?
function has_host() {
  local -r endpoints="$1" host="$2"
  local e
  while IFS= read -r e; do
    [[ -z ${e} ]] && continue
    # Strip the :port suffix before comparing.
    if [[ ${e%%:*} == "${host}" ]]; then
      return 0
    fi
  done <<<"${endpoints}"
  return 1
}

shopt -s nullglob
for f in "${DIR}"/*.yml "${DIR}"/*.yaml; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  while IFS= read -r job; do
    [[ -z ${job} ]] && continue

    endpoints="$(yq eval "
      .jobs.\"${job}\".steps[]
      | select(.uses // \"\" | test(\"step-security/harden-runner@\"))
      | .with.\"allowed-endpoints\" // \"\"
    " "${f}" | tr ' ' '\n' | sed '/^$/d')"

    # A job with no harden-runner step has no allowlist to lint.
    [[ -z ${endpoints} ]] && continue

    uses="$(yq eval ".jobs.\"${job}\".steps[].uses // \"\"" "${f}")"
    runs="$(yq eval ".jobs.\"${job}\".steps[].run // \"\"" "${f}")"

    # --- Assertion 1: forward rules -------------------------------------

    if [[ ${uses} == *"DeterminateSystems/flakehub-cache-action"* ]]; then
      fail "${f}: job '${job}' uses flakehub-cache-action; the action is banned (flakehub hosts are not part of this repo's egress allowlist)"
    fi

    if [[ ${uses} == *"github/codeql-action/init"* ]]; then
      has_host "${endpoints}" "${RELEASE_ASSETS}" ||
        fail "${f}: job '${job}' uses codeql-action/init but does not allowlist ${RELEASE_ASSETS} (the bundle falls back to a release asset, which 302s there)"
    fi

    if [[ ${uses} == *"aquasecurity/trivy-action"* ]]; then
      has_host "${endpoints}" "mirror.gcr.io" ||
        fail "${f}: job '${job}' uses trivy-action but does not allowlist mirror.gcr.io"
      has_host "${endpoints}" "ghcr.io" ||
        fail "${f}: job '${job}' uses trivy-action but does not allowlist ghcr.io (the documented DB fallback; without it a mirror.gcr.io outage fails the scan instead of degrading)"
    fi

    if [[ ${runs} == *"releases/download"* ]]; then
      has_host "${endpoints}" "${RELEASE_ASSETS}" ||
        fail "${f}: job '${job}' downloads a GitHub release asset but does not allowlist ${RELEASE_ASSETS} (the github.com redirect is unconditional)"
    fi

    if [[ ${uses} == *"anchore/sbom-action"* ]]; then
      has_host "${endpoints}" "raw.githubusercontent.com" ||
        fail "${f}: job '${job}' uses anchore/sbom-action but does not allowlist raw.githubusercontent.com (the syft-install path reaches it, non-deterministically across arches, so the gap is latent)"
      has_host "${endpoints}" "get.anchore.io" ||
        fail "${f}: job '${job}' uses anchore/sbom-action but does not allowlist get.anchore.io (the syft install-script host)"
    fi

    if [[ ${runs} == *"gh release upload"* ]]; then
      has_host "${endpoints}" "uploads.github.com" ||
        fail "${f}: job '${job}' runs 'gh release upload' but does not allowlist uploads.github.com (asset bytes POST to the uploads host, not the REST API host)"
    fi

    # --- Assertion 2: sigstore host-set consistency ----------------------

    has_fulcio=0 has_rekor=0 has_tuf=0 has_ts=0
    has_host "${endpoints}" "${FULCIO}" && has_fulcio=1
    has_host "${endpoints}" "${REKOR}" && has_rekor=1
    has_host "${endpoints}" "${TUF}" && has_tuf=1
    has_host "${endpoints}" "${TIMESTAMP}" && has_ts=1
    sigstore_total=$((has_fulcio + has_rekor + has_tuf + has_ts))

    signs=0
    verifies=0
    # Word-bounded after the subcommand: "cosign signature" (prose, not an
    # invocation) must not match "cosign sign".
    [[ ${runs} =~ cosign([[:space:]]+--)?[[:space:]]+sign(-blob)?([[:space:]]|$) ]] && signs=1
    [[ ${runs} =~ cosign([[:space:]]+--)?[[:space:]]+verify(-blob)?([[:space:]]|$) ]] && verifies=1

    if ((sigstore_total > 0 || signs == 1 || verifies == 1)); then
      if ((signs == 1)); then
        # Signing needs all four.
        if ((has_fulcio == 0 || has_rekor == 0 || has_tuf == 0 || has_ts == 0)); then
          fail "${f}: job '${job}' runs 'cosign sign' with an incomplete sigstore host set; signing requires ${FULCIO}, ${REKOR}, ${TUF}, and ${TIMESTAMP} (cosign 3.x requests an RFC3161 timestamp when producing a bundle)"
        fi
      elif ((verifies == 1)); then
        # Verifying against a self-contained .sigstore bundle needs only the
        # TUF root refresh, and must NOT carry the signing-only TSA host.
        if ((has_tuf == 0)); then
          fail "${f}: job '${job}' runs 'cosign verify' with an incomplete sigstore host set; verification requires at least ${TUF}"
        fi
        if ((has_ts == 1)); then
          fail "${f}: job '${job}' runs 'cosign verify' but allowlists ${TIMESTAMP}; the TSA is signing-only — verification gets the TSA cert chain from the TUF root"
        fi
      else
        # No cosign detected, yet sigstore hosts are present. Either the job
        # reaches cosign indirectly (through a script) or the allowlist is
        # drifting. Demand at least the conservative signing-adjacent floor.
        if ((has_fulcio == 0 || has_rekor == 0 || has_tuf == 0)); then
          fail "${f}: job '${job}' has an incomplete sigstore host set (${sigstore_total} of the 3 required); a job carrying any sigstore host must carry ${FULCIO}, ${REKOR}, and ${TUF}"
        fi
      fi
    fi

    # --- Assertion 3: reverse check (denylist) ---------------------------

    while IFS= read -r e; do
      [[ -z ${e} ]] && continue
      host="${e%%:*}"
      for pattern in "${DENYLIST[@]}"; do
        # shellcheck disable=SC2053 # glob match on the denylist pattern is intended
        if [[ ${host} == ${pattern} ]]; then
          fail "${f}: job '${job}' allowlists ${host}, which no tool in this repo reaches"
        fi
      done
    done <<<"${endpoints}"

  done < <(yq eval '.jobs | keys | .[]' "${f}")
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d egress-allowlist violation(s)\n' "${failed}" >&2
  exit 1
fi
exit 0
