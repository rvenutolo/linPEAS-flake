#!/usr/bin/env bash
# scripts/refresh-trufflehog-image.sh
#
# @description Write .github/trufflehog-image, the TruffleHog container
# image ref `trufflehog.yml` hands the trufflesecurity/trufflehog action,
# from the release in that action's `# vX.Y.Z` pin comment and the digest
# ghcr.io serves for that release's tag.
# @generates .github/trufflehog-image
# @option --check exit 1 if the file is missing or would change; exit 2 if
# the workflow is missing or unparsable, if it does not pin the action at
# exactly one release, or if ghcr.io cannot be reached or answers without
# one well-formed digest

# The action runs `docker run "${IMAGE}:${VERSION}"`, so the file holds
# `X.Y.Z@sha256:<digest>`: the tag keeps the release readable, and the
# digest makes the reference immutable. ghcr tags carry no `v`. The digest
# is the `Docker-Content-Digest` ghcr.io answers for the tag's manifest,
# asked for as a multi-arch index first, so it is the digest
# `docker pull` resolves the tag to on any runner. The request is
# anonymous: the image is public, and ghcr.io issues a pull token scoped
# to it without credentials.
#
# Renovate cannot keep this file in step itself (ghcr.io publishes no
# release timestamps, so its release-age gate never clears the image), so
# renovate-flake-lock-refresh.yml runs this on every Renovate PR that
# changes trufflehog.yml and commits the result.
# scripts/check-trufflehog-image-pin.sh keeps a PR whose file names
# another release red.
#
# Usage:
#
#     scripts/refresh-trufflehog-image.sh           # rewrite the file
#     scripts/refresh-trufflehog-image.sh --check   # exit 1 if it is stale
#
# Env overrides (for tests):
#
#     TRUFFLEHOG_WORKFLOW_OVERRIDE    path to trufflehog.yml
#     TRUFFLEHOG_IMAGE_FILE_OVERRIDE  path to the image file
#
# Exits 0 when the file names the pinned release's digest, in the
# rewrite mode after writing it; 1 under --check when the file is missing
# or differs; 2 when it could not run: an unknown argument, a missing
# tool, the workflow missing or unparsable, no single pinned release in
# it, or a registry request that failed or answered without one
# well-formed digest.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/ascii-match.sh
source "${_lib_dir}/lib/ascii-match.sh"
# shellcheck source=scripts/lib/repo.sh
source "${_lib_dir}/lib/repo.sh"
# shellcheck source=scripts/lib/job-keys.sh
source "${_lib_dir}/lib/job-keys.sh"

readonly IMAGE_REPO='trufflesecurity/trufflehog'
readonly REGISTRY='https://ghcr.io'
# An index or manifest list first, so a multi-arch tag resolves to the
# digest docker pulls it by, then a single-platform manifest.
readonly ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
readonly COMMENT_RE='^v([0-9]+\.[0-9]+\.[0-9]+)$'
readonly DIGEST_RE='^sha256:[0-9a-f]{64}$'
# One array per step map carrying `uses:`: the alias-resolved reference and
# the reference's line comment.
readonly STEPS_QUERY='.. | select(kind == "map") | select(has("uses")) | [(.uses | explode(.)), (.uses | line_comment)]'

# @description Print the one release the workflow pins the action at.
# Exits 2 when it pins none, more than one, or a step lacks the comment.
# @arg $1 workflow path
function pinned_release() {
  local -r workflow="$1"
  local action_re steps record ref comment
  action_re="^$(ascii_fold_regex "${IMAGE_REPO}")@"
  if ! steps="$(yq "${YQ_MERGE_SPEC[@]}" -o=json -I=0 "${STEPS_QUERY}" "${workflow}")"; then
    log_err "could not parse ${workflow}"
    exit 2
  fi
  local -A releases=()
  while IFS= read -r record; do
    [[ -n ${record} ]] || continue
    ref="$(jq --raw-output '.[0] | tostring' <<<"${record}")"
    ascii_match "${ref}" "${action_re}" || continue
    comment="$(jq --raw-output '.[1] | tostring' <<<"${record}")"
    if ! ascii_match "${comment}" "${COMMENT_RE}"; then
      log_err "${workflow} has a ${IMAGE_REPO} step with no # vX.Y.Z pin comment"
      exit 2
    fi
    releases["${comment#v}"]=1
  done <<<"${steps}"
  if ((${#releases[@]} == 0)); then
    log_err "${workflow} names no ${IMAGE_REPO} step"
    exit 2
  fi
  if ((${#releases[@]} > 1)); then
    local sorted
    sorted="$(printf '%s\n' "${!releases[@]}" | sort | tr '\n' ' ')"
    log_err "${workflow} pins ${IMAGE_REPO} at more than one release: ${sorted% }"
    exit 2
  fi
  printf '%s\n' "${!releases[@]}"
}

# @description Print the digest ghcr.io serves for a tag of the image.
# Exits 2 on a failed request or an answer without one well-formed digest.
# @arg $1 tag
function resolve_digest() {
  local -r tag="$1"
  local token_json token headers line name value
  local -a digests=()
  if ! token_json="$(curl --silent --show-error --fail --proto '=https' \
    --max-time 30 --retry 2 \
    "${REGISTRY}/token?scope=repository:${IMAGE_REPO}:pull&service=ghcr.io")"; then
    log_err 'could not get a pull token from ghcr.io'
    exit 2
  fi
  if ! token="$(jq --raw-output --exit-status '.token | strings' <<<"${token_json}" 2>/dev/null)" ||
    [[ -z ${token} ]]; then
    log_err 'ghcr.io answered the token request without a token'
    exit 2
  fi
  if ! headers="$(curl --silent --show-error --fail --proto '=https' \
    --max-time 30 --retry 2 --head \
    --header "Authorization: Bearer ${token}" \
    --header "Accept: ${ACCEPT}" \
    "${REGISTRY}/v2/${IMAGE_REPO}/manifests/${tag}")"; then
    log_err "could not read the manifest of ${IMAGE_REPO}:${tag} from ghcr.io"
    exit 2
  fi
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ ${line} == *:* ]] || continue
    name="${line%%:*}"
    [[ ${name,,} == 'docker-content-digest' ]] || continue
    value="${line#*:}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    digests+=("${value}")
  done <<<"${headers}"
  if ((${#digests[@]} != 1)); then
    log_err "ghcr.io named ${#digests[@]} Docker-Content-Digest header(s) for ${tag}; want one"
    exit 2
  fi
  if ! ascii_match "${digests[0]}" "${DIGEST_RE}"; then
    log_err "ghcr.io answered digest $(printf '%q' "${digests[0]}") for ${tag}; want sha256:<64 hex>"
    exit 2
  fi
  printf '%s\n' "${digests[0]}"
}

function main() {
  local check_only='false'
  if [[ ${1:-} == '--check' ]]; then
    check_only='true'
  elif [[ $# -gt 0 ]]; then
    log_err "unknown arg: ${1}"
    exit 2
  fi
  readonly check_only

  # Byte-wise case folding and bracket ranges for every test below.
  export LC_ALL=C

  require_tool yq
  require_tool jq
  require_tool curl

  local repo_root workflow image_file
  repo_root="$(repo_toplevel)"
  workflow="${TRUFFLEHOG_WORKFLOW_OVERRIDE:-${repo_root}/.github/workflows/trufflehog.yml}"
  image_file="${TRUFFLEHOG_IMAGE_FILE_OVERRIDE:-${repo_root}/.github/trufflehog-image}"
  readonly repo_root workflow image_file

  if [[ ! -f ${workflow} ]]; then
    log_err "${workflow} not found"
    exit 2
  fi

  local release digest ref
  # Each helper has reported its own cause; its exit is always 2.
  release="$(pinned_release "${workflow}")" || exit 2
  digest="$(resolve_digest "${release}")" || exit 2
  ref="${release}@${digest}"
  readonly release digest ref

  local current='' present='false'
  if [[ -f ${image_file} ]]; then
    present='true'
    # `read -d ''` keeps every byte up to EOF and reports EOF as status 1.
    IFS= read -r -d '' current <"${image_file}" || true
  fi

  if [[ ${current} == "${ref}"$'\n' ]]; then
    log_info "${image_file} is current: ${ref}"
    return 0
  fi

  if [[ ${check_only} == 'true' ]]; then
    if [[ ${present} == 'false' ]]; then
      log_err "${image_file} is missing; it should hold ${ref}. Run scripts/refresh-trufflehog-image.sh and commit."
    else
      log_err "${image_file} is stale: it holds $(printf '%q' "${current%$'\n'}"); it should hold ${ref}. Run scripts/refresh-trufflehog-image.sh and commit."
    fi
    exit 1
  fi

  printf '%s\n' "${ref}" >"${image_file}"
  log_info "wrote ${ref} to ${image_file}"
}

main "$@"
