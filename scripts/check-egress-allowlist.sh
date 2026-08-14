#!/usr/bin/env bash
# scripts/check-egress-allowlist.sh
#
# @description Lint: every job's harden-runner `allowed-endpoints` list
# carries the hosts its tool inventory actually reaches, carries the ghcr
# blob host alongside ghcr.io, carries a complete Docker Hub pull host set
# (and the push host too, if it logs in or pushes) if it carries any Docker
# Hub registry host at all, carries a complete sigstore host set if it
# carries any sigstore host at all, matches the declared notify egress set
# if the job runs the notify-workflow-result composite, and carries no
# denylisted host.

# Binds each job's `allowed-endpoints` list to what the job's tooling actually
# reaches. Hand-authored allowlists rot silently: a tool version bumps, a URL
# changes, or a fallback path activates, and the list is not updated. The
# resulting failure is latent — it surfaces only when the blocked path is
# finally exercised, which can be months later. A `connection refused` against
# a healthy public host is harden-runner's block signature, not an outage.
#
# Six assertions per job:
#
#   1. Forward rules, keyed on `uses:` and on `run:` text:
#        github/codeql-action/init  -> release-assets.githubusercontent.com
#          (the bundle falls back to a release asset when the toolcache misses,
#           and a github.com release-download URL 302s there unconditionally)
#        aquasecurity/trivy-action  -> get.trivy.dev AND mirror.gcr.io AND ghcr.io
#          (get.trivy.dev serves the binary — the release tag resolves against
#           github.com but the bytes do not; ghcr.io is the documented DB
#           fallback, so without it a mirror.gcr.io outage fails the scan
#           instead of degrading)
#        a `releases/download` URL  -> release-assets.githubusercontent.com
#        anchore/sbom-action        -> raw.githubusercontent.com AND get.anchore.io
#          (the syft-install path reaches raw.githubusercontent.com
#           non-deterministically across arches; get.anchore.io serves the
#           install script)
#        anchore/scan-action        -> get.anchore.io AND grype.anchore.io AND
#                                      raw.githubusercontent.com
#          (get.anchore.io serves the grype install script,
#           raw.githubusercontent.com is reached by the same install path
#           non-deterministically across arches, and grype itself fetches its
#           vulnerability DB from grype.anchore.io)
#        peter-evans/dockerhub-description -> hub.docker.com
#          (the action authenticates against and PATCHes the Docker Hub web
#           API to publish the repository README; it never talks to a
#           registry host)
#        a `gh release upload` run  -> uploads.github.com
#          (asset bytes POST to the uploads host, not the REST API host)
#        the scorecard CLI (`nix develop --command scorecard` or
#        `scorecard --repo`, either substring)  -> api.securityscorecards.dev
#                                                   AND api.osv.dev AND
#                                                   api.deps.dev
#          (scorecard queries its own API plus the OSV and deps.dev datasets
#           while evaluating checks; an invocation shaped differently than
#           either keyed substring is not detected)
#        a `gh attestation verify` run -> tuf-repo.github.com
#          (verification refreshes GitHub's TUF root before checking the
#           bundle)
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
#   2. ghcr blob-host consistency. Any job whose allowlist carries ghcr.io
#      at all must also carry pkg-containers.githubusercontent.com,
#      whatever tool put ghcr.io there: ghcr.io serves manifests, but layer
#      blobs come from the pkg-containers host, so a pull, push, or a
#      Trivy vulnerability-DB fallback stalls on the first blob without it.
#
#   3. Docker Hub host-set consistency. Any job whose allowlist carries ANY
#      Docker Hub registry host must carry the full pull floor:
#      auth.docker.io + registry-1.docker.io + production.cloudfront.docker.com
#      (the token service, the registry API, and the layer CDN — pulling a
#      single image needs all three together). A job that additionally logs
#      in or pushes (`docker login`/`docker push` or `buildx imagetools
#      create`) must also carry index.docker.io, the write-path host.
#      `hub.docker.com` is never required by this assertion — it is the
#      Docker Hub web API, not a registry host, and it doubles as a lychee
#      link-check target in links.yml. Assertion 1 requires it directly
#      wherever peter-evans/dockerhub-description appears, since that
#      action's writes land on the web API rather than the registry.
#
#   4. Sigstore host-set consistency. Any job whose allowlist carries ANY
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
#   5. Reverse check: a denylist of hosts nothing in this repo justifies.
#      Junk entries defeat allowlist review.
#
#   6. Notify-composite parity. Every job that runs the
#      notify-workflow-result composite is bound to the host set declared
#      in `.github/actions/notify-workflow-result/egress-allowlist.txt`,
#      which is the single source of truth — the list lives beside the
#      composite whose network behavior it describes, so adding an API
#      call to a new host edits the declaration and the composite in one
#      place. `#` comments and blank lines in it are ignored.
#
#      Discovery is by property, not by name: a subject is any job with a
#      step whose `uses:` names notify-workflow-result, which covers the
#      `./.github/actions/...` form, the SHA-pinned self-reference (used
#      where a `pull_request` event must not run a PR branch's copy of the
#      composite), and the next notify job nobody has written yet. No
#      job-name list and no workflow-path list means a new notify job is
#      governed on the day it is written rather than on the day someone
#      remembers to widen a lint.
#
#      Two branches, keyed on whether the job does anything beyond
#      notifying:
#        pure shape (the job's `uses:` set is exactly harden-runner,
#          actions/checkout and the composite): the allowlist must EQUAL
#          the declared set. A host the shape cannot reach is dropped
#          rather than tolerated, since an unreachable host in a
#          copy-pasted list is how the list stops describing the job.
#        extended shape (any other step, including a bare `run:`): the
#          allowlist must be a SUPERSET of the declared set. A future
#          notify job that computes its body is not forced to edit this
#          lint to land, and the extra hosts it carries are still
#          governed by assertions 1-5.
#
#      Breadth is asserted rather than inferred: the run reports how many
#      notify jobs it discovered, and finding none on an unfiltered scan
#      is a broken discovery predicate reported as a could-not-run, not a
#      clean tree. `WORKFLOW_FILE_FILTER` suppresses that guard because
#      the fixture harness scans one file at a time and almost every
#      fixture legitimately holds no notify job;
#      `LINT_ALLOW_EMPTY_SCAN=1` suppresses it for a deliberately empty
#      scan root.
#
# KNOWN BLIND SPOT: detection reads the workflow file only, one level deep. A
# job that reaches cosign through `scripts/*.sh` or `just` is invisible to the
# `run:`-text sign/verify rules. Assertion 4's "neither detected" branch
# covers that case regardless of detection, so an approximate call-graph
# resolver would buy false confidence, not coverage.
#
# TWO MORE LIMITATIONS in the same detection family, both in assertion 3's
# Docker Hub push-branch check: it matches `docker push` / `docker login`
# anywhere in a job's concatenated `run:` text, including inside a shell
# comment, so a job that merely mentions those words in a comment would be
# required to carry index.docker.io, the write-path host, even though it
# never reaches it. The same check is also blind to a push performed by
# tooling shaped differently — `skopeo copy`, `crane push`, `regctl`, or a
# wrapped script — which would silently under-guard the write path.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures, and
# LINT_ALLOW_EMPTY_SCAN for a deliberately empty scan root.
# Exits 0 clean, 1 on any drift, 2 if yq is missing, if the declaration
# file is missing or empty, or if an unfiltered scan discovers no notify
# job at all.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"

readonly DEFAULT_DIR=".github/workflows"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"

readonly FULCIO="fulcio.sigstore.dev"
readonly REKOR="rekor.sigstore.dev"
readonly TUF="tuf-repo-cdn.sigstore.dev"
readonly TIMESTAMP="timestamp.sigstore.dev"
readonly RELEASE_ASSETS="release-assets.githubusercontent.com"

# Docker Hub pull path: token service, registry API, and layer CDN. All three
# are required to pull a single image. `hub.docker.com` is deliberately absent
# from this set — it is the web API and a lychee link-check target, not a
# registry host. It is instead required directly by assertion 1 wherever
# peter-evans/dockerhub-description appears.
readonly -a DOCKERHUB_PULL=(
  'auth.docker.io'
  'production.cloudfront.docker.com'
  'registry-1.docker.io'
)
readonly DOCKERHUB_PUSH='index.docker.io'

# Hosts nothing in this repo justifies. Patterns are matched with `==` glob.
readonly -a DENYLIST=(
  'cafe.github.com'
  'magic-nix-cache*.amazonaws.com'
  'api.flakehub.com'
  'cache.flakehub.com'
  'flakehub.com'
  'install.determinate.systems'
)

readonly NOTIFY_COMPOSITE='notify-workflow-result'
readonly DECLARATION_REL=".github/actions/${NOTIFY_COMPOSITE}/egress-allowlist.txt"

# Resolved against this script's own location rather than the scan root:
# the fixture harness repoints the scan root at tests/fixtures, and the
# declaration a fixture run must be measured against is always the real one
# beside the composite it describes.
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
readonly SCRIPT_DIR
readonly DECLARATION="${SCRIPT_DIR}/../${DECLARATION_REL}"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

declare -a DECLARED=()
if [[ -r ${DECLARATION} ]]; then
  # `|| [[ -n ... ]]` keeps a final line with no trailing newline, which
  # read reports as a failure even after populating the variable.
  while IFS= read -r decl_line || [[ -n ${decl_line} ]]; do
    decl_line="${decl_line%%#*}"
    decl_line="${decl_line//[[:space:]]/}"
    [[ -n ${decl_line} ]] || continue
    DECLARED+=("${decl_line}")
  done <"${DECLARATION}"
fi
if ((${#DECLARED[@]} == 0)); then
  printf '%s: read 0 host(s) from %s — the notify egress parity rule has nothing to compare against, so a job carrying any list at all would score clean\n' \
    "${0##*/}" "${DECLARATION_REL}" >&2
  exit 2
fi
readonly DECLARED

failed=0
notify_jobs=0

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
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' "${DIR}/*.yml" "${DIR}/*.yaml"
for f in "${workflow_files[@]}"; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  # Capture yq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(yq ...)`: a process substitution's exit
  # status is not propagated under set -Eeuo pipefail, so a yq failure
  # (unparsable workflow, or a query that errors on a valid-but-odd
  # shape) would yield empty input and the check would pass silently.
  if ! job_rows="$(yq eval '.jobs | keys | .[]' "${f}")"; then
    fail "${f}: could not evaluate workflow with yq (malformed?)"
    continue
  fi
  [[ -n ${job_rows} ]] || continue
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
      has_host "${endpoints}" "get.trivy.dev" ||
        fail "${f}: job '${job}' uses trivy-action but does not allowlist get.trivy.dev (the action resolves the release tag against github.com but downloads the binary from get.trivy.dev; without it Trivy never installs and every later step is skipped)"
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

    if [[ ${uses} == *"anchore/scan-action"* ]]; then
      has_host "${endpoints}" "get.anchore.io" ||
        fail "${f}: job '${job}' uses anchore/scan-action but does not allowlist get.anchore.io (the grype install-script host)"
      has_host "${endpoints}" "grype.anchore.io" ||
        fail "${f}: job '${job}' uses anchore/scan-action but does not allowlist grype.anchore.io (grype fetches its vulnerability DB there; without it the scan cannot run)"
      has_host "${endpoints}" "raw.githubusercontent.com" ||
        fail "${f}: job '${job}' uses anchore/scan-action but does not allowlist raw.githubusercontent.com (the grype-install path reaches it, non-deterministically across arches, so the gap is latent)"
    fi

    if [[ ${uses} == *"peter-evans/dockerhub-description"* ]]; then
      has_host "${endpoints}" "hub.docker.com" ||
        fail "${f}: job '${job}' uses peter-evans/dockerhub-description but does not allowlist hub.docker.com (the action authenticates against and PATCHes the Docker Hub web API to publish the repository README; it never reaches a registry host)"
    fi

    if [[ ${runs} == *"gh release upload"* ]]; then
      has_host "${endpoints}" "uploads.github.com" ||
        fail "${f}: job '${job}' runs 'gh release upload' but does not allowlist uploads.github.com (asset bytes POST to the uploads host, not the REST API host)"
    fi

    if [[ ${runs} == *"command scorecard"* || ${runs} == *"scorecard --repo"* ]]; then
      for h in 'api.securityscorecards.dev' 'api.deps.dev' 'api.osv.dev'; do
        has_host "${endpoints}" "${h}" ||
          fail "${f}: job '${job}' runs the scorecard CLI but does not allowlist ${h} (scorecard queries its own API plus the OSV and deps.dev datasets while evaluating checks)"
      done
    fi

    if [[ ${runs} == *"gh attestation verify"* ]]; then
      has_host "${endpoints}" "tuf-repo.github.com" ||
        fail "${f}: job '${job}' runs 'gh attestation verify' but does not allowlist tuf-repo.github.com (verification refreshes GitHub's TUF root before checking the bundle)"
    fi

    # --- Assertion 2: ghcr blob-host consistency -------------------------

    if has_host "${endpoints}" "ghcr.io"; then
      has_host "${endpoints}" "pkg-containers.githubusercontent.com" ||
        fail "${f}: job '${job}' allowlists ghcr.io but not pkg-containers.githubusercontent.com (ghcr.io serves manifests; layer blobs come from the pkg-containers host, so a pull or push stalls on the first blob)"
    fi

    # --- Assertion 3: Docker Hub host-set consistency --------------------

    dockerhub_any=0
    for h in "${DOCKERHUB_PULL[@]}" "${DOCKERHUB_PUSH}"; do
      if has_host "${endpoints}" "${h}"; then
        dockerhub_any=1
      fi
    done

    if ((dockerhub_any == 1)); then
      for h in "${DOCKERHUB_PULL[@]}"; do
        has_host "${endpoints}" "${h}" ||
          fail "${f}: job '${job}' carries a Docker Hub registry host but not ${h} (pulling one image needs the token service, the registry API, and the layer CDN together)"
      done
      if [[ ${runs} =~ docker[[:space:]]+(login|push) ]] ||
        [[ ${runs} == *"buildx imagetools create"* ]]; then
        has_host "${endpoints}" "${DOCKERHUB_PUSH}" ||
          fail "${f}: job '${job}' logs in or pushes to Docker Hub but does not allowlist ${DOCKERHUB_PUSH} (the write path authenticates against the index host, not the pull registry host)"
      fi
    fi

    # --- Assertion 4: sigstore host-set consistency ----------------------

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

    # --- Assertion 5: reverse check (denylist) ---------------------------

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

    # --- Assertion 6: notify-composite egress parity ---------------------

    if [[ ${uses} == *"${NOTIFY_COMPOSITE}"* ]]; then
      notify_jobs=$((notify_jobs + 1))

      # A step carrying no `uses:` — a `run:` step — arrives from yq as an
      # empty line, so it falls through to the default arm and widens the
      # job to the extended shape. That is the intent: a job doing work
      # beyond notifying may reach hosts this declaration does not name.
      pure_shape=1
      while IFS= read -r u; do
        case "${u}" in
        *"step-security/harden-runner@"*) ;;
        *"actions/checkout@"*) ;;
        *"${NOTIFY_COMPOSITE}"*) ;;
        *) pure_shape=0 ;;
        esac
      done <<<"${uses}"

      for h in "${DECLARED[@]}"; do
        has_host "${endpoints}" "${h%%:*}" ||
          fail "${f}: job '${job}' runs the ${NOTIFY_COMPOSITE} composite but does not allowlist ${h}, which ${DECLARATION_REL} declares every such job reaches"
      done

      if ((pure_shape == 1)); then
        while IFS= read -r e; do
          [[ -z ${e} ]] && continue
          declared_host=0
          for h in "${DECLARED[@]}"; do
            if [[ ${e%%:*} == "${h%%:*}" ]]; then
              declared_host=1
            fi
          done
          if ((declared_host == 0)); then
            fail "${f}: job '${job}' runs the ${NOTIFY_COMPOSITE} composite and nothing else, yet allowlists ${e%%:*}, which ${DECLARATION_REL} does not declare; no step in that shape reaches it"
          fi
        done <<<"${endpoints}"
      fi
    fi

  done <<<"${job_rows}"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d egress-allowlist violation(s)\n' "${failed}" >&2
  exit 1
fi

# A discovery predicate that matches nothing reports the same clean exit a
# tree with no drift does, so the breadth the notify rule claims to have
# checked is asserted instead. The file filter is the one legitimate way to
# reach zero: the fixture harness scans one workflow at a time and almost
# every fixture holds no notify job at all.
if ((notify_jobs == 0)) && [[ -z ${FILE_FILTER} && -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
  printf '%s: found 0 notify job(s) under %s — a predicate matching nothing reports the same ok line a clean tree does; set LINT_ALLOW_EMPTY_SCAN=1 if this root deliberately runs no notify composite\n' \
    "${0##*/}" "${DIR}" >&2
  exit 2
fi

printf '%d notify job(s) checked against the declared egress allowlist\n' "${notify_jobs}"
exit 0
