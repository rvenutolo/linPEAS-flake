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
# The same split binds the manual recovery snippets in the docs. A
# shell-fenced Markdown block that performs a tag delete
# (`--request DELETE` / `-X DELETE`) against Docker Hub must name
# DOCKERHUB_TOKEN_DELETE and must not name DOCKERHUB_TOKEN_RW: the
# write-scoped PAT returns 401 on a tag delete, so a snippet pasting it
# hands the operator a failure that reads like a credential problem.
# A fence counts as a Docker Hub delete when it does a DELETE and either
# addresses hub.docker.com or names a DOCKERHUB_TOKEN — a DELETE against
# some other API is not this rule's business, and scoping on the host
# alone would exempt a snippet that spells the host through a variable.
# Token names are matched over the whole fence, not the delete line: a
# real snippet assigns its credential many lines above the request.
#
# Honors WORKFLOWS_DIR_OVERRIDE (defaults to .github/workflows) so the test
# harness can point at a temp dir, PATHS_OVERRIDE (newline-separated file
# list) for the Markdown scan set, and LINT_ALLOW_EMPTY_SCAN=1 to accept a
# workflows dir holding no YAML or an empty Markdown scan set. Exits 0 if
# the split holds, 1 on a violation, 2 when the workflows dir is not there
# to read, holds no workflow to read, holds one that could not be read, or
# the Markdown scan set could not be enumerated.
set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"

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

# Markdown: a shell-fenced Docker Hub tag delete must carry the
# delete-scoped token. Fence-scoped rather than line-scoped, and reported
# at the fence's opening line so the operator lands on the whole snippet.
declare -a md_paths=()
if [[ -n ${PATHS_OVERRIDE:-} ]]; then
  while IFS= read -r md_path; do
    [[ -z ${md_path} ]] && continue
    md_paths+=("${md_path}")
  done <<<"${PATHS_OVERRIDE}"
else
  # tests/ is excluded because its fixture trees exist to be violations:
  # a fixture asserting this very rule fires would fail the real run.
  enumerate_into md_paths 'git ls-files' git ls-files -z -- \
    '*.md' ':(exclude)tests/**'
fi

# enumerate_into makes this assertion for the git branch; PATHS_OVERRIDE
# bypasses it, and a fixture list that resolves to nothing would otherwise
# clear the whole Markdown rule while the run still exits 0.
if ((${#md_paths[@]} == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
  printf 'dockerhub-token-scope-split lint: markdown scan set is empty; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate\n' >&2
  exit 2
fi

# @description Emit one tab-delimited record per line for $1: `V` records
#              carry a fence start line and the reason it offends, and a
#              single trailing `C` record carries the fence tallies. The
#              tallies are what make a clean verdict auditable — "no
#              violation" over zero shell fences is not the same result as
#              "no violation" over a Docker Hub delete that was checked.
# @arg $1 markdown file path
function scan_fences() {
  local -r file="$1"
  awk '
    function verdict() {
      fences++
      if (!eligible) { return }
      shell_fences++
      if (!delete_seen) { return }
      if (!hub_seen && !token_seen) { return }
      hub_deletes++
      if (rw_seen) {
        printf "V\t%d\tnames DOCKERHUB_TOKEN_RW\n", start
      } else if (!delete_token_seen) {
        printf "V\t%d\tnames no DOCKERHUB_TOKEN_DELETE\n", start
      }
    }
    /^[[:space:]]*```/ {
      if (in_fence) {
        verdict()
        in_fence = 0
        eligible = 0
      } else {
        lang = $0
        sub(/^[[:space:]]*```/, "", lang)
        sub(/[[:space:]].*$/, "", lang)
        eligible = (lang == "" || lang == "sh" || lang == "bash" \
          || lang == "shell" || lang == "console" || lang == "text")
        in_fence = 1
        start = NR
        delete_seen = 0
        delete_token_seen = 0
        rw_seen = 0
        token_seen = 0
        hub_seen = 0
      }
      next
    }
    !in_fence || !eligible { next }
    {
      if ($0 ~ /(--request[[:space:]=]+DELETE|-X[[:space:]]*DELETE)/) { delete_seen = 1 }
      if (index($0, "hub.docker.com")) { hub_seen = 1 }
      if (index($0, "DOCKERHUB_TOKEN_DELETE")) { delete_token_seen = 1 }
      if (index($0, "DOCKERHUB_TOKEN_RW")) { rw_seen = 1 }
      if ($0 ~ /DOCKERHUB_TOKEN/) { token_seen = 1 }
    }
    END {
      if (in_fence) { verdict() }
      printf "C\t%d\t%d\t%d\n", fences, shell_fences, hub_deletes
    }
  ' "$(awk_path "${file}")"
}

md_scanned=0
md_fences=0
md_shell_fences=0
md_hub_deletes=0
for md_path in ${md_paths[@]+"${md_paths[@]}"}; do
  # An unreadable doc is a tooling fault, not a compliant one: scoring it
  # as "no offending fence" clears every snippet it carries.
  if ! fence_out="$(scan_fences "${md_path}")"; then
    printf 'dockerhub-token-scope-split lint: awk failed reading %s\n' \
      "${md_path}" >&2
    exit 2
  fi
  md_scanned=$((md_scanned + 1))
  while IFS=$'\t' read -r kind a b c; do
    case "${kind}" in
    V)
      violation "${md_path}:${a}: shell fence deletes a Docker Hub tag but ${b}; a tag delete needs DOCKERHUB_TOKEN_DELETE (the _RW token returns 401)"
      ;;
    C)
      md_fences=$((md_fences + a))
      md_shell_fences=$((md_shell_fences + b))
      md_hub_deletes=$((md_hub_deletes + c))
      ;;
    esac
  done <<<"${fence_out}"
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
printf 'check-dockerhub-token-scope-split: ok — %d workflow(s), %d markdown file(s), %d fence(s) (%d shell-shaped, %d Docker Hub tag delete(s))\n' \
  "${#workflow_files[@]}" "${md_scanned}" "${md_fences}" "${md_shell_fences}" \
  "${md_hub_deletes}"
