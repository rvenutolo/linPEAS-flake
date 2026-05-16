#!/usr/bin/env bash
# Bump linpeas-pin.json to the latest peass-ng/PEASS-ng release.
#
# Exits 0 with no changes if the pin is already current.
# Exits 0 with file changes if a bump was made.
# Exits non-zero on any error.

set -Eeuo pipefail
IFS=$'\n\t'
trap 'printf "[%s] %-5s line %s (exit %s): %s\n" \
  "$(date "+%Y-%m-%dT%H:%M:%S%z")" ERROR "${LINENO}" "$?" "${BASH_COMMAND}" >&2' ERR

function log() {
  printf '[%s] %-5s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >&2
}
function log_info() { log INFO "$*"; }
function log_err() { log ERROR "$*"; }

# @description Verify a required CLI tool is on PATH; exit 1 if missing.
# @arg $1 tool name
function require_tool() {
  local -r tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    log_err "missing required tool: ${tool}"
    exit 1
  fi
}

function main() {
  require_tool git
  require_tool gh
  require_tool jq
  require_tool curl
  require_tool nix
  require_tool sha256sum

  local repo_root pin_file
  repo_root="$(git rev-parse --show-toplevel)"
  pin_file="${repo_root}/linpeas-pin.json"
  readonly repo_root pin_file

  if [[ ! -f ${pin_file} ]]; then
    log_err "${pin_file} not found"
    exit 1
  fi

  local current_version
  current_version="$(jq --raw-output .version "${pin_file}")"
  log_info "current pin: ${current_version}"

  local release_json
  release_json="$(gh api repos/peass-ng/PEASS-ng/releases/latest)"

  local new_tag
  new_tag="$(printf '%s' "${release_json}" | jq --raw-output .tag_name)"
  log_info "upstream latest: ${new_tag}"

  if [[ ${current_version} == "${new_tag}" ]]; then
    log_info 'already at latest, nothing to do'
    exit 0
  fi

  local asset_url asset_digest
  asset_url="$(printf '%s' "${release_json}" |
    jq --raw-output '.assets[] | select(.name == "linpeas.sh") | .browser_download_url')"
  asset_digest="$(printf '%s' "${release_json}" |
    jq --raw-output '.assets[] | select(.name == "linpeas.sh") | .digest')"

  if [[ -z ${asset_url} ]]; then
    log_err "release ${new_tag} has no linpeas.sh asset"
    exit 1
  fi

  local tmpfile
  tmpfile="$(mktemp)"
  # Use :- default so the trap (fires after main() returns) does not trip
  # set -u when this local has gone out of scope.
  trap 'rm --force -- "${tmpfile:-}"' EXIT

  curl --disable --fail --silent --show-error --location \
    --output "${tmpfile}" "${asset_url}"

  if [[ -n ${asset_digest} && ${asset_digest} != 'null' ]]; then
    local expected_sha actual_sha_line actual_sha
    expected_sha="${asset_digest#sha256:}"
    actual_sha_line="$(sha256sum "${tmpfile}")"
    actual_sha="${actual_sha_line%% *}"
    if [[ ${expected_sha} != "${actual_sha}" ]]; then
      log_err "sha256 mismatch (expected ${expected_sha}, got ${actual_sha})"
      exit 1
    fi
  fi

  local sri_hash
  # `--type sha256` is the default and is deprecated; default to SRI sha256.
  sri_hash="$(nix hash file --sri "${tmpfile}")"

  # Per D5: key is `hash`, not `sha256`.
  local new_pin
  new_pin="$(jq --null-input \
    --arg version "${new_tag}" \
    --arg url "${asset_url}" \
    --arg hash "${sri_hash}" \
    '{version: $version, url: $url, hash: $hash}')"

  printf '%s\n' "${new_pin}" >"${pin_file}"
  log_info "bumped ${current_version} -> ${new_tag}"
}

main "$@"
