#!/usr/bin/env bash
# tests/trufflehog-release.test.sh
#
# Behavior matrix for scripts/trufflehog-release.sh: the `verify` result
# shape and its rejections, the version-file shape, the `scan` argument
# checks, the event-to-range mapping, the digest check and the archive
# extraction rules. The release tree is generated into a scratch directory
# and fetched over file://; the trufflehog binary and cosign are stubs that
# write their argv to a marker file, so nothing leaves the machine and no
# payload has a side effect beyond that file.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/trufflehog-release.sh"
readonly VERSION='3.99.4'
readonly TARBALL="trufflehog_${VERSION}_linux_amd64.tar.gz"
readonly WANT_IDENTITY="https://github.com/trufflesecurity/trufflehog/.github/workflows/release.yml@refs/tags/v${VERSION}"
readonly WANT_ISSUER='https://token.actions.githubusercontent.com'
readonly NULL_SHA='0000000000000000000000000000000000000000'

failures=0
scratch="$(mktemp --directory)"
readonly scratch
# shellcheck disable=SC2064 # expanded now on purpose: the path is fixed once created
trap "rm --recursive --force -- '${scratch}'" EXIT

readonly RELEASE_DIR="${scratch}/release/v${VERSION}"
readonly STUB_BIN="${scratch}/stubbin"
readonly MARKER="${scratch}/marker"
readonly COSIGN_MARKER="${scratch}/cosign-marker"
mkdir --parents "${RELEASE_DIR}" "${STUB_BIN}"

cat >"${STUB_BIN}/cosign" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${COSIGN_MARKER}"
exit "${COSIGN_EXIT:-0}"
STUB_EOF
chmod +x "${STUB_BIN}/cosign"

# @description Build the release tree: a tarball of the given variant, its
# checksums file, and dummy signature and certificate files.
# @arg $1 variant: plain | extras | symlink
function build_release() {
  local -r variant="$1"
  local stage="${scratch}/stage"
  rm --recursive --force -- "${scratch}/stage" "${RELEASE_DIR}"
  mkdir --parents "${stage}" "${RELEASE_DIR}"
  case "${variant}" in
  nobin)
    mkdir "${stage}/evil"
    cat >"${stage}/evil/trufflehog" <<'NOBIN_EOF'
#!/usr/bin/env bash
printf EVIL_RAN >"${STUB_MARKER}"
NOBIN_EOF
    chmod +x "${stage}/evil/trufflehog"
    ;;
  symlink)
    # The link target is a user-owned stub that stays on disk, so only the
    # link check, not a permissions error or a dangling target, can reject it.
    cat >"${scratch}/linktarget" <<'LINK_EOF'
#!/usr/bin/env bash
printf LINK_RAN >"${STUB_MARKER}"
LINK_EOF
    chmod +x "${scratch}/linktarget"
    ln --symbolic "${scratch}/linktarget" "${stage}/trufflehog"
    ;;
  *)
    cat >"${stage}/trufflehog" <<'BIN_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_MARKER}"
ls -A "${0%/*}" >"${STUB_MARKER}.listing"
exit "${STUB_EXIT:-0}"
BIN_EOF
    chmod +x "${stage}/trufflehog"
    ;;
  esac
  if [[ ${variant} == nobin ]]; then
    tar --create --gzip --file "${RELEASE_DIR}/${TARBALL}" --directory "${stage}" evil
  elif [[ ${variant} == extras ]]; then
    mkdir "${stage}/evil"
    cat >"${stage}/evil/trufflehog" <<'EVIL_EOF'
#!/usr/bin/env bash
printf EVIL_RAN >"${STUB_MARKER}"
EVIL_EOF
    chmod +x "${stage}/evil/trufflehog"
    printf 'readme\n' >"${stage}/README.md"
    tar --create --gzip --file "${RELEASE_DIR}/${TARBALL}" --directory "${stage}" evil README.md trufflehog
  else
    tar --create --gzip --file "${RELEASE_DIR}/${TARBALL}" --directory "${stage}" trufflehog
  fi
  FIXTURE_SHA="$(sha256sum "${RELEASE_DIR}/${TARBALL}")"
  FIXTURE_SHA="${FIXTURE_SHA%% *}"
  printf '%s  %s\n' "${FIXTURE_SHA}" "${TARBALL}" >"${RELEASE_DIR}/trufflehog_${VERSION}_checksums.txt"
  printf 'sig\n' >"${RELEASE_DIR}/trufflehog_${VERSION}_checksums.txt.sig"
  printf 'pem\n' >"${RELEASE_DIR}/trufflehog_${VERSION}_checksums.txt.pem"
}

function write_checksums() {
  printf '%b' "$1" >"${RELEASE_DIR}/trufflehog_${VERSION}_checksums.txt"
}

function write_version_file() {
  printf '%b' "$1" >"${scratch}/version"
}

function fail() {
  printf 'FAIL %s: %s\n' "$1" "$2" >&2
  failures=1
}

# Runs the script from the repo root; sets rc, out, err.
function run() {
  rc=0
  rm --force -- "${MARKER}" "${MARKER}.listing" "${COSIGN_MARKER}"
  (cd "${REPO_ROOT}" && env \
    PATH="${STUB_BIN}:${PATH}" \
    TRUFFLEHOG_VERSION_FILE_OVERRIDE="${scratch}/version" \
    TRUFFLEHOG_RELEASE_BASE_URL_OVERRIDE="file://${scratch}/release" \
    STUB_MARKER="${MARKER}" COSIGN_MARKER="${COSIGN_MARKER}" \
    "$@" bash "${SCRIPT}" "${SCENARIO_ARGS[@]}") >"${scratch}/out" 2>"${scratch}/err" || rc=$?
  out="$(<"${scratch}/out")"
  err="$(<"${scratch}/err")"
}

function expect_rc() {
  local -r label="$1" want="$2"
  if [[ ${rc} != "${want}" ]]; then
    fail "${label}" "exit ${rc}, want ${want}; stderr: ${err}"
    return 1
  fi
}

function pass() { printf 'OK   %s\n' "$1"; }

# Writes an event payload file and sets GITHUB_EVENT_PATH-style path.
function write_event() {
  printf '%s' "$1" >"${scratch}/event.json"
}

function marker_lines() {
  if [[ -f ${MARKER} ]]; then cat "${MARKER}"; fi
}

# @description One scan scenario. Expects the binary's argv (newline-joined).
# @arg $1 label  @arg $2 event name  @arg $3 want argv  @arg $4 want rc
function scan_scenario() {
  local -r label="$1" event="$2" want_argv="$3" want_rc="$4"
  SCENARIO_ARGS=(scan --version "${VERSION}" --sha256 "${FIXTURE_SHA}")
  run GITHUB_EVENT_NAME="${event}" GITHUB_EVENT_PATH="${scratch}/event.json" STUB_EXIT="${STUB_EXIT_FOR:-0}"
  expect_rc "${label}" "${want_rc}" || return 0
  local got
  got="$(marker_lines)"
  if [[ ${got} != "${want_argv}" ]]; then
    fail "${label}" "binary argv was $(printf '%q' "${got}"), want $(printf '%q' "${want_argv}")"
    return 0
  fi
  pass "${label}"
}

function argv_for() {
  printf 'git\nfile://%s/\n--since-commit\n%s\n--branch\n%s\n--fail\n--no-update\n--github-actions\n--results=verified,unknown' \
    "${REPO_ROOT}" "$1" "$2"
}

# --- verify -----------------------------------------------------------------

build_release plain
write_version_file "${VERSION}\n"

SCENARIO_ARGS=(verify)
run COSIGN_EXIT=0
if expect_rc verify_happy_path 0; then
  want_out="version=${VERSION}"$'\n'"sha256=${FIXTURE_SHA}"
  cosign_args="$(cat "${COSIGN_MARKER}")"
  last_arg="${cosign_args##*$'\n'}"
  if [[ ${out} != "${want_out}" ]]; then
    fail verify_happy_path "stdout was $(printf '%q' "${out}")"
  elif [[ ${cosign_args} != verify-blob* ]] ||
    [[ ${cosign_args} != *$'\n--certificate-identity\n'"${WANT_IDENTITY}"$'\n'* ]] ||
    [[ ${cosign_args} != *$'\n--certificate-oidc-issuer\n'"${WANT_ISSUER}"$'\n'* ]] ||
    [[ ${last_arg} != */trufflehog_${VERSION}_checksums.txt ]] ||
    [[ ${cosign_args} == *insecure* ]]; then
    fail verify_happy_path "cosign argv was $(printf '%q' "${cosign_args}")"
  else
    pass verify_happy_path
  fi
fi

run COSIGN_EXIT=1
if expect_rc verify_cosign_fails 1; then
  if [[ ${out} == *sha256=* ]]; then fail verify_cosign_fails "sha256 printed"; else pass verify_cosign_fails; fi
fi

write_checksums "${FIXTURE_SHA}  other_${VERSION}_linux_arm64.tar.gz\n"
run COSIGN_EXIT=0
if expect_rc verify_rejects_missing_line 1; then pass verify_rejects_missing_line; fi

write_checksums "${FIXTURE_SHA}  ${TARBALL}\n${FIXTURE_SHA}  ${TARBALL}\n"
run COSIGN_EXIT=0
if expect_rc verify_rejects_duplicate_line 1; then pass verify_rejects_duplicate_line; fi

write_checksums "${FIXTURE_SHA}  ${TARBALL}"
run COSIGN_EXIT=0
if expect_rc verify_accepts_unterminated_final_line 0; then
  if [[ ${out} == *"sha256=${FIXTURE_SHA}" ]]; then pass verify_accepts_unterminated_final_line; else fail verify_accepts_unterminated_final_line "stdout $(printf '%q' "${out}")"; fi
fi

for bad in 'zz' "${FIXTURE_SHA:0:63}" "${FIXTURE_SHA^^}"; do
  write_checksums "${bad}  ${TARBALL}\n"
  run COSIGN_EXIT=0
  if expect_rc "verify_rejects_bad_hash_shape(${bad:0:8})" 1; then pass "verify_rejects_bad_hash_shape(${bad:0:8})"; fi
done

build_release plain
bad_versions=('3.99.4\0' '3.99.4\n3.99.4\n' '3.99.4' 'v3.99.4\n' '' '3.99\n' '3.99.4\n\n')
for bad in "${bad_versions[@]}"; do
  write_version_file "${bad}"
  run COSIGN_EXIT=0
  label="verify_rejects_version_file($(printf '%q' "${bad}"))"
  if expect_rc "${label}" 2; then
    if [[ -f ${COSIGN_MARKER} ]]; then fail "${label}" "cosign ran"; else pass "${label}"; fi
  fi
done
rm --force -- "${scratch}/version"
run COSIGN_EXIT=0
if expect_rc verify_rejects_missing_version_file 2; then pass verify_rejects_missing_version_file; fi
write_version_file "${VERSION}\n"

rm --force -- "${RELEASE_DIR}/trufflehog_${VERSION}_checksums.txt.pem"
run COSIGN_EXIT=0
if expect_rc verify_download_failure 2; then
  if [[ -f ${COSIGN_MARKER} ]]; then fail verify_download_failure "cosign ran"; else pass verify_download_failure; fi
fi

# --- scan -------------------------------------------------------------------

build_release plain
write_event '{"pull_request":{"base":{"sha":"1111111111111111111111111111111111111111"},"head":{"sha":"2222222222222222222222222222222222222222"}}}'
scan_scenario scan_pull_request_range pull_request "$(argv_for 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222)" 0

write_event '{"commits":[{"id":"x"}],"before":"3333333333333333333333333333333333333333","after":"4444444444444444444444444444444444444444"}'
scan_scenario scan_push_range push "$(argv_for 3333333333333333333333333333333333333333 4444444444444444444444444444444444444444)" 0

write_event '{"commits":[{"id":"x"}],"before":"'"${NULL_SHA}"'","after":"4444444444444444444444444444444444444444"}'
scan_scenario scan_push_zero_before push "$(argv_for '' 4444444444444444444444444444444444444444)" 0

write_event '{"commits":[],"before":"b","after":"a"}'
SCENARIO_ARGS=(scan --version "${VERSION}" --sha256 "${FIXTURE_SHA}")
run GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="${scratch}/event.json"
if expect_rc scan_push_no_commits_exits_0 0; then
  if [[ ${out} != 'No commits to scan' || -f ${MARKER} ]]; then
    fail scan_push_no_commits_exits_0 "stdout $(printf '%q' "${out}") or binary ran"
  else pass scan_push_no_commits_exits_0; fi
fi

write_event '{}'
scan_scenario scan_schedule_full schedule "$(argv_for '' '')" 0
scan_scenario scan_dispatch_full workflow_dispatch "$(argv_for '' '')" 0

for event in release '' issues; do
  SCENARIO_ARGS=(scan --version "${VERSION}" --sha256 "${FIXTURE_SHA}")
  run GITHUB_EVENT_NAME="${event}" GITHUB_EVENT_PATH="${scratch}/event.json"
  if expect_rc "scan_unknown_event_exits_2(${event:-empty})" 2; then
    if [[ -f ${MARKER} ]]; then fail "scan_unknown_event_exits_2(${event:-empty})" "binary ran"; else pass "scan_unknown_event_exits_2(${event:-empty})"; fi
  fi
done

# An unreadable or incomplete event payload exits 2 and the binary never runs.
bad_payload_cases=(
  'push|{not json'
  'pull_request|{not json'
  'push|[]'
  'pull_request|"text"'
  'pull_request|{"pull_request":null}'
  'pull_request|{}'
  'pull_request|{"pull_request":{"base":{"sha":"1111111111111111111111111111111111111111"}}}'
  'pull_request|{"pull_request":{"base":{"sha":7},"head":{"sha":"2222222222222222222222222222222222222222"}}}'
  'pull_request|{"pull_request":{"base":{"sha":"basesha"},"head":{"sha":"headsha"}}}'
  'push|{"before":"3333333333333333333333333333333333333333","after":"4444444444444444444444444444444444444444"}'
  'push|{"commits":null}'
  'push|{"commits":[{}],"before":"3333333333333333333333333333333333333333"}'
  'push|{"commits":[{}],"before":null,"after":"4444444444444444444444444444444444444444"}'
)
for case_entry in "${bad_payload_cases[@]}"; do
  event="${case_entry%%|*}"
  write_event "${case_entry#*|}"
  SCENARIO_ARGS=(scan --version "${VERSION}" --sha256 "${FIXTURE_SHA}")
  run GITHUB_EVENT_NAME="${event}" GITHUB_EVENT_PATH="${scratch}/event.json"
  label="scan_rejects_bad_payload(${case_entry:0:60})"
  if expect_rc "${label}" 2; then
    if [[ -f ${MARKER} ]]; then fail "${label}" "binary ran"; else pass "${label}"; fi
  fi
done
write_event '{}'

# A stable nonzero finding status propagates.
write_event '{}'
STUB_EXIT_FOR=183 scan_scenario scan_propagates_finding schedule "$(argv_for '' '')" 183

# Digest mismatch: the binary must never run.
SCENARIO_ARGS=(scan --version "${VERSION}" --sha256 "$(printf '%064d' 7)")
run GITHUB_EVENT_NAME=schedule GITHUB_EVENT_PATH="${scratch}/event.json"
if expect_rc scan_hash_mismatch 1; then
  if [[ -f ${MARKER} ]]; then fail scan_hash_mismatch "binary ran"; else pass scan_hash_mismatch; fi
fi

# Malformed arguments exit 2 before any download: remove the release tree.
mv "${scratch}/release" "${scratch}/release.hidden"
for args in \
  "--version ${VERSION} --sha256 zz" \
  "--version ${VERSION} --sha256 ${FIXTURE_SHA^^}" \
  "--version v${VERSION} --sha256 ${FIXTURE_SHA}" \
  "--version 3.99 --sha256 ${FIXTURE_SHA}" \
  "--version ${VERSION}" \
  "--sha256 ${FIXTURE_SHA}"; do
  read -r -a SCENARIO_ARGS <<<"scan ${args}"
  run GITHUB_EVENT_NAME=schedule GITHUB_EVENT_PATH="${scratch}/event.json"
  if expect_rc "scan_rejects_malformed_args(${args:0:30})" 2; then
    if [[ ${err} == *'cannot download'* || -f ${MARKER} ]]; then
      fail "scan_rejects_malformed_args(${args:0:30})" "download attempted or binary ran"
    else pass "scan_rejects_malformed_args(${args:0:30})"; fi
  fi
done
mv "${scratch}/release.hidden" "${scratch}/release"

# Archive extraction: only the top-level trufflehog runs.
build_release extras
scan_scenario scan_extracts_only_binary schedule "$(argv_for '' '')" 0
if [[ -f ${MARKER} && "$(<"${MARKER}")" == *EVIL_RAN* ]]; then fail scan_extracts_only_binary "evil ran"; fi
# Nothing but the binary may sit next to it after extraction.
if [[ ! -f ${MARKER}.listing || "$(<"${MARKER}.listing")" != trufflehog ]]; then
  fail scan_extracts_only_binary "extraction directory held $(cat "${MARKER}.listing" 2>/dev/null | tr '\n' ' ')"
fi

build_release nobin
SCENARIO_ARGS=(scan --version "${VERSION}" --sha256 "${FIXTURE_SHA}")
run GITHUB_EVENT_NAME=schedule GITHUB_EVENT_PATH="${scratch}/event.json"
if expect_rc scan_rejects_missing_top_level_binary 1; then
  if [[ -f ${MARKER} ]]; then fail scan_rejects_missing_top_level_binary "a binary ran"; else pass scan_rejects_missing_top_level_binary; fi
fi
build_release plain

build_release symlink
SCENARIO_ARGS=(scan --version "${VERSION}" --sha256 "${FIXTURE_SHA}")
run GITHUB_EVENT_NAME=schedule GITHUB_EVENT_PATH="${scratch}/event.json"
if expect_rc scan_rejects_symlink_binary 1; then
  if [[ -f ${MARKER} ]]; then fail scan_rejects_symlink_binary "binary ran"; else pass scan_rejects_symlink_binary; fi
fi

# --- workflow shape ---------------------------------------------------------

# The job that executes the binary must never skip on a failed verify (a
# skipped required check passes), must keep GitHub-only egress with sudo
# and containers disabled, and no step may name a secret or the job token,
# in dot or bracket form, in any letter case, or serialize the whole
# `github` or `secrets` context; notify must see both jobs. Each query must print
# `true` against the real workflow.
readonly WORKFLOW="${REPO_ROOT}/.github/workflows/trufflehog.yml"
readonly HARDEN_SEL='.jobs.trufflehog.steps[] | select(.uses // "" | test("^step-security/harden-runner@"))'
# shellcheck disable=SC2016 # a GitHub Actions expression, not a shell one
shape_checks=(
  'scan_needs_verify|[.jobs.trufflehog.needs] | flatten | any_c(. == "trufflehog-verify")'
  'scan_if_always|.jobs.trufflehog.if == "always()"'
  'scan_harden_runner_first|.jobs.trufflehog.steps[0].uses // "" | test("^step-security/harden-runner@")'
  'scan_egress_block|['"${HARDEN_SEL}"' | .with."egress-policy" == "block"] | (length == 1 and all)'
  'scan_sudo_and_containers_disabled|['"${HARDEN_SEL}"' | .with."disable-sudo-and-containers" | tostring == "true"] | (length == 1 and all)'
  'scan_endpoints_github_only|['"${HARDEN_SEL}"' | .with."allowed-endpoints" // "" | sub("\\s+"; " ") | split(" ") | .[] | select(. != "") | select(test("^([a-z0-9-]+\\.)*(github\\.com|githubusercontent\\.com):443$") | not)] | length == 0'
  'scan_endpoints_present|['"${HARDEN_SEL}"' | .with."allowed-endpoints" // "" | sub("\\s+"; " ") | split(" ") | .[] | select(. != "")] | length > 0'
  'no_trufflehog_action|[.. | select(kind == "map") | select(has("uses")) | .uses | select(test("(?i)^trufflesecurity/trufflehog"))] | length == 0'
  'scan_holds_no_token|[.jobs.trufflehog | .. | select(kind == "scalar") | select(tag == "!!str") | select(test("(?i)secrets[.\\[]|github(\\.token|\\[)|tojson\\(\\s*(github|secrets)\\s*\\)"))] | length == 0'
  'scan_gates_on_verify_result|.jobs.trufflehog.steps[1].env.VERIFY_RESULT == "${{ needs.trufflehog-verify.result }}" and (.jobs.trufflehog.steps[1].run | test("VERIFY_RESULT\\} != .success.")) and (.jobs.trufflehog.steps[1].if == null)'
  'notify_needs_both|[.jobs.notify.needs] | flatten | (any_c(. == "trufflehog-verify") and any_c(. == "trufflehog"))'
  'verify_runs_release_script|[.jobs."trufflehog-verify".steps[].run // "" | select(test("scripts/trufflehog-release\\.sh verify"))] | length == 1'
  'scan_runs_release_script|[.jobs.trufflehog.steps[].run // "" | select(test("scripts/trufflehog-release\\.sh scan"))] | length == 1'
)
for entry in "${shape_checks[@]}"; do
  label="workflow_shape(${entry%%|*})"
  got="$(yq --unwrapScalar "${entry#*|}" "${WORKFLOW}" 2>&1)" || got="yq failed: ${got}"
  if [[ ${got} == true ]]; then pass "${label}"; else fail "${label}" "query gave $(printf '%q' "${got}")"; fi
done

# notify's combined result: success only when both jobs succeeded; a
# cancelled verification, or a cancelled scan after a verified release, is
# `cancelled`; anything else fails.
combine_run="$(yq '.jobs.notify.steps[] | select(.id == "combined") | .run' "${WORKFLOW}")"
notify_cases=(
  'success success success'
  'success failure failure'
  'failure failure failure'
  'failure success failure'
  'skipped success failure'
  'success skipped failure'
  'cancelled failure cancelled'
  'failure cancelled failure'
  'cancelled cancelled cancelled'
  'success cancelled cancelled'
  'cancelled success cancelled'
  'skipped cancelled failure'
  'skipped skipped failure'
  'success unknown failure'
)
for case_entry in "${notify_cases[@]}"; do
  IFS=' ' read -r verify_result scan_result want <<<"${case_entry}"
  label="workflow_shape(notify_result ${verify_result}+${scan_result})"
  : >"${scratch}/gh-output"
  rc=0
  VERIFY_RESULT="${verify_result}" SCAN_RESULT="${scan_result}" GITHUB_OUTPUT="${scratch}/gh-output" \
    bash -c "${combine_run}" >/dev/null 2>&1 || rc=$?
  got="$(<"${scratch}/gh-output")"
  if [[ ${rc} == 0 && ${got} == "result=${want}" ]]; then pass "${label}"; else fail "${label}" "exit ${rc}, output $(printf '%q' "${got}"), want result=${want}"; fi
done

exit "${failures}"
