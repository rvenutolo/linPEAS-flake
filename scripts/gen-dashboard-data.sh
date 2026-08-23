#!/usr/bin/env bash
# scripts/gen-dashboard-data.sh
#
# @description Generate docs/_data/dashboard.yml for the MkDocs site
# by aggregating pin metadata and live GitHub REST API data.
# @generates docs/_data/dashboard.yml

# Generate docs/_data/dashboard.yml for the MkDocs site.
#
# Aggregates pin metadata (from linpeas-pin.json) plus live data from the
# GitHub REST API (upstream peass-ng/PEASS-ng release + recent upstream
# releases for bump-lag pairing, this-repo releases, last bump PR, latest
# verify-latest-release run) into a single YAML file consumed at MkDocs
# build time via mkdocs-macros-plugin `include_yaml`.
#
# Hard-fail rules (security-critical):
#   1. Any required CLI tool missing  -> exit 2 (see rule 7).
#   2. Upstream peass-ng releases/latest non-200 -> exit 2: the lookup
#      never happened, so it says nothing about the pin's contents.
#      This-repo lookups (releases/latest, last bump PR, latest
#      verify-latest-release run) soft-fall-back to empty/"unknown" so a
#      brand-new repo or transient API hiccup does not block the build.
#      A lookup that returns a JSON API error body is a degraded lookup,
#      not data: `gh api` writes that body to stdout, so it must be
#      shape-checked before use or the site publishes its missing keys as
#      a literal "null". Each degradation logs a WARN naming the lookup.
#   3. Missing required JSON field    -> exit 1 with field name; no partial
#                                        yaml written.
#   4. pin.version must match         -> [0-9]{8}-[0-9a-f]{7,40}
#   5. pin.url must start with        -> https://github.com/peass-ng/
#                                        PEASS-ng/releases/download/
#   6. Atomic write: make_temp + mv; never `>` redirect to the final path.
#   7. Inputs the generator cannot even read — a required CLI tool absent
#      from PATH, a missing pin file, or a pin/upstream-release/releases
#      payload that is empty, unparsable, or the wrong shape — exit 2,
#      not 1. Those say nothing about the pin's contents, and exit 1 is
#      reserved for data that was read and found bad.
#
# Exits 0 on success.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
# shellcheck source=scripts/lib/payload.sh
source "${_lib_dir}/lib/payload.sh"
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

# @description Fetch a JSON document from the live gh-api endpoint.
# @arg $1 gh api path
function fetch_live() {
  local -r api_path="$1"
  gh api --header 'X-GitHub-Api-Version: 2022-11-28' -- "${api_path}"
}

# @description Fill the caller's variable from an override fixture, if
# one is set. Returns 1 (filling nothing) when no override is set, so the
# caller falls through to its own literal `fetch_live` assignment — kept
# in the caller rather than folded into this helper, so a static
# shell-script analyzer sees a literal assignment to the caller's
# variable name and does not flag it as read-but-never-set. A nameref
# buried inside this helper would be invisible to that analysis even
# though the assignment happens at runtime.
#
# `read_json_payload_into` fills a nameref, so it must run in the
# calling shell — never inside `$(...)`, where its `exit 2` would be
# trapped in a subshell and the caller would carry on with an empty
# payload. This function is always invoked as a plain command, never
# captured with `$(...)`, so the read below runs directly here.
#
# Used only by the fetches whose payload is required (gated by
# `require_json_payload` in main): a missing or unreadable override for
# one of these is a could-not-run, not data. `fetch_soft`'s lookups are
# allowed to degrade instead, so they read their override through
# `fetch_soft_body` below rather than through this hard-exit path. The
# two names carry the difference: the `_into` suffix marks the reader
# that fills a caller variable and can `exit 2` in the caller's shell,
# and `fetch_soft_body` marks the one whose every failure is something
# `fetch_soft` is expected to catch and fall back on.
# @arg $1 name of the caller variable to fill
# @arg $2 override env var name
# @arg $3 source kind, as named by payload_source_into for this override
# @arg $4 optional subject, passed straight through to the reader —
#   supplied only by a fetch whose source kind another script in this
#   tree also names, which the reader's own contract is the reference for
# @exitcode 1 no override is set; the caller must fetch live
function fetch_override_into() {
  local -r out_var="$1"
  local -r override_var="$2"
  local -r src="$3"
  local -r subject="${4:-}"
  local -r override="${!override_var:-}"
  [[ -n ${override} ]] || return 1
  read_json_payload_into "${out_var}" "${override}" "${src}" "${subject}"
}

# @description Produce `fetch_soft`'s response body, from either an
# env-var override path (for tests) or the live gh-api endpoint,
# tolerating a read failure rather than exiting. It exists only as the
# body-producing half of `fetch_soft` below, whose lookups are allowed
# to degrade to a fallback on any failure, including a bad override
# fixture — hence the name: everything this function can do wrong is
# `fetch_soft`'s to absorb. The required fetches in main() use
# `fetch_override_into`/`fetch_live` instead, so a bad override on one
# of those is reported as a could-not-run rather than silently
# degrading.
# @arg $1 override env-var name (e.g. UPSTREAM_RELEASE_JSON_OVERRIDE)
# @arg $2 gh api path used when the override is unset
function fetch_soft_body() {
  local -r override_var="$1"
  local -r api_path="$2"
  local -r override_path="${!override_var:-}"
  if [[ -n ${override_path} ]]; then
    # payload-read-exempt: this read feeds fetch_soft's degrade-to-fallback contract — an absent, unreadable, or malformed override here must resolve to a status fetch_soft's caller can catch and fall back on, not the could-not-run exit the shared reader would raise.
    cat -- "${override_path}"
  else
    fetch_live "${api_path}"
  fi
}

# @description Fetch a this-repo lookup that is allowed to degrade. `gh
# api` writes its JSON error body to stdout, so a failed lookup arrives
# as a non-empty, non-null string that would otherwise be read as data —
# publishing a literal "null" tag or ref to the site. Emits the body only
# when the fetch succeeded, parsed as JSON, and carries the shape the
# caller needs; otherwise emits nothing and logs a WARN naming the
# degraded lookup, so a persistently broken lookup is visible in the
# build log instead of rendering as a permanent "unknown".
# @arg $1 override env-var name
# @arg $2 gh api path used when the override is unset
# @arg $3 jq expression asserting the required shape
# @arg $4 human label for the WARN line
function fetch_soft() {
  local -r override_var="$1"
  local -r api_path="$2"
  local -r shape="$3"
  local -r label="$4"

  local body rc=0
  body="$(fetch_soft_body "${override_var}" "${api_path}" 2>/dev/null)" || rc=$?
  if ((rc != 0)); then
    log WARN "${label}: lookup failed (exit ${rc}); using fallback"
    return 0
  fi
  if [[ -z ${body} ]]; then
    log WARN "${label}: empty response; using fallback"
    return 0
  fi
  if ! jq --exit-status "${shape}" <<<"${body}" >/dev/null 2>&1; then
    log WARN "${label}: response is not valid JSON of the expected shape; using fallback"
    return 0
  fi
  printf '%s' "${body}"
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

  # The pin gates below carry a subject. Their source kind —
  # `PIN_FILE_OVERRIDE` under a fixture, `linpeas-pin.json` otherwise —
  # is shared with `bump-linpeas.sh`, which reads the same file, so the
  # source alone leaves an operator unable to tell which script could
  # not read its pin.
  local pin_json pin_source
  payload_source_into pin_source PIN_FILE_OVERRIDE 'linpeas-pin.json'
  read_json_payload_into pin_json "${pin_file}" "${pin_source}" 'dashboard pin'

  mkdir --parents "$(dirname -- "${out_file}")"

  log_info 'gathering pin + upstream data'
  require_json_payload "${pin_source}" "${pin_json}" '
    if type != "object" then "payload is \(type), want object"
    elif (.version | type) != "string" then ".version is \(.version | type), want string"
    elif (.url | type) != "string" then ".url is \(.url | type), want string"
    else empty
    end' 'dashboard pin'

  local pin_version pin_url upstream_tag upstream_date
  pin_version="$(jq --raw-output .version <<<"${pin_json}")"
  pin_url="$(jq --raw-output .url <<<"${pin_json}")"
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
  # `bump-linpeas.sh` and the `pin.url` prefix assertion in `nix/linpeas.nix`.
  if [[ ${pin_url} != "${EXPECTED_PIN_URL_PREFIX}"* ]]; then
    log_err "pin.url outside expected upstream prefix: ${pin_url}"
    exit 1
  fi

  local upstream_release upstream_release_source
  payload_source_into upstream_release_source UPSTREAM_RELEASE_JSON_OVERRIDE \
    "repos/${UPSTREAM_REPO}/releases/latest"
  # read_json_payload_into (inside fetch_override_into) fills a nameref,
  # so it must run in this shell — never inside `$(...)`, where its
  # `exit 2` would be trapped in a subshell and this script would carry
  # on with an empty upstream_release.
  #
  # Both gates carry a subject: `bump-linpeas.sh` names this identical
  # API route for its own upstream-release fetch, so on a live run the
  # source kind alone identifies neither caller. The two list fetches
  # below name routes no other script reads, so they pass none.
  if ! fetch_override_into upstream_release UPSTREAM_RELEASE_JSON_OVERRIDE \
    "${upstream_release_source}" 'dashboard upstream release'; then
    # `gh` is on PATH — an absent one is reported by require_tool above —
    # so a failure here is the API refusing, the token expiring, or the
    # network being gone. That is a lookup that never happened, not a
    # pin this generator read and rejected, and the two must not leave
    # the run with the same status.
    if ! upstream_release="$(fetch_live "repos/${UPSTREAM_REPO}/releases/latest")"; then
      log_err "could not fetch ${upstream_release_source}"
      exit 2
    fi
  fi
  require_json_payload "${upstream_release_source}" "${upstream_release}" '
    if type != "object" then "payload is \(type), want object"
    elif (.tag_name | type) != "string" then ".tag_name is \(.tag_name | type), want string"
    elif (.published_at | type) != "string" then ".published_at is \(.published_at | type), want string"
    else empty
    end' 'dashboard upstream release'
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
  latest_release="$(fetch_soft LATEST_RELEASE_JSON_OVERRIDE \
    "repos/${THIS_REPO}/releases/latest" \
    '.tag_name | type == "string" and length > 0' \
    'releases/latest')"
  if [[ -z ${latest_release} || ${latest_release} == 'null' ]]; then
    latest_tag=''
    image_ref=''
  else
    latest_tag="$(jq --raw-output .tag_name <<<"${latest_release}")"
    image_ref="ghcr.io/rvenutolo/linpeas:${latest_tag}"
  fi

  log_info 'gathering recent releases'
  local releases_json releases_source
  payload_source_into releases_source THIS_REPO_RELEASES_JSON_OVERRIDE \
    "repos/${THIS_REPO}/releases?per_page=20"
  # read_json_payload_into (inside fetch_override_into) fills a nameref,
  # so it must run in this shell — never inside `$(...)`, where its
  # `exit 2` would be trapped in a subshell and this script would carry
  # on with an empty releases_json.
  if ! fetch_override_into releases_json THIS_REPO_RELEASES_JSON_OVERRIDE \
    "${releases_source}"; then
    if ! releases_json="$(fetch_live "repos/${THIS_REPO}/releases?per_page=20")"; then
      log_err "could not fetch ${releases_source}"
      exit 2
    fi
  fi
  require_json_payload "${releases_source}" "${releases_json}" '
    if type != "array" then "payload is \(type), want array"
    elif (any(.[]; (.tag_name | type) != "string")) then "a release entry .tag_name is not a string"
    elif (any(.[]; (.published_at | type) != "string")) then "a release entry .published_at is not a string"
    else empty
    end'

  log_info 'gathering recent upstream releases'
  local upstream_releases_json upstream_releases_source
  payload_source_into upstream_releases_source UPSTREAM_RELEASES_JSON_OVERRIDE \
    "repos/${UPSTREAM_REPO}/releases?per_page=20"
  # read_json_payload_into (inside fetch_override_into) fills a nameref,
  # so it must run in this shell — never inside `$(...)`, where its
  # `exit 2` would be trapped in a subshell and this script would carry
  # on with an empty upstream_releases_json.
  if ! fetch_override_into upstream_releases_json UPSTREAM_RELEASES_JSON_OVERRIDE \
    "${upstream_releases_source}"; then
    if ! upstream_releases_json="$(fetch_live "repos/${UPSTREAM_REPO}/releases?per_page=20")"; then
      log_err "could not fetch ${upstream_releases_source}"
      exit 2
    fi
  fi
  require_json_payload "${upstream_releases_source}" "${upstream_releases_json}" '
    if type != "array" then "payload is \(type), want array"
    elif (any(.[]; (.tag_name | type) != "string")) then "a release entry .tag_name is not a string"
    elif (any(.[]; (.published_at | type) != "string")) then "a release entry .published_at is not a string"
    else empty
    end'

  log_info 'gathering last bump PR'
  local bump_pr_json bump_pr_url bump_pr_number bump_pr_merged_at
  bump_pr_json="$(fetch_soft BUMP_PR_JSON_OVERRIDE \
    "search/issues?q=repo:${THIS_REPO}+is:pr+is:merged+in:title+chore%3A+bump+linpeas&sort=updated&order=desc&per_page=1" \
    '((.items | type) == "array") and all(.items[]; type == "object")' \
    'last bump PR')"
  # A swallowed Search-API failure (the `|| true` above) yields an empty
  # string, not `{"items":[]}`. jq on empty input emits nothing — the `// 0`
  # default never fires (zero inputs, not a null value) — so bump_pr_number
  # would be "" and `--argjson bump_pr_number ""` aborts the assembly jq.
  # Degrade to the documented empty last-bump section instead, matching the
  # latest_release / parity_json soft-fallbacks (hard-fail rule 2).
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
  parity_json="$(fetch_soft PARITY_JSON_OVERRIDE \
    "repos/${THIS_REPO}/actions/workflows/verify-latest-release.yml/runs?per_page=1" \
    '((.workflow_runs | type) == "array") and all(.workflow_runs[]; type == "object")' \
    'parity run')"
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
  out_tmp="$(make_temp --tmpdir="$(dirname -- "${out_file}")" dashboard.yml.XXXXXX)"
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
  # The payload gate proves each `published_at` is a string, not that it
  # is a date `fromdateiso8601` can parse. A jq that dies on the pairing
  # has computed no lag at all, and its exit 5 is outside the convention.
  local lag_recent
  if ! lag_recent="$(jq --compact-output --slurp '
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
    ' <(printf '%s' "${upstream_releases_json}") <(printf '%s' "${releases_json}"))"; then
    log_err 'could not pair this-repo releases with upstream releases for bump lag'
    exit 2
  fi

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

  # A render that failed wrote a partial document, and the caller must not
  # read the exit status as anything but a could-not-run: jq leaves 5 on a
  # payload it cannot parse and yq leaves 1, which this contract reserves
  # for a required field that was missing from a payload it did read.
  if ! jq --null-input \
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
    yq --prettyPrint --output-format=yaml eval '.' - >"${out_tmp}"; then
    log_err "could not render the dashboard document into ${out_tmp}"
    exit 2
  fi

  mv -- "${out_tmp}" "${out_file}"
  trap - EXIT
  log_info "wrote ${out_file}"
}

main "$@"
