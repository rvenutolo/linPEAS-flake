#!/usr/bin/env bash
# scripts/check-dockerhub-token-scope-split.sh
#
# @description Lint: enforce the DOCKERHUB_TOKEN RW/DELETE scope split.
# The delete-scoped PAT (secrets.DOCKERHUB_TOKEN_DELETE) is consumed only
# by dockerhub-sync.yml (peter-evans/dockerhub-description needs Delete
# scope to PATCH repo metadata; a Read/Write-only PAT returns 403). The
# write-scoped PAT (secrets.DOCKERHUB_TOKEN_RW) is consumed only by
# release-on-bump.yml — never by the anonymous/read-only
# verify-latest-release.yml. The delete-capable token must never leak into
# workflows that only push images, and no unsuffixed secrets.DOCKERHUB_TOKEN
# may exist — only _RW and _DELETE are authoritative.
#
# Honors WORKFLOWS_DIR_OVERRIDE (defaults to .github/workflows) so the test
# harness can point at a temp dir, and LINT_ALLOW_EMPTY_SCAN=1 to accept a
# workflows dir holding no YAML. Exits 0 if the split holds, 1 on a
# violation, 2 when the workflows dir is not there to read, holds no
# workflow to read, or holds one that could not be read.
set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-.github/workflows}"

if [[ ! -d ${WORKFLOWS_DIR} ]]; then
  printf 'dockerhub-token-scope-split lint: workflows dir %s missing\n' \
    "${WORKFLOWS_DIR}" >&2
  exit 2
fi

readonly RELEASE_WF="${WORKFLOWS_DIR}/release-on-bump.yml"
readonly VERIFY_WF="${WORKFLOWS_DIR}/verify-latest-release.yml"
readonly SYNC_WF="${WORKFLOWS_DIR}/dockerhub-sync.yml"

failed=0

# @description Record a violation and bump the failure counter.
# @arg $1 message
function violation() {
  printf '%s\n' "$1" >&2
  failed=$((failed + 1))
}

# @description Return 0 if the file consumes secrets.<name>, else 1.
# A missing file returns 1 (treated as "does not consume").
# @arg $1 workflow file path
# @arg $2 bare secret name (e.g. DOCKERHUB_TOKEN_RW)
function consumes_secret() {
  local -r file="$1" name="$2"
  [[ -f ${file} ]] || return 1
  grep --extended-regexp --quiet \
    "secrets\.${name}([^A-Za-z0-9_]|\$)" "${file}"
}

# Absence: delete-scoped token must not leak into release/verify workflows.
for wf in "${RELEASE_WF}" "${VERIFY_WF}"; do
  if consumes_secret "${wf}" 'DOCKERHUB_TOKEN_DELETE'; then
    violation "${wf}: consumes secrets.DOCKERHUB_TOKEN_DELETE (delete-scoped token must not leak into push/verify workflows)"
  fi
done

# Absence: write-scoped token must not appear in the sync workflow.
if consumes_secret "${SYNC_WF}" 'DOCKERHUB_TOKEN_RW'; then
  violation "${SYNC_WF}: consumes secrets.DOCKERHUB_TOKEN_RW (sync must use the delete-scoped token)"
fi

# Absence: write-scoped token must not leak into the read-only verify
# workflow. verify-latest-release.yml runs its Docker Hub attestation checks
# anonymously/read-only by design, so dropping DOCKERHUB_TOKEN_RW means a
# compromised step there cannot exfiltrate the push credential. The RW token
# is release-only.
if consumes_secret "${VERIFY_WF}" 'DOCKERHUB_TOKEN_RW'; then
  violation "${VERIFY_WF}: consumes secrets.DOCKERHUB_TOKEN_RW (verify is read-only; the write-scoped token is release-only)"
fi

# Suffix: every secrets.DOCKERHUB_TOKEN* reference must be _RW or _DELETE.
# A workflows dir that exists but holds no YAML leaves this whole check with
# nothing to read, and the run then exits 0 having asserted nothing about
# any suffix. That is a could-not-run, not a clean split.
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' "${WORKFLOWS_DIR}/*.yml" "${WORKFLOWS_DIR}/*.yaml"
for wf in "${workflow_files[@]}"; do
  # grep separates "this workflow names no DOCKERHUB_TOKEN" (1) from "this
  # workflow could not be read" (2). Only the first is a finding about
  # content; scoring the second the same way clears an unreadable workflow
  # of every suffix violation it carries.
  matches_rc=0
  matches="$(grep --extended-regexp --only-matching -- \
    'secrets\.DOCKERHUB_TOKEN[A-Za-z0-9_]*' "${wf}")" || matches_rc=$?
  if ((matches_rc > 1)); then
    printf 'dockerhub-token-scope-split lint: grep failed reading %s\n' \
      "${wf}" >&2
    exit 2
  fi
  [[ -z ${matches} ]] && continue
  matches="$(sort --unique <<<"${matches}")"
  while IFS= read -r match; do
    [[ -z ${match} ]] && continue
    if [[ ${match} != 'secrets.DOCKERHUB_TOKEN_RW' &&
      ${match} != 'secrets.DOCKERHUB_TOKEN_DELETE' ]]; then
      violation "${wf}: ${match} is not authoritative (only _RW and _DELETE variants are allowed)"
    fi
  done <<<"${matches}"
done

# Positive: producers must exist and consume their scoped token (guards the
# absence checks from passing trivially when a producer is deleted/renamed).
if ! consumes_secret "${RELEASE_WF}" 'DOCKERHUB_TOKEN_RW'; then
  violation "${RELEASE_WF}: must consume secrets.DOCKERHUB_TOKEN_RW (missing file or scope-split producer removed)"
fi
if ! consumes_secret "${SYNC_WF}" 'DOCKERHUB_TOKEN_DELETE'; then
  violation "${SYNC_WF}: must consume secrets.DOCKERHUB_TOKEN_DELETE (missing file or scope-split producer removed)"
fi

if ((failed > 0)); then
  printf '%d violation(s) found\n' "${failed}" >&2
  exit 1
fi
exit 0
