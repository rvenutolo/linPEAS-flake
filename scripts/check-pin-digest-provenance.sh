#!/usr/bin/env bash
# scripts/check-pin-digest-provenance.sh
#
# @description Lint: a pin digest may not move under an unchanged
# version label. Diffs action pins (`uses: <path>@<sha> # <version>`)
# in workflows/composite actions and the octoscan container digest
# pair against the base ref; a changed SHA/digest whose version
# comment did not change is a repointed released tag (the
# digest-repoint supply-chain class) and fails. Floating-major pins
# (`# vN`) legitimately retarget across patch releases, so instead of
# a hard fail their new commit must be reachable from the upstream
# default branch — a force-pushed dangling commit fails.

# Gates the Renovate auto-merge path: a digest-only bump PR is by
# construction a repointed released tag. minimumReleaseAge does not
# delay it (the version's release timestamp is unchanged), and the
# daily ratchet-pin-audit calls a tag-matching pin "current", so this
# PR-time diff check is the only automated gate on that path.
#
# Reachability probe (floating-major only): the new SHA is
# dereferenced if it is an annotated-tag object, then compared against
# the upstream default branch; `identical`/`behind` passes,
# `ahead`/`diverged` fails. Any API failure exits 2 (loud) — never a
# silent pass. The probe runs only when a floating-major digest
# actually changed, so routine runs make no API calls.
#
# Exit: 0 pass, 1 violation, 2 operational error.
#
# Env overrides (test-only):
#   BASE_REF          — git ref for base content (default: origin/main)
#   BASE_DIR_OVERRIDE — read base files from this dir instead of git show
#   HEAD_DIR_OVERRIDE — read head files from this dir (default: .)

set -Eeuo pipefail
IFS=$'\n\t'

readonly BASE_REF="${BASE_REF:-origin/main}"
readonly BASE_DIR="${BASE_DIR_OVERRIDE:-}"
readonly HEAD_DIR="${HEAD_DIR_OVERRIDE:-.}"
readonly OCTOSCAN_FILE="scripts/octoscan-scan.sh"
readonly OCTOSCAN_IMAGE="ghcr.io/synacktiv/octoscan"
readonly GH_API_VERSION_HEADER="X-GitHub-Api-Version: 2022-11-28"

function die_op() {
  printf 'pin-digest-provenance: %s\n' "$1" >&2
  exit 2
}

# Emit the head-side scanned file list (paths relative to HEAD_DIR).
function head_files() {
  local f
  shopt -s nullglob
  for f in \
    "${HEAD_DIR}"/.github/workflows/*.yml \
    "${HEAD_DIR}"/.github/workflows/*.yaml \
    "${HEAD_DIR}"/.github/actions/*/action.yml \
    "${HEAD_DIR}"/.github/actions/*/action.yaml; do
    printf '%s\n' "${f#"${HEAD_DIR}"/}"
  done
  shopt -u nullglob
  if [[ -f "${HEAD_DIR}/${OCTOSCAN_FILE}" ]]; then
    printf '%s\n' "${OCTOSCAN_FILE}"
  fi
}

# Print base content of a file; empty output when absent in base.
# @arg $1 file path relative to repo root
function base_content() {
  local -r file="$1"
  if [[ -n ${BASE_DIR} ]]; then
    [[ -f "${BASE_DIR}/${file}" ]] || return 0
    cat -- "${BASE_DIR}/${file}"
  else
    git show "${BASE_REF}:${file}" 2>/dev/null || true
  fi
}

# Emit `file|path|version|sha` tuples for one file's content on stdin.
# @arg $1 file path label
function extract_pins() {
  local -r file="$1"
  local line
  if [[ ${file} == "${OCTOSCAN_FILE}" ]]; then
    local digest="" ver=""
    while IFS= read -r line; do
      if [[ ${line} =~ ^OCTOSCAN_DIGEST=\"(sha256:[a-f0-9]{64})\" ]]; then
        digest="${BASH_REMATCH[1]}"
      elif [[ ${line} =~ ^OCTOSCAN_VERSION=\"(v[0-9][A-Za-z0-9.]*)\" ]]; then
        ver="${BASH_REMATCH[1]}"
      fi
    done
    if [[ -n ${digest} && -n ${ver} ]]; then
      printf '%s|%s|%s|%s\n' "${file}" "${OCTOSCAN_IMAGE}" "${ver}" "${digest}"
    fi
    return 0
  fi
  local path sha version
  while IFS= read -r line; do
    if [[ ${line} =~ uses:[[:space:]]+([A-Za-z0-9._/-]+)@([0-9a-f]{40})[[:space:]]*#[[:space:]]*([^[:space:]]+) ]]; then
      path="${BASH_REMATCH[1]}"
      sha="${BASH_REMATCH[2]}"
      version="${BASH_REMATCH[3]}"
      # Local composite actions have no upstream to repoint.
      [[ ${path} == .* ]] && continue
      printf '%s|%s|%s|%s\n' "${file}" "${path}" "${version}" "${sha}"
    fi
  done
  return 0
}

# Floating-major reachability probe.
# @arg $1 uses path   @arg $2 new sha
# Returns 0 reachable, 1 not reachable; dies (exit 2) on API error.
function check_reachable() {
  local -r path="$1" sha="$2"
  command -v gh >/dev/null 2>&1 ||
    die_op 'gh not found on PATH (needed for floating-major reachability probe)'
  local -a parts
  IFS=/ read -ra parts <<<"${path}"
  local -r owner_repo="${parts[0]}/${parts[1]}"
  local commit="${sha}" tag_out
  # Annotated-tag-object pins dereference to their commit; a 404 means
  # the SHA is not a tag object, i.e. already a commit.
  if tag_out="$(gh api --header "${GH_API_VERSION_HEADER}" \
    "repos/${owner_repo}/git/tags/${sha}" --jq '.object.sha' 2>&1)"; then
    [[ ${tag_out} =~ ^[0-9a-f]{40}$ ]] ||
      die_op "malformed tag deref payload for ${owner_repo}@${sha}: ${tag_out}"
    commit="${tag_out}"
  elif ! grep --quiet --ignore-case 'Not Found' <<<"${tag_out}"; then
    die_op "tag deref API error for ${owner_repo}@${sha}: ${tag_out}"
  fi
  local default_branch
  default_branch="$(gh api --header "${GH_API_VERSION_HEADER}" \
    "repos/${owner_repo}" --jq '.default_branch' 2>&1)" ||
    die_op "default-branch lookup failed for ${owner_repo}: ${default_branch}"
  [[ -n ${default_branch} && ${default_branch} != null ]] ||
    die_op "empty default branch for ${owner_repo}"
  local status
  status="$(gh api --header "${GH_API_VERSION_HEADER}" \
    "repos/${owner_repo}/compare/${default_branch}...${commit}" --jq '.status' 2>&1)" ||
    die_op "compare API failed for ${owner_repo} ${default_branch}...${commit}: ${status}"
  case "${status}" in
  identical | behind)
    printf 'note: floating-major pin %s@%s verified reachable from %s (%s)\n' \
      "${path}" "${sha}" "${default_branch}" "${status}" >&2
    return 0
    ;;
  ahead | diverged)
    return 1
    ;;
  *)
    die_op "unexpected compare status '${status}' for ${owner_repo}"
    ;;
  esac
}

if [[ -z ${BASE_DIR} ]]; then
  git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null ||
    die_op "cannot resolve ${BASE_REF} (is origin/main fetched?)"
fi

base_tuples=""
head_tuples=""
while IFS= read -r file; do
  head_tuples+="$(extract_pins "${file}" <"${HEAD_DIR}/${file}")"$'\n'
  base_tuples+="$(extract_pins "${file}" <<<"$(base_content "${file}")")"$'\n'
done < <(head_files)

# The octoscan pair is a load-bearing extraction target: if the file
# exists in head but the pair is not found, the var block was reshaped
# and this gate would silently stop covering it. Fail loud instead.
if [[ -f "${HEAD_DIR}/${OCTOSCAN_FILE}" ]] &&
  ! grep --quiet "^${OCTOSCAN_FILE}|" <<<"${head_tuples}"; then
  die_op "octoscan digest/version pair not found in ${OCTOSCAN_FILE} (extraction shape drift?)"
fi

keys="$(printf '%s\n%s\n' "${base_tuples}" "${head_tuples}" |
  awk -F'|' 'NF == 4 { print $1 "|" $2 "|" $3 }' | sort -u)"

violations=0
while IFS= read -r key; do
  [[ -n ${key} ]] || continue
  base_shas="$(awk -F'|' -v k="${key}" \
    '($1 "|" $2 "|" $3) == k { print $4 }' <<<"${base_tuples}" | sort -u)"
  head_shas="$(awk -F'|' -v k="${key}" \
    '($1 "|" $2 "|" $3) == k { print $4 }' <<<"${head_tuples}" | sort -u)"
  # Key only on one side = pin (or version) added/removed — not a
  # repoint. New versions ride minimumReleaseAge + the daily audit.
  [[ -n ${base_shas} && -n ${head_shas} ]] || continue
  [[ ${base_shas} == "${head_shas}" ]] && continue
  file="${key%%|*}"
  rest="${key#*|}"
  path="${rest%%|*}"
  version="${rest#*|}"
  if [[ ${version} =~ ^v[0-9]+$ ]]; then
    while IFS= read -r sha; do
      [[ -n ${sha} ]] || continue
      grep --quiet --line-regexp --fixed-strings "${sha}" <<<"${base_shas}" && continue
      if ! check_reachable "${path}" "${sha}"; then
        printf 'FAIL: floating-major digest %s@%s (%s) in %s not reachable from upstream default branch\n' \
          "${path}" "${sha}" "${version}" "${file}" >&2
        violations=1
      fi
    done <<<"${head_shas}"
  else
    printf 'FAIL: digest repointed under unchanged version: %s (%s) in %s\n' \
      "${path}" "${version}" "${file}" >&2
    violations=1
  fi
done <<<"${keys}"

if ((violations != 0)); then
  printf 'pin digest provenance check FAILED — a digest moved under an unchanged version label.\n' >&2
  printf 'A repointed released tag is the digest-repoint supply-chain class. Review upstream before unblocking.\n' >&2
  exit 1
fi

printf 'pin digest provenance OK\n'
