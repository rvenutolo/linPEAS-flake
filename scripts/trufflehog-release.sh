#!/usr/bin/env bash
# scripts/trufflehog-release.sh
#
# @description Verify and run the TruffleHog release binary pinned in
# .github/trufflehog-version. `verify` downloads the release's checksums
# file with its keyless cosign signature and certificate, checks the
# signature against the TruffleHog release workflow's identity for that
# tag, and prints the linux/amd64 tarball's pinned digest. `scan` downloads
# that tarball, checks it against a digest `verify` printed, extracts the
# `trufflehog` binary and runs a secret scan over the checked-out
# repository, over the commit range the triggering event implies.
#
# Splitting the two lets the job that holds the signature tooling hand the
# job that runs the scan nothing but a version and a digest.
#
# Usage:
#   trufflehog-release.sh verify
#   trufflehog-release.sh scan --version <X.Y.Z> --sha256 <64 hex>
#
# Environment (scan): GITHUB_EVENT_NAME and GITHUB_EVENT_PATH select the
# range exactly as the trufflesecurity/trufflehog action does.
# @option verify print `version=<X.Y.Z>` and `sha256=<hex>` on stdout
# @option scan scan the repository at the current work tree's root
#
# Test seams: TRUFFLEHOG_VERSION_FILE_OVERRIDE replaces the version file
# path; TRUFFLEHOG_RELEASE_BASE_URL_OVERRIDE replaces the release download
# prefix.
#
# Exits 0 when the signature verified (verify) or the scan found nothing
# (scan), 1 when verification failed (a cosign failure, a checksums file
# without exactly one tarball line or with a malformed digest, a digest
# mismatch, a tarball without a regular-file `trufflehog`), 2 when the
# script could not run (a missing tool, a missing or malformed version
# file, a malformed argument, an unsupported event, a download failure).
# In `scan`, a non-zero exit from the trufflehog binary itself (a finding,
# or its own error) is passed through unchanged, so 1 or 2 can also come
# from the binary.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
# shellcheck source=scripts/lib/repo.sh
source "${_lib_dir}/lib/repo.sh"

readonly DEFAULT_VERSION_FILE='.github/trufflehog-version'
readonly VERSION_FILE="${TRUFFLEHOG_VERSION_FILE_OVERRIDE:-${DEFAULT_VERSION_FILE}}"
readonly DEFAULT_BASE_URL='https://github.com/trufflesecurity/trufflehog/releases/download'
readonly BASE_URL="${TRUFFLEHOG_RELEASE_BASE_URL_OVERRIDE:-${DEFAULT_BASE_URL}}"
# Only the test seam may leave https: it points at a file:// fixture tree.
# The shipped base URL is always fetched over https alone.
if [[ -n ${TRUFFLEHOG_RELEASE_BASE_URL_OVERRIDE:-} ]]; then
  readonly CURL_PROTO='=file,https'
else
  readonly CURL_PROTO='=https'
fi
readonly CERT_ISSUER='https://token.actions.githubusercontent.com'
readonly NULL_SHA='0000000000000000000000000000000000000000'

tmp_dir=''

function cleanup() {
  if [[ -n ${tmp_dir} ]]; then
    rm --recursive --force -- "${tmp_dir}"
  fi
}

function usage() {
  printf 'usage: %s verify | scan --version <X.Y.Z> --sha256 <64 hex>\n' "${0##*/}" >&2
  exit 2
}

# @description Print the pinned version. The file must hold exactly one
# `X.Y.Z` line with its final newline and no NUL byte.
# @stdout the version
# @exitcode 2 the file is missing or malformed
function read_version() {
  local ref=''
  if [[ ! -f ${VERSION_FILE} ]]; then
    log_err "${VERSION_FILE} is missing"
    exit 2
  fi
  # Status 0 means `read` stopped at a NUL: more bytes follow.
  if IFS= read -r -d '' ref <"${VERSION_FILE}"; then
    log_err "${VERSION_FILE} holds a NUL byte"
    exit 2
  fi
  if [[ ! ${ref} =~ ^[0123456789]+\.[0123456789]+\.[0123456789]+$'\n'$ ]]; then
    log_err "${VERSION_FILE} is not one X.Y.Z line"
    exit 2
  fi
  printf '%s\n' "${ref%$'\n'}"
}

# @description Download one release asset.
# @arg $1 version  @arg $2 asset name  @arg $3 destination path
# @exitcode 2 the download failed
function fetch_asset() {
  local -r version="$1"
  local -r asset="$2"
  local -r dest="$3"
  if ! curl --disable --fail --silent --show-error --location --proto "${CURL_PROTO}" --tlsv1.2 \
    --output "${dest}" "${BASE_URL}/v${version}/${asset}"; then
    log_err "cannot download ${asset} for v${version}"
    exit 2
  fi
}

function verify() {
  local version
  version="$(read_version)"
  require_tool curl
  require_tool cosign
  require_tool mktemp
  tmp_dir="$(make_temp --directory)"
  local -r checksums="${tmp_dir}/trufflehog_${version}_checksums.txt"
  local -r tarball="trufflehog_${version}_linux_amd64.tar.gz"
  fetch_asset "${version}" "trufflehog_${version}_checksums.txt" "${checksums}"
  fetch_asset "${version}" "trufflehog_${version}_checksums.txt.sig" "${checksums}.sig"
  fetch_asset "${version}" "trufflehog_${version}_checksums.txt.pem" "${checksums}.pem"

  local -r identity="https://github.com/trufflesecurity/trufflehog/.github/workflows/release.yml@refs/tags/v${version}"
  if ! cosign verify-blob \
    --certificate "${checksums}.pem" \
    --signature "${checksums}.sig" \
    --certificate-identity "${identity}" \
    --certificate-oidc-issuer "${CERT_ISSUER}" \
    "${checksums}"; then
    log_err "cosign could not verify the v${version} checksums signature"
    exit 1
  fi

  local line_hash line_name line_rest sha='' matches=0
  # The `|| [[ -n ... ]]` keeps a final line that lacks its newline.
  while IFS=' ' read -r line_hash line_name line_rest || [[ -n ${line_hash} ]]; do
    if [[ ${line_name} == "${tarball}" && -z ${line_rest} ]]; then
      matches=$((matches + 1))
      sha="${line_hash}"
    fi
  done <"${checksums}"
  if ((matches != 1)); then
    log_err "the checksums file lists ${tarball} ${matches} times, not once"
    exit 1
  fi
  if [[ ! ${sha} =~ ^[0123456789abcdef]{64}$ ]]; then
    log_err "the checksums file holds a malformed digest for ${tarball}"
    exit 1
  fi
  printf 'version=%s\nsha256=%s\n' "${version}" "${sha}"
}

# @description Print one string field of the event payload. Errexit is off
# while the caller captures this function's output, so every jq status is
# checked here.
# @arg $1 jq filter  @arg $2 field label for the diagnostic
# @stdout the field, a 40-digit lower-case hex revision
# @exitcode 2 the field is missing, not a string, or not a revision
function event_revision() {
  local -r filter="$1"
  local -r label="$2"
  local value
  if ! value="$(jq --exit-status --raw-output "${filter} | select(type == \"string\")" "${GITHUB_EVENT_PATH}")"; then
    log_err "the event payload has no string ${label}"
    exit 2
  fi
  if [[ ! ${value} =~ ^[0123456789abcdef]{40}$ ]]; then
    log_err "the event payload's ${label} is not a 40-digit hex revision"
    exit 2
  fi
  printf '%s\n' "${value}"
}

# @description Print the BASE and HEAD revisions for the event, one per
# line (either may be empty), copying the trufflehog action's mapping. A
# push with no commits prints nothing and returns 3.
# @exitcode 2 the event is unsupported or its payload is unreadable
# @exitcode 3 nothing to scan
function event_range() {
  local -r event="${GITHUB_EVENT_NAME:-}"
  local base='' head=''
  case "${event}" in
  push | pull_request)
    if [[ ! -f ${GITHUB_EVENT_PATH:-} ]]; then
      log_err "GITHUB_EVENT_PATH does not name a file"
      exit 2
    fi
    if ! jq --exit-status 'type == "object"' "${GITHUB_EVENT_PATH}" >/dev/null; then
      log_err "the event payload is not a JSON object"
      exit 2
    fi
    ;;
  workflow_dispatch | schedule) ;;
  *)
    log_err "unsupported event: ${event:-<unset>}"
    exit 2
    ;;
  esac
  case "${event}" in
  push)
    local commits
    if ! commits="$(jq --exit-status --raw-output '.commits | select(type == "array") | length' "${GITHUB_EVENT_PATH}")"; then
      log_err "the push payload has no commits array"
      exit 2
    fi
    if [[ ${commits} == 0 ]]; then
      return 3
    fi
    head="$(event_revision '.after' 'after')" || exit 2
    base="$(event_revision '.before' 'before')" || exit 2
    if [[ ${base} == "${NULL_SHA}" ]]; then
      base=''
    fi
    ;;
  pull_request)
    base="$(event_revision '.pull_request.base.sha' 'pull_request.base.sha')" || exit 2
    head="$(event_revision '.pull_request.head.sha' 'pull_request.head.sha')" || exit 2
    ;;
  esac
  printf '%s\n%s\n' "${base}" "${head}"
}

function scan() {
  local version='' sha=''
  while (($# > 0)); do
    case "$1" in
    --version)
      (($# >= 2)) || usage
      version="$2"
      shift 2
      ;;
    --sha256)
      (($# >= 2)) || usage
      sha="$2"
      shift 2
      ;;
    *) usage ;;
    esac
  done
  if [[ ! ${version} =~ ^[0123456789]+\.[0123456789]+\.[0123456789]+$ ]]; then
    log_err "--version is not X.Y.Z"
    exit 2
  fi
  if [[ ! ${sha} =~ ^[0123456789abcdef]{64}$ ]]; then
    log_err "--sha256 is not 64 lower-case hex digits"
    exit 2
  fi
  require_tool curl
  require_tool jq
  require_tool tar
  require_tool sha256sum
  require_tool mktemp

  # Resolved before the event is read, so a run outside a work tree is
  # reported as that rather than as whatever the event lacks.
  local root
  root="$(repo_toplevel)"

  local range rc=0
  range="$(event_range)" || rc=$?
  if ((rc == 3)); then
    printf 'No commits to scan\n'
    exit 0
  elif ((rc != 0)); then
    exit "${rc}"
  fi
  local base head
  base="${range%%$'\n'*}"
  head="${range#*$'\n'}"

  tmp_dir="$(make_temp --directory)"
  local -r tarball="trufflehog_${version}_linux_amd64.tar.gz"
  fetch_asset "${version}" "${tarball}" "${tmp_dir}/${tarball}"
  printf '%s  %s\n' "${sha}" "${tarball}" >"${tmp_dir}/sha256sums"
  if ! (cd "${tmp_dir}" && sha256sum --check --strict --status sha256sums); then
    log_err "${tarball} does not match the verified digest"
    exit 1
  fi

  local -r bin_dir="${tmp_dir}/bin"
  mkdir --parents "${bin_dir}"
  # Naming the one member keeps every other archive entry from being
  # written; --no-wildcards makes the name literal and anchored.
  if ! tar --extract --gzip --no-wildcards --file "${tmp_dir}/${tarball}" --directory "${bin_dir}" trufflehog; then
    log_err "${tarball} holds no top-level trufflehog"
    exit 1
  fi
  if [[ -L ${bin_dir}/trufflehog || ! -f ${bin_dir}/trufflehog ]]; then
    log_err "the trufflehog entry in ${tarball} is not a regular file"
    exit 1
  fi
  chmod u+x "${bin_dir}/trufflehog"

  # The scan runs from the repository root, and only GitHub is reachable
  # from the job, so an unverifiable finding must still fail the run.
  rc=0
  (cd "${root}" && "${bin_dir}/trufflehog" git "file://${root}/" \
    --since-commit "${base}" --branch "${head}" \
    --fail --no-update --github-actions --results=verified,unknown) || rc=$?
  exit "${rc}"
}

function main() {
  (($# >= 1)) || usage
  trap cleanup EXIT
  local -r mode="$1"
  shift
  case "${mode}" in
  verify)
    (($# == 0)) || usage
    verify
    ;;
  scan) scan "$@" ;;
  *) usage ;;
  esac
}

main "$@"
