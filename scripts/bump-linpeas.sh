#!/usr/bin/env bash
# scripts/bump-linpeas.sh
#
# @description Bump linpeas-pin.json to the latest peass-ng/PEASS-ng release.

# Exits 0 with no changes if the pin is already current.
# Exits 0 with file changes if a bump was made.
# Exits 1 on a bump error — an upstream tag or asset that fails
# validation, a digest mismatch.
# Exits 2 when the bump cannot start: a required tool is absent from
# PATH, or the pin file it reads and rewrites is not there.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"
install_err_trap

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
    exit 2
  fi

  local current_version
  current_version="$(jq --raw-output .version "${pin_file}")"
  log_info "current pin: ${current_version}"

  local release_json
  # Pin `X-GitHub-Api-Version` (defense-in-depth). If GitHub ever
  # ships a v2 of the `releases/latest` schema, the explicit header makes
  # the failure mode "API version mismatch" rather than a downstream
  # "asset URL empty, weird" failure. See:
  # https://docs.github.com/en/rest/overview/api-versions
  release_json="$(gh api \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    repos/peass-ng/PEASS-ng/releases/latest)"

  local new_tag
  new_tag="$(printf '%s' "${release_json}" | jq --raw-output .tag_name)"
  log_info "upstream latest: ${new_tag}"

  # Shape-validate before any downstream use: branch name, commit message,
  # PR title, and pin file all interpolate this verbatim. Hoists the
  # canonical regex (mirrors the assertion in flake.nix) to the
  # entry of the bump chain so a malformed upstream tag is rejected
  # before any artefact is produced. Mirrors the layered "validate-then-use"
  # pattern (flake.nix eval, gen-dashboard-data.sh, release-on-bump.yml).
  if [[ ! ${new_tag} =~ ^[0-9]{8}-[0-9a-f]{7,40}$ ]]; then
    log_err "upstream tag does not match expected format: ${new_tag}"
    exit 1
  fi

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

  # Defense in depth: refuse any asset URL outside the expected upstream
  # release-asset prefix. Protects against a tampered or malformed API
  # response substituting an attacker-controlled URL into the pin file.
  local -r expected_url_prefix='https://github.com/peass-ng/PEASS-ng/releases/download/'
  if [[ ${asset_url} != "${expected_url_prefix}"* ]]; then
    log_err "asset URL outside expected prefix: ${asset_url}"
    exit 1
  fi

  local tmpfile pin_tmp
  # Declare `pin_tmp` early so the EXIT trap can reference it even when
  # the second `mktemp` (below) never runs: without the early
  # declaration a partial failure between `mktemp --tmpdir=...` and the
  # final `mv` leaves a stray `linpeas-pin.json.XXXXXX` in the working
  # tree.
  pin_tmp=''
  tmpfile="$(mktemp)"
  # Use :- defaults so the trap (fires after main() returns) does not trip
  # set -u when these locals have gone out of scope.
  trap 'rm --force -- "${tmpfile:-}" "${pin_tmp:-}"' EXIT

  curl --disable --fail --silent --show-error --location \
    --output "${tmpfile}" "${asset_url}"

  # The GitHub release-asset `.digest` field is an independent integrity
  # signal from the file we just downloaded. Absence/null is treated as a
  # hard fail rather than a silent skip — readme.md advertises this as a
  # security property, so it must never be silently bypassed.
  if [[ -z ${asset_digest} || ${asset_digest} == 'null' ]]; then
    log_err "release ${new_tag} asset has no .digest field — cannot cross-check"
    exit 1
  fi
  if [[ ${asset_digest} != sha256:* ]]; then
    log_err "unsupported digest algorithm: ${asset_digest}"
    exit 1
  fi
  local expected_sha actual_sha_line actual_sha
  expected_sha="${asset_digest#sha256:}"
  actual_sha_line="$(sha256sum "${tmpfile}")"
  actual_sha="${actual_sha_line%% *}"
  if [[ ${expected_sha} != "${actual_sha}" ]]; then
    log_err "sha256 mismatch (expected ${expected_sha}, got ${actual_sha})"
    exit 1
  fi

  local sri_hash
  # `--type sha256` is the default and is deprecated; default to SRI sha256.
  sri_hash="$(nix hash file --sri "${tmpfile}")"

  # Pin schema: key is `hash`, not `sha256`.
  # The shape emitted here (3 top-level keys, sorted alphabetically by
  # jq's default object construction order: hash, url, version, plus a
  # trailing newline from printf) must stay byte-identical to what
  # prettier would write for `*.json` files. treefmt runs prettier on
  # `linpeas-pin.json`; any drift here would cause the next `nix fmt`
  # to rewrite the bumper's output and trip pre-commit on the bump PR.
  local new_pin
  new_pin="$(jq --null-input \
    --arg version "${new_tag}" \
    --arg url "${asset_url}" \
    --arg hash "${sri_hash}" \
    '{version: $version, url: $url, hash: $hash}')"

  # Atomic replace: write to a sibling temp file then rename. Avoids
  # leaving a truncated pin file behind on SIGKILL / runner termination.
  # `pin_tmp` was declared at the top of `main` so the EXIT trap also
  # cleans up this temp on failure between `mktemp` and `mv`.
  pin_tmp="$(mktemp --tmpdir="$(dirname -- "${pin_file}")" linpeas-pin.json.XXXXXX)"
  printf '%s\n' "${new_pin}" >"${pin_tmp}"
  mv -- "${pin_tmp}" "${pin_file}"
  log_info "bumped ${current_version} -> ${new_tag}"
}

main "$@"
