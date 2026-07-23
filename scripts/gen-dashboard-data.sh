#!/usr/bin/env bash
# scripts/gen-dashboard-data.sh
#
# @description Generate docs/_data/dashboard.yml for the MkDocs site
# by aggregating pin metadata and live GitHub REST API data.

# Generate docs/_data/dashboard.yml for the MkDocs site.
#
# Aggregates pin metadata (from linpeas-pin.json) plus live data from the
# GitHub REST API (upstream peass-ng/PEASS-ng release + recent upstream
# releases for bump-lag pairing, this-repo releases, last bump PR, latest
# verify-latest-release run) into a single YAML file consumed at MkDocs
# build time via mkdocs-macros-plugin `include_yaml`.
#
# Hard-fail rules (security-critical):
#   1. Any required CLI tool missing  -> exit 1.
#   2. Upstream peass-ng releases/latest non-200 -> exit 1 (curl/gh error
#      surfaced). This-repo lookups (releases/latest, last bump PR, latest
#      verify-latest-release run) soft-fall-back to empty/"unknown" so a
#      brand-new repo or transient API hiccup does not block the build.
#   3. Missing required JSON field    -> exit 1 with field name; no partial
#                                        yaml written.
#   4. pin.version must match         -> [0-9]{8}-[0-9a-f]{7,40}
#   5. pin.url must start with        -> https://github.com/peass-ng/
#                                        PEASS-ng/releases/download/
#   6. Atomic write: mktemp + mv; never `>` redirect to the final path.
#
# Exits 0 on success.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"
install_err_trap

# @description Verify a JSON-extracted field is non-empty and not 'null';
# exit 1 with the field name if missing.
# @arg $1 value
# @arg $2 field name (for error message)
function require_field() {
  local -r value="$1"
  local -r name="$2"
  if [[ -z ${value} || ${value} == 'null' ]]; then
    log_err "required field missing: ${name}"
    exit 1
  fi
}

readonly UPSTREAM_REPO='peass-ng/PEASS-ng'
readonly THIS_REPO='rvenutolo/linPEAS-flake'
readonly EXPECTED_PIN_URL_PREFIX='https://github.com/peass-ng/PEASS-ng/releases/download/'
readonly VERSION_REGEX='^[0-9]{8}-[0-9a-f]{7,40}$'

# @description Fetch JSON from either an env-var override path (for tests) or
# the live gh-api endpoint. Override path lets the test harness exercise the
# script's security-critical failure branches without hitting the network and
# without mutating real on-disk state. When the override var is empty/unset,
# behavior is identical to a plain `gh api "${api_path}"`.
# @arg $1 override env-var name (e.g. UPSTREAM_RELEASE_JSON_OVERRIDE)
# @arg $2 gh api path used when the override is unset
function fetch_or_override() {
  local -r override_var="$1"
  local -r api_path="$2"
  local -r override_path="${!override_var:-}"
  if [[ -n ${override_path} ]]; then
    cat -- "${override_path}"
  else
    gh api --header 'X-GitHub-Api-Version: 2022-11-28' -- "${api_path}"
  fi
}

function main() {
  require_tool git
  require_tool gh
  require_tool jq
  require_tool date
  require_tool yq

  local repo_root pin_file out_file out_tmp
  repo_root="$(git rev-parse --show-toplevel)"
  pin_file="${repo_root}/linpeas-pin.json"
  if [[ -n ${PIN_FILE_OVERRIDE:-} ]]; then
    pin_file="${PIN_FILE_OVERRIDE}"
  fi
  out_file="${OUT_FILE_OVERRIDE:-${repo_root}/docs/_data/dashboard.yml}"
  readonly repo_root pin_file out_file

  if [[ ! -f ${pin_file} ]]; then
    log_err "${pin_file} not found"
    exit 1
  fi

  mkdir --parents "$(dirname -- "${out_file}")"

  log_info 'gathering pin + upstream data'
  local pin_version pin_url upstream_tag upstream_date
  pin_version="$(jq --raw-output .version "${pin_file}")"
  pin_url="$(jq --raw-output .url "${pin_file}")"
  require_field "${pin_version}" 'pin.version'
  require_field "${pin_url}" 'pin.url'
  if [[ ! ${pin_version} =~ ${VERSION_REGEX} ]]; then
    log_err "pin.version does not match expected format: ${pin_version}"
    exit 1
  fi
  # Symmetric prefix check for `pin.url`. The dashboard page
  # renders `pin.url` as a clickable link; without this guard a malformed
  # pin file reaching the site-build path could produce a phishing link.
  # Mirrors the `pin.url` prefix guard already present in
  # `bump-linpeas.sh` and the `pin.url` prefix assertion in `flake.nix`.
  if [[ ${pin_url} != "${EXPECTED_PIN_URL_PREFIX}"* ]]; then
    log_err "pin.url outside expected upstream prefix: ${pin_url}"
    exit 1
  fi

  local upstream_release
  upstream_release="$(fetch_or_override UPSTREAM_RELEASE_JSON_OVERRIDE \
    "repos/${UPSTREAM_REPO}/releases/latest")"
  upstream_tag="$(jq --raw-output .tag_name <<<"${upstream_release}")"
  upstream_date="$(jq --raw-output .published_at <<<"${upstream_release}")"
  require_field "${upstream_tag}" 'upstream_release.tag_name'
  require_field "${upstream_date}" 'upstream_release.published_at'

  # Compute drift between the pin's YYYYMMDD prefix and upstream's
  # published_at timestamp. Clamp negative drift to 0 (clock skew, or pin
  # ahead of "latest" during a brief upstream pre-release window).
  local pin_date_iso upstream_epoch pin_epoch drift_days
  pin_date_iso="${pin_version:0:4}-${pin_version:4:2}-${pin_version:6:2}T00:00:00Z"
  upstream_epoch="$(date --date "${upstream_date}" +%s)"
  pin_epoch="$(date --date "${pin_date_iso}" +%s)"
  drift_days=$(((upstream_epoch - pin_epoch) / 86400))
  if ((drift_days < 0)); then
    drift_days=0
  fi

  log_info 'gathering this-repo release data'
  local latest_release latest_tag image_ref
  latest_release="$(fetch_or_override LATEST_RELEASE_JSON_OVERRIDE \
    "repos/${THIS_REPO}/releases/latest" 2>/dev/null || true)"
  if [[ -z ${latest_release} || ${latest_release} == 'null' ]]; then
    latest_tag=''
    image_ref=''
  else
    latest_tag="$(jq --raw-output .tag_name <<<"${latest_release}")"
    image_ref="ghcr.io/rvenutolo/linpeas:${latest_tag}"
  fi

  log_info 'gathering recent releases'
  local releases_json
  releases_json="$(fetch_or_override THIS_REPO_RELEASES_JSON_OVERRIDE \
    "repos/${THIS_REPO}/releases?per_page=20")"

  log_info 'gathering recent upstream releases'
  local upstream_releases_json
  upstream_releases_json="$(fetch_or_override UPSTREAM_RELEASES_JSON_OVERRIDE \
    "repos/${UPSTREAM_REPO}/releases?per_page=20")"

  log_info 'gathering last bump PR'
  local bump_pr_json bump_pr_url bump_pr_number bump_pr_merged_at
  bump_pr_json="$(fetch_or_override BUMP_PR_JSON_OVERRIDE \
    "search/issues?q=repo:${THIS_REPO}+is:pr+is:merged+in:title+chore%3A+bump+linpeas&sort=updated&order=desc&per_page=1" ||
    true)"
  # A swallowed Search-API failure (the `|| true` above) yields an empty
  # string, not `{"items":[]}`. jq on empty input emits nothing — the `// 0`
  # default never fires (zero inputs, not a null value) — so bump_pr_number
  # would be "" and `--argjson bump_pr_number ""` aborts the assembly jq.
  # Degrade to the documented empty last-bump section instead, matching the
  # latest_release / parity_json soft-fallbacks (hard-fail rule #2).
  if [[ -z ${bump_pr_json} ]]; then
    bump_pr_url=''
    bump_pr_number=0
    bump_pr_merged_at=''
  else
    bump_pr_url="$(jq --raw-output '.items[0].html_url // ""' <<<"${bump_pr_json}")"
    bump_pr_number="$(jq --raw-output '.items[0].number // 0' <<<"${bump_pr_json}")"
    bump_pr_merged_at="$(jq --raw-output '.items[0].closed_at // ""' <<<"${bump_pr_json}")"
  fi

  log_info 'gathering parity-check run'
  local parity_json parity_conclusion parity_checked_at parity_run_url
  parity_json="$(fetch_or_override PARITY_JSON_OVERRIDE \
    "repos/${THIS_REPO}/actions/workflows/verify-latest-release.yml/runs?per_page=1" \
    2>/dev/null || true)"
  if [[ -z ${parity_json} ]]; then
    parity_conclusion='unknown'
    parity_checked_at=''
    parity_run_url=''
  else
    parity_conclusion="$(jq --raw-output '.workflow_runs[0].conclusion // "unknown"' <<<"${parity_json}")"
    parity_checked_at="$(jq --raw-output '.workflow_runs[0].updated_at // ""' <<<"${parity_json}")"
    parity_run_url="$(jq --raw-output '.workflow_runs[0].html_url // ""' <<<"${parity_json}")"
  fi

  local generated_at
  generated_at="$(date --utc --iso-8601=seconds)"

  log_info "assembling ${out_file}"
  out_tmp="$(mktemp --tmpdir="$(dirname -- "${out_file}")" dashboard.yml.XXXXXX)"
  # The EXIT trap captures the literal path at trap-set time (single-quoted
  # would defer expansion and ${out_tmp} may have gone out of scope by then).
  # shellcheck disable=SC2064
  trap "rm --force -- '${out_tmp}'" EXIT

  local releases_yaml_items
  releases_yaml_items="$(jq --compact-output '[.[] | {
      tag: .tag_name,
      date: .published_at,
      image_tag: ("ghcr.io/rvenutolo/linpeas:" + .tag_name)
    }]' <<<"${releases_json}")"

  # Pair each this-repo release with the upstream release of the same tag
  # (this repo mirrors upstream tags) and compute bump lag in hours.
  # Unmatched this-repo releases (no upstream entry within the fetched
  # window) are skipped with a warning, not failed: the upstream window is
  # finite and a very old this-repo release may have aged out of it.
  local lag_recent
  lag_recent="$(jq --compact-output --slurp '
      (.[0] | map({(.tag_name): .published_at}) | add) as $upstream
      | .[1]
      | map(
          . as $r
          | ($upstream[$r.tag_name]) as $up
          | select($up != null)
          | {
              tag: $r.tag_name,
              our_date: $r.published_at,
              upstream_date: $up,
              lag_hours: (
                ((($r.published_at | fromdateiso8601)
                - ($up | fromdateiso8601)) / 3600)
                | (. * 10 | round) / 10
              ),
            }
        )
      | reverse
    ' <(printf '%s' "${upstream_releases_json}") <(printf '%s' "${releases_json}"))"

  local unmatched
  unmatched="$(jq --raw-output --slurp '
      (.[0] | map(.tag_name)) as $upstream_tags
      | .[1]
      | map(select(.tag_name as $t | ($upstream_tags | index($t)) | not) | .tag_name)
      | .[]
    ' <(printf '%s' "${upstream_releases_json}") <(printf '%s' "${releases_json}"))"
  if [[ -n ${unmatched} ]]; then
    while IFS= read -r tag; do
      log_info "lag: skipping this-repo release with no upstream match: ${tag}"
    done <<<"${unmatched}"
  fi

  jq --null-input \
    --arg pin_version "${pin_version}" \
    --arg pin_url "${pin_url}" \
    --arg upstream_tag "${upstream_tag}" \
    --arg upstream_date "${upstream_date}" \
    --argjson drift_days "${drift_days}" \
    --arg upstream_latest "${upstream_tag}" \
    --arg bump_pr_url "${bump_pr_url}" \
    --argjson bump_pr_number "${bump_pr_number}" \
    --arg bump_pr_merged_at "${bump_pr_merged_at}" \
    --arg latest_tag "${latest_tag}" \
    --arg image_ref "${image_ref}" \
    --arg parity_conclusion "${parity_conclusion}" \
    --arg parity_checked_at "${parity_checked_at}" \
    --arg parity_run_url "${parity_run_url}" \
    --argjson releases "${releases_yaml_items}" \
    --argjson lag_recent "${lag_recent}" \
    --arg generated_at "${generated_at}" \
    '{
      pin: {
        version: $pin_version,
        url: $pin_url,
        upstream_tag: $upstream_tag,
        upstream_date: $upstream_date,
      },
      drift: {
        days: $drift_days,
        upstream_latest: $upstream_latest,
      },
      last_bump: {
        pr_url: $bump_pr_url,
        pr_number: $bump_pr_number,
        merged_at: $bump_pr_merged_at,
      },
      release: {
        latest_tag: $latest_tag,
        image_ref: $image_ref,
      },
      parity: {
        conclusion: $parity_conclusion,
        checked_at: $parity_checked_at,
        run_url: $parity_run_url,
      },
      releases: $releases,
      lag: {
        recent: $lag_recent,
      },
      generated_at: $generated_at,
    }' |
    yq --prettyPrint --output-format=yaml eval '.' - >"${out_tmp}"

  mv -- "${out_tmp}" "${out_file}"
  trap - EXIT
  log_info "wrote ${out_file}"
}

main "$@"
