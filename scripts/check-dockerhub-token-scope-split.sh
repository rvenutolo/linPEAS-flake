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
# harness can point at a temp dir. Exits 0 if the split holds, 1 otherwise.
set -Eeuo pipefail
IFS=$'\n\t'

readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-.github/workflows}"

if [[ ! -d ${WORKFLOWS_DIR} ]]; then
  printf 'dockerhub-token-scope-split lint: workflows dir %s missing\n' \
    "${WORKFLOWS_DIR}" >&2
  exit 1
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
shopt -s nullglob
for wf in "${WORKFLOWS_DIR}"/*.yml; do
  while IFS= read -r match; do
    [[ -z ${match} ]] && continue
    if [[ ${match} != 'secrets.DOCKERHUB_TOKEN_RW' &&
      ${match} != 'secrets.DOCKERHUB_TOKEN_DELETE' ]]; then
      violation "${wf}: ${match} is not authoritative (only _RW and _DELETE variants are allowed)"
    fi
  done < <(grep --extended-regexp --only-matching \
    'secrets\.DOCKERHUB_TOKEN[A-Za-z0-9_]*' "${wf}" | sort --unique)
done
shopt -u nullglob

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
