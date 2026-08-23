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
# Seven assertions per job:
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
#        ./.github/actions/setup-nix -> cache.nixos.org AND releases.nixos.org
#          (the composite downloads the installer from releases.nixos.org, and
#           every nix command it enables substitutes from cache.nixos.org, so
#           a job running it without both hosts either fails to install nix or
#           rebuilds every derivation from source. This is the mirror of
#           assertion 7: that one binds a PRESENT host to a tool that must be
#           REACHABLE by it, this one binds a PRESENT tool to the hosts it must
#           be able to reach. Both arms match the composite path itself and not
#           a prefix of it, so `setup-nix-cache-thing` is a different action to
#           both — hence the single shared matcher rather than two)
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
#   7. Nix-host reachability. Every assertion above binds a host to a tool
#      it must be PRESENT for; this is the first binding a host to a tool
#      it must be REACHABLE by. Any job whose `allowed-endpoints` carries
#      `cache.nixos.org` or `releases.nixos.org` must satisfy one of:
#        - a step `uses:` the `./.github/actions/setup-nix` composite
#          (the only nix-installing path anywhere in this tree), or
#        - a `run:` block invoking a `nix` subcommand (`nix build`,
#          `nix develop`, `nix shell`, `nix flake`, and siblings —
#          matched only when `nix` is followed by whitespace and a known
#          subcommand, so `nixpkgs-fmt`, `nixos.org`, and a `nix` path
#          segment inside a URL such as
#          `releases.nixos.org/nix/nix-2.34.7/install` do not count), or
#        - an in-job `# egress-nix-exempt: <reason>` comment with a
#          non-empty reason.
#      An empty-reason marker is rejected outright, and a marker on a job
#      whose allowlist carries neither host is reported as stale — the
#      rule it would exempt does not apply to that job.
#
#      Detection deliberately does NOT follow callees: a job reaching nix
#      indirectly through a `scripts/*.sh` invocation or a `just` recipe
#      is invisible to both the `uses:` and `run:` arms and needs the
#      marker instead, so the reason a reviewer reads is what carries the
#      justification, not an approximate call-graph resolver that would
#      buy false confidence rather than coverage.
#
#      The marker is a YAML comment, gone once yq has parsed the
#      document, so it is found by a raw-text scan bounded to the job's
#      own line range (from its key's line, taken from yq's `line`
#      builtin, to one line before the next job's key line, or to the
#      end of the file for the last job) rather than by any yq query.
#
#      Breadth is asserted the same way as assertion 6: the run reports
#      how many jobs carry either host, and finding none on an
#      unfiltered scan is a could-not-run, not a clean tree.
#      `WORKFLOW_FILE_FILTER` and `LINT_ALLOW_EMPTY_SCAN=1` suppress that
#      guard the same way they do for assertion 6.
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
# THE SAME COMMENT BLIND SPOT applies to assertion 7's `run:` arm: the
# `invokes_nix` regex matches a nix subcommand anywhere in a job's
# concatenated `run:` text, including inside a shell comment, so a job
# whose only nix token is `# we do not nix build here anymore` is credited
# with reaching nix tooling even though it never runs `nix`. As with
# assertion 3, this is not parsed out: a `run:` block is shell text, and
# reliably stripping comments from it needs a shell parser this lint does
# not carry. The documented limitation is the honest treatment.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures,
# LINT_ALLOW_EMPTY_SCAN for a deliberately empty scan root, and
# NOTIFY_EGRESS_DECLARATION_OVERRIDE for an alternate notify egress
# declaration. That last one is what makes the declaration guard testable:
# the default declaration path resolves from this script's own location, so
# without it no fixture can present a tree whose declaration is absent or
# names no host, and assertion 6's could-not-run branch is reachable only by
# hand.
# Exits 0 clean, 1 on any drift, 2 if yq is missing, if the declaration
# file is missing or empty, or if an unfiltered scan discovers no notify
# job or no cache.nixos.org/releases.nixos.org-carrying job at all.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

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

# The sole nix-installing path in this tree, the recognized `nix` subcommands
# a `run:` block can invoke, and the escape-hatch marker. The composite path is
# read by both directions of the nix rule: assertion 1 requires the two nix
# hosts wherever it runs, assertion 7 accepts it as the tool a carried nix host
# is reachable by.
readonly NIX_SETUP_COMPOSITE='./.github/actions/setup-nix'
readonly NIX_SUBCOMMANDS='build|develop|shell|run|flake|profile|eval|copy|store|search|registry|repl|show-config'
readonly NIX_EXEMPT_MARKER='egress-nix-exempt:'

# Resolved against this script's own location rather than the scan root:
# the fixture harness repoints the scan root at tests/fixtures, and the
# declaration a fixture run must be measured against is always the real one
# beside the composite it describes.
SCRIPT_DIR="${_lib_dir}"
readonly SCRIPT_DIR
readonly DECLARATION="${NOTIFY_EGRESS_DECLARATION_OVERRIDE:-${SCRIPT_DIR}/../${DECLARATION_REL}}"

# Diagnostics naming the declaration use the path this run actually resolved.
# Printing the repo-relative constant under the override would point an
# operator at a file the run never opened.
readonly DECLARATION_LABEL="${NOTIFY_EGRESS_DECLARATION_OVERRIDE:-${DECLARATION_REL}}"

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
    "${0##*/}" "${DECLARATION_LABEL}" >&2
  exit 2
fi
readonly DECLARED

failed=0
notify_jobs=0
nix_host_jobs=0

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
declare -a selected_files=()
filter_into selected_files 'workflow YAML' "${FILE_FILTER}" "${workflow_files[@]}"
for f in "${selected_files[@]}"; do
  [[ -f ${f} ]] || continue

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

  # Assertion 7 prep: each job's own line range, for the marker raw-text
  # scan below. A `# egress-nix-exempt:` marker is a YAML comment, gone
  # once yq has parsed the document, so it can only be found by reading
  # the file's own text — bounded to one job's lines, so a marker sitting
  # in a sibling job's block is never credited to this one. `line` (a yq
  # builtin) reports a job key's own 1-indexed source line; a job's range
  # runs from there to one line before the next job key's line, or to the
  # end of the file for the last job in document order.
  declare -A JOB_START=()
  declare -A JOB_END=()
  declare -a job_order=()
  if ! job_line_rows="$(yq eval '.jobs | keys | .[] | [., line] | join("\t")' "${f}")"; then
    fail "${f}: could not evaluate job line numbers with yq (malformed?)"
    continue
  fi
  while IFS=$'\t' read -r jline_name jline_num; do
    [[ -z ${jline_name} ]] && continue
    JOB_START["${jline_name}"]="${jline_num}"
    job_order+=("${jline_name}")
  done <<<"${job_line_rows}"
  file_lines="$(wc -l <"${f}")"
  for jidx in "${!job_order[@]}"; do
    jline_name="${job_order[${jidx}]}"
    if ((jidx + 1 < ${#job_order[@]})); then
      JOB_END["${jline_name}"]=$((JOB_START["${job_order[$((jidx + 1))]}"] - 1))
    else
      JOB_END["${jline_name}"]="${file_lines}"
    fi
  done

  while IFS= read -r job; do
    [[ -z ${job} ]] && continue

    # Every endpoint finding below is derived from this list. A yq that
    # dies on the step walk has read no allowlist at all, and its exit 1
    # would surface as an allowlist found wanting.
    if ! endpoints="$(yq eval "
      .jobs.\"${job}\".steps[]
      | select(.uses // \"\" | test(\"step-security/harden-runner@\"))
      | .with.\"allowed-endpoints\" // \"\"
    " "${f}" | tr ' ' '\n' | sed '/^$/d')"; then
      printf '%s: cannot read allowed-endpoints for job %q\n' "${f}" "${job}" >&2
      exit 2
    fi

    # A job with no harden-runner step has no allowlist to lint.
    [[ -z ${endpoints} ]] && continue

    if ! uses="$(yq eval ".jobs.\"${job}\".steps[].uses // \"\"" "${f}")"; then
      printf '%s: cannot read the step uses: list for job %q\n' "${f}" "${job}" >&2
      exit 2
    fi
    if ! runs="$(yq eval ".jobs.\"${job}\".steps[].run // \"\"" "${f}")"; then
      printf '%s: cannot read the step run: list for job %q\n' "${f}" "${job}" >&2
      exit 2
    fi

    # Path-bounded setup-nix detection, shared by assertion 1's forward rule
    # and assertion 7's reachability arm so the two directions of the nix rule
    # can never disagree about what counts as the composite. It is the
    # composite path itself that matches, never a `uses:` value that merely
    # starts with it — `./.github/actions/setup-nix-cache-thing` is a different
    # composite, installs no nix, and satisfies neither direction.
    has_setup_nix=0
    while IFS= read -r u; do
      if [[ ${u} == "${NIX_SETUP_COMPOSITE}" || ${u} == "${NIX_SETUP_COMPOSITE}@"* ]]; then
        has_setup_nix=1
      fi
    done <<<"${uses}"

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

    # Checked per host rather than as a set, so a job carrying one nix host and
    # not the other is still reported for the one it is missing.
    if ((has_setup_nix == 1)); then
      for h in 'releases.nixos.org' 'cache.nixos.org'; do
        has_host "${endpoints}" "${h}" ||
          fail "${f}: job '${job}' uses ${NIX_SETUP_COMPOSITE} but does not allowlist ${h} (the composite downloads the installer from releases.nixos.org, and every nix command it enables substitutes from cache.nixos.org)"
      done
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
          fail "${f}: job '${job}' runs the ${NOTIFY_COMPOSITE} composite but does not allowlist ${h}, which ${DECLARATION_LABEL} declares every such job reaches"
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
            fail "${f}: job '${job}' runs the ${NOTIFY_COMPOSITE} composite and nothing else, yet allowlists ${e%%:*}, which ${DECLARATION_LABEL} does not declare; no step in that shape reaches it"
          fi
        done <<<"${endpoints}"
      fi
    fi

    # --- Assertion 7: nix-host reachability -------------------------------

    marker_present=0
    marker_reason=""
    job_start="${JOB_START[${job}]:-0}"
    job_end="${JOB_END[${job}]:-0}"
    if ((job_start > 0)); then
      # `|| true`: grep exits 1 on no match, which `set -e` would
      # otherwise treat as this pipeline's own failure.
      marker_line="$(sed -n "${job_start},${job_end}p" "${f}" |
        grep -m1 -E "^[[:space:]]*#[[:space:]]*${NIX_EXEMPT_MARKER}" || true)"
      if [[ -n ${marker_line} ]]; then
        marker_present=1
        marker_reason="${marker_line#*"${NIX_EXEMPT_MARKER}"}"
        # Trim surrounding whitespace so a reason of only spaces reads as
        # empty, the same as no reason at all.
        marker_reason="${marker_reason#"${marker_reason%%[![:space:]]*}"}"
        marker_reason="${marker_reason%"${marker_reason##*[![:space:]]}"}"
      fi
    fi

    if has_host "${endpoints}" "cache.nixos.org" || has_host "${endpoints}" "releases.nixos.org"; then
      nix_host_jobs=$((nix_host_jobs + 1))

      # `nix` must be followed by whitespace and a recognized subcommand,
      # with a non-identifier (or start-of-string) character before it:
      # `nixpkgs-fmt`, `nixos.org`, and the `nix` path segment inside
      # `releases.nixos.org/nix/nix-2.34.7/install` all fail this, since
      # none has whitespace directly after the bare word `nix`. This is a
      # textual match over the job's concatenated `run:` text, so a nix
      # subcommand written inside a shell comment (e.g. `# we do not nix
      # build here anymore`) still matches — the same shell-comment blind
      # spot assertion 3's Docker Hub push-branch check has, documented
      # above rather than parsed around.
      invokes_nix=0
      [[ ${runs} =~ (^|[^a-zA-Z0-9_./-])nix[[:space:]]+(${NIX_SUBCOMMANDS})([[:space:]]|$) ]] && invokes_nix=1

      if ((has_setup_nix == 0 && invokes_nix == 0)); then
        if ((marker_present == 1)); then
          if [[ -z ${marker_reason} ]]; then
            fail "${f}: job '${job}' carries a '${NIX_EXEMPT_MARKER}' marker with no reason (allowlists cache.nixos.org/releases.nixos.org, reaches nix through neither ${NIX_SETUP_COMPOSITE} nor a run: nix invocation)"
          fi
        else
          fail "${f}: job '${job}' allowlists cache.nixos.org/releases.nixos.org but reaches no nix tooling — neither ${NIX_SETUP_COMPOSITE} nor a run: nix invocation is detected, and no '# ${NIX_EXEMPT_MARKER} <reason>' marker justifies it"
        fi
      fi
    else
      if ((marker_present == 1)); then
        fail "${f}: job '${job}' carries a stale '${NIX_EXEMPT_MARKER}' marker; its allowlist carries neither cache.nixos.org nor releases.nixos.org, so this rule does not apply to it"
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

# Same convention as the notify breadth guard above: a discovery
# predicate matching nothing reports the same clean exit a genuinely
# nix-free tree does, so the breadth assertion 7 claims to have checked
# is asserted instead of inferred from the absence of a violation.
if ((nix_host_jobs == 0)) && [[ -z ${FILE_FILTER} && -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
  printf '%s: found 0 job(s) carrying cache.nixos.org/releases.nixos.org under %s — a predicate matching nothing reports the same ok line a clean tree does; set LINT_ALLOW_EMPTY_SCAN=1 if this root deliberately carries neither host\n' \
    "${0##*/}" "${DIR}" >&2
  exit 2
fi

printf '%d notify job(s) checked against the declared egress allowlist\n' "${notify_jobs}"
printf '%d nix-host job(s) checked for reachability\n' "${nix_host_jobs}"
exit 0
