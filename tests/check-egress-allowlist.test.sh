#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-egress-allowlist.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/egress-allowlist"
readonly DECLARATION_FIXTURES="${REPO_ROOT}/tests/fixtures/egress-allowlist-declaration"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

expect good.yml 0 ""
expect bad-codeql-missing-release-assets.yml 1 "release-assets.githubusercontent.com"
expect bad-trivy-missing-ghcr-fallback.yml 1 "ghcr.io"
expect bad-trivy-missing-get-trivy.yml 1 "get.trivy.dev"
expect bad-release-asset-download.yml 1 "release-assets.githubusercontent.com"
expect bad-sign-missing-timestamp.yml 1 "timestamp.sigstore.dev"
expect bad-sigstore-partial-set.yml 1 "incomplete sigstore host set"
expect bad-verify-carries-timestamp.yml 1 "timestamp.sigstore.dev"
expect bad-denylisted-host.yml 1 "cafe.github.com"
expect bad-flakehub-action.yml 1 "flakehub-cache-action"
expect bad-sbom-missing-raw-githubusercontent.yml 1 "raw.githubusercontent.com"
expect bad-gh-release-upload-missing-uploads.yml 1 "uploads.github.com"
expect bad-verify-missing-tuf.yml 1 "verification requires at least tuf-repo-cdn.sigstore.dev"
expect bad-sbom-missing-get-anchore.yml 1 "get.anchore.io"
expect bad-scan-action-missing-get-anchore.yml 1 "get.anchore.io"
expect bad-scan-action-missing-grype-anchore.yml 1 "grype.anchore.io"
expect bad-scan-action-missing-raw-githubusercontent.yml 1 "raw.githubusercontent.com"
expect bad-ghcr-missing-pkg-containers.yml 1 "pkg-containers.githubusercontent.com"
expect bad-dockerhub-missing-auth.yml 1 "auth.docker.io"
expect bad-dockerhub-missing-registry.yml 1 "registry-1.docker.io"
expect bad-dockerhub-missing-cloudfront.yml 1 "production.cloudfront.docker.com"
expect bad-dockerhub-push-missing-index.yml 1 "index.docker.io"
expect bad-buildx-imagetools-create-missing-index.yml 1 "index.docker.io"
expect bad-dockerhub-description-missing-hub.yml 1 "hub.docker.com"
expect bad-scorecard-missing-scorecards-api.yml 1 "api.securityscorecards.dev"
expect bad-scorecard-missing-osv.yml 1 "api.osv.dev"
expect bad-scorecard-missing-deps-dev.yml 1 "api.deps.dev"
expect bad-attestation-verify-missing-tuf.yml 1 "tuf-repo.github.com"

# The mirror of assertion 7: a job that runs the setup-nix composite must carry
# both nix hosts. Proven per host rather than all-or-nothing — the second
# fixture carries cache.nixos.org and is still a violation, and its single
# violation count is what proves the rule did not blanket-demand both hosts
# from a job already carrying one.
expect bad-nix-setup-nix-missing-both-hosts.yml 1 "does not allowlist cache.nixos.org"
expect bad-nix-setup-nix-missing-both-hosts.yml 1 "does not allowlist releases.nixos.org"
expect bad-nix-setup-nix-missing-releases-host.yml 1 "does not allowlist releases.nixos.org"
expect bad-nix-setup-nix-missing-releases-host.yml 1 "1 egress-allowlist violation(s)"
# Boundary discipline for the same rule: a composite whose path merely starts
# with the setup-nix path is a different action, so it is not required to carry
# the nix hosts. A bare substring test would fail this fixture.
expect good-nix-lookalike-without-hosts.yml 0 ""

# A workflow yq cannot parse must fail loud, not empty the scan silently.
expect bad-malformed.yml 1 "could not evaluate"

# Every job carrying the notify composite is bound to the declared host set.
# The pure three-step shape must match it exactly; a job with extra steps may
# carry more, but never less.
expect good-notify-parity.yml 0 ""
expect bad-notify-missing-host.yml 1 "github.com:443"
expect bad-notify-extra-host.yml 1 "cache.nixos.org"
expect good-notify-sha-pinned.yml 0 ""
# The SHA-pinned self-reference has to be discovered, not merely tolerated: a
# clean run over the matching pinned job says nothing about whether the job
# was read at all, so the pinned form gets a violating job of its own.
expect bad-notify-sha-pinned-missing-host.yml 1 "github.com:443"
expect good-notify-extended.yml 0 ""
expect bad-notify-extended-missing.yml 1 "api.github.com:443"

# The parity rule is worth exactly as much as the declaration it reads, so a
# declaration that is unreadable or that names no host is a could-not-run:
# with an empty comparison set every notify job scores clean whatever its
# allowlist holds, and the run would report that as a checked tree. Exit 2,
# not 1 — nothing was evaluated, so this is not drift.
function expect_declaration() {
  local -r name="$1" declaration="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(NOTIFY_EGRESS_DECLARATION_OVERRIDE="${declaration}" \
    WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER=good-notify-parity.yml \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != 2 ]]; then
    printf 'FAIL %s: exit %s, want 2\n  stderr: %s\n' "${name}" "${got_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${name}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}

# Absent: the diagnostic has to name the file it could not read, otherwise an
# operator cannot tell which path the run resolved.
expect_declaration declaration-absent "${DECLARATION_FIXTURES}/absent.txt" "absent.txt"
# Present and readable, but comments and blanks only. A file that exists is
# not a declaration that declares anything, so the host count is what the
# guard keys on rather than the file's existence.
expect_declaration declaration-zero-hosts "${DECLARATION_FIXTURES}/comments-only.txt" "read 0 host(s)"

# Zero notify jobs on an unfiltered scan is a broken discovery predicate, not
# a clean tree: assert the breadth the rule claims to have checked. Exit 2,
# not 1 — this is the repo's "could not run" code, and check-guard-exit-code.sh
# enforces the split.
got_exit=0
got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${REPO_ROOT}/tests/fixtures/egress-allowlist-no-notify" \
  "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
if [[ ${got_exit} != 2 || ${got_stderr} != *"0 notify job"* ]]; then
  printf 'FAIL zero-notify-discovery: exit %s\n  stderr: %s\n' "${got_exit}" "${got_stderr}" >&2
  exit 1
fi
printf 'OK   zero-notify-discovery\n'

# ...and the documented override suppresses it.
LINT_ALLOW_EMPTY_SCAN=1 WORKFLOWS_DIR_OVERRIDE="${REPO_ROOT}/tests/fixtures/egress-allowlist-no-notify" \
  "${SCRIPT}" >/dev/null 2>&1 ||
  {
    printf 'FAIL zero-notify-discovery-override\n' >&2
    exit 1
  }
printf 'OK   zero-notify-discovery-override\n'

# Assertion 7: nix-host reachability. A job whose allowlist carries
# cache.nixos.org or releases.nixos.org must reach nix through the
# setup-nix composite, a run: block invoking a nix subcommand, or an
# in-job `# egress-nix-exempt: <reason>` marker; an empty-reason marker is
# rejected, and a marker on a job carrying neither host is reported as
# stale rather than silently tolerated.
expect good-nix-setup-nix.yml 0 ""
expect good-nix-run-invocation.yml 0 ""
expect bad-nix-neither.yml 1 "reaches no nix tooling"
# A same-prefixed but different composite (`setup-nix-cache-thing`) must not
# satisfy the setup-nix arm: the arm matches the composite path itself, not
# any path that merely starts with it.
expect bad-nix-setup-nix-lookalike.yml 1 "reaches no nix tooling"
expect good-nix-exempt.yml 0 ""
expect bad-nix-exempt-empty-reason.yml 1 "no reason"
expect bad-nix-stale-marker.yml 1 "stale"

# Breadth: zero jobs carrying either nix host on an unfiltered scan is a
# broken discovery predicate, not a clean tree — same convention, and same
# could-not-run exit code, as the zero-notify-discovery guard above. The
# fixture workflow carries a notify job (so assertion 6's breadth passes)
# but no nix host at all, isolating assertion 7's own guard.
got_exit=0
got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${REPO_ROOT}/tests/fixtures/egress-allowlist-no-nix-host" \
  "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
if [[ ${got_exit} != 2 || ${got_stderr} != *"0 job(s) carrying cache.nixos.org/releases.nixos.org"* ]]; then
  printf 'FAIL zero-nix-host-discovery: exit %s\n  stderr: %s\n' "${got_exit}" "${got_stderr}" >&2
  exit 1
fi
printf 'OK   zero-nix-host-discovery\n'

# ...and the documented override suppresses it.
LINT_ALLOW_EMPTY_SCAN=1 WORKFLOWS_DIR_OVERRIDE="${REPO_ROOT}/tests/fixtures/egress-allowlist-no-nix-host" \
  "${SCRIPT}" >/dev/null 2>&1 ||
  {
    printf 'FAIL zero-nix-host-discovery-override\n' >&2
    exit 1
  }
printf 'OK   zero-nix-host-discovery-override\n'

# LIVE: the real tree must satisfy assertion 7, and the run must have
# actually scanned something. The assertion checks the printed count is
# nonzero rather than pinning it to today's exact job count, which would
# turn every unrelated job addition into a spurious fixture failure — the
# same convention tests/check-payload-source-helper.test.sh uses for its
# own live-tree breadth assertion. A regression that narrows the
# discovery predicate without flipping any fixture above is exactly what
# this count catches instead.
live_out=""
live_exit=0
live_out="$(WORKFLOWS_DIR_OVERRIDE="${REPO_ROOT}/.github/workflows" "${SCRIPT}" 2>&1)" || live_exit=$?
if [[ ${live_exit} != 0 ]]; then
  printf 'FAIL live-nix-host-tree: expected exit 0, got %s\n  output: %s\n' "${live_exit}" "${live_out}" >&2
  exit 1
fi
live_count="$(grep -oE '[0-9]+ nix-host job\(s\) checked' <<<"${live_out}" | grep -oE '^[0-9]+' || true)"
if [[ -z ${live_count} || ${live_count} -eq 0 ]]; then
  printf 'FAIL live-nix-host-tree: 0 nix-host jobs checked\n  output: %s\n' "${live_out}" >&2
  exit 1
fi
printf 'OK   live-nix-host-tree (%s job(s) checked)\n' "${live_count}"

printf 'all tests passed\n'
