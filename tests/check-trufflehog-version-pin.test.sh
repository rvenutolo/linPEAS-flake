#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-trufflehog-version-pin.sh"
readonly SHA='0123456789abcdef0123456789abcdef01234567'
readonly GOOD_VERSION=$'3.99.4\n'
# Version-file contents a scenario passes to leave the file out, or to
# write the valid line followed by a NUL and more bytes (a shell variable
# cannot hold NUL).
readonly ABSENT='<absent>'
readonly NUL_PADDED='<nul-padded>'

# The two invocations trufflehog.yml must carry, as its jobs write them.
# shellcheck disable=SC2016 # shell text for the generated workflow, not for this shell
readonly VERIFY_RUN='nix shell .#cosign --command bash scripts/trufflehog-release.sh verify >> "${GITHUB_OUTPUT}"'
# shellcheck disable=SC2016 # shell text for the generated workflow, not for this shell
readonly SCAN_RUN='bash scripts/trufflehog-release.sh scan --version "${VERSION}" --sha256 "${SHA256}"'

failures=0

# @description A trufflehog.yml body with one step per job.
# @arg $1 the verify job's `run:` text  @arg $2 the scan job's `run:` text
# @arg $3 extra step lines appended to the scan job, already indented
function workflow() {
  printf 'on: push\njobs:\n  trufflehog-verify:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          %s\n  trufflehog:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          %s\n%s' \
    "$1" "$2" "${3:-}"
}

GOOD_WORKFLOW="$(workflow "${VERIFY_RUN}" "${SCAN_RUN}")"$'\n'
readonly GOOD_WORKFLOW
readonly OTHER_WORKFLOW=$'on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@'"${SHA}"$' # v7.0.1\n'
readonly ACTION_STEP="      - uses: trufflesecurity/trufflehog@${SHA} # v3.99.4"$'\n'

# @description Run the lint over a tree built in a temp dir at run time,
# so no workflow-shaped fixture is a tracked file a formatter or workflow
# linter reads, and compare its exit status and the whole of stderr.
# @arg $1 scenario label
# @arg $2 trufflehog.yml body, or ABSENT
# @arg $3 version file content, ABSENT or NUL_PADDED
# @arg $4 expected exit status
# @arg $5 expected stderr, with DIR standing for the temp dir
# @arg $@ extra files as `relative/path=body` pairs under the scan dir
function expect() {
  local -r name="$1" body="$2" version="$3" want_exit="$4" want_raw="$5"
  shift 5
  local dir got_exit=0 got_stderr want extra rel
  dir="$(mktemp --directory)"
  mkdir -- "${dir}/wf"
  if [[ ${body} != "${ABSENT}" ]]; then
    printf '%s' "${body}" >"${dir}/wf/trufflehog.yml"
  fi
  for extra in "$@"; do
    rel="${extra%%=*}"
    if [[ ${rel} == */* ]]; then mkdir --parents -- "${dir}/wf/${rel%/*}"; fi
    printf '%s' "${extra#*=}" >"${dir}/wf/${rel}"
  done
  if [[ ${version} == "${NUL_PADDED}" ]]; then
    printf '%s\0trailing' "${GOOD_VERSION}" >"${dir}/version"
  elif [[ ${version} != "${ABSENT}" ]]; then
    printf '%s' "${version}" >"${dir}/version"
  fi
  want="${want_raw//DIR/${dir}}"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}/wf" \
    TRUFFLEHOG_VERSION_FILE_OVERRIDE="${dir}/version" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s, and stderr %q\n  got: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${want}" "${got_stderr}" >&2
    failures=$((failures + 1))
    return 0
  fi
  printf 'OK   %s\n' "${name}"
}

# @description The stderr a list of findings produces, with its count line.
# @arg $@ the finding lines
function findings() {
  printf '%s\n' "$@"
  printf '%d trufflehog version pin finding(s)' "$#"
}

# @description The finding a malformed version file produces.
# @arg $1 the file's content
function bad_shape() {
  printf 'DIR/version: holds %q; want one line X.Y.Z' "$1"
}

# @description The finding a reintroduced action reference produces.
# @arg $1 file path under the scan dir  @arg $2 the reference
function action_use() {
  printf 'DIR/wf/%s: uses %q; run the signed release binary through scripts/trufflehog-release.sh instead' "$1" "$2"
}

readonly NO_VERIFY='DIR/wf/trufflehog.yml: no step runs scripts/trufflehog-release.sh verify'
readonly NO_SCAN='DIR/wf/trufflehog.yml: no step runs scripts/trufflehog-release.sh scan'

# The live-shaped tree passes: a one-line version file, no action, and
# both invocations in trufflehog.yml, beside an unrelated workflow.
expect live-shaped "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 0 '' "other.yml=${OTHER_WORKFLOW}"

# The upstream action is rejected wherever a `uses:` names it: in
# trufflehog.yml, in another workflow, in a composite action, re-cased,
# or through an alias.
expect action-in-trufflehog-yml "$(workflow "${VERIFY_RUN}" "${SCAN_RUN}" "${ACTION_STEP}")" "${GOOD_VERSION}" 1 \
  "$(findings "$(action_use trufflehog.yml "trufflesecurity/trufflehog@${SHA}")")"
expect action-in-other-workflow "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 1 \
  "$(findings "$(action_use other.yml "trufflesecurity/trufflehog@${SHA}")")" \
  "other.yml=${OTHER_WORKFLOW}${ACTION_STEP}"
expect action-in-composite "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 1 \
  "$(findings "$(action_use actions/scan/action.yml "trufflesecurity/trufflehog@${SHA}")")" \
  "actions/scan/action.yml=runs:
  using: composite
  steps:
    - uses: trufflesecurity/trufflehog@${SHA}
"
expect action-recased "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 1 \
  "$(findings "$(action_use other.yml "TruffleSecurity/TruffleHog@${SHA}")")" \
  "other.yml=${OTHER_WORKFLOW}      - uses: TruffleSecurity/TruffleHog@${SHA}
"
expect action-aliased "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 1 \
  "$(findings "$(action_use other.yml "trufflesecurity/trufflehog@${SHA}")")" \
  "other.yml=x-ref: &th trufflesecurity/trufflehog@${SHA}
${OTHER_WORKFLOW}      - uses: *th
"
expect action-subpath "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 1 \
  "$(findings "$(action_use other.yml "trufflesecurity/trufflehog/sub@${SHA}")")" \
  "other.yml=${OTHER_WORKFLOW}      - uses: trufflesecurity/trufflehog/sub@${SHA}
"
expect action-flow-style "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 1 \
  "$(findings "$(action_use other.yml "trufflesecurity/trufflehog@${SHA}")")" \
  "other.yml=on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ uses: trufflesecurity/trufflehog@${SHA} }]
"
# A `docker://` reference runs upstream's unsigned image directly, from
# ghcr.io or from Docker Hub, by tag or by digest.
expect docker-ghcr "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 1 \
  "$(findings "$(action_use other.yml 'docker://ghcr.io/trufflesecurity/trufflehog:latest')")" \
  "other.yml=${OTHER_WORKFLOW}      - uses: docker://ghcr.io/trufflesecurity/trufflehog:latest
"
expect docker-hub "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 1 \
  "$(findings "$(action_use other.yml 'docker://trufflesecurity/trufflehog:3')")" \
  "other.yml=${OTHER_WORKFLOW}      - uses: docker://trufflesecurity/trufflehog:3
"
expect docker-digest-recased "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 1 \
  "$(findings "$(action_use other.yml "docker://GHCR.io/TruffleSecurity/TruffleHog@sha256:${SHA}${SHA:0:24}")")" \
  "other.yml=${OTHER_WORKFLOW}      - uses: docker://GHCR.io/TruffleSecurity/TruffleHog@sha256:${SHA}${SHA:0:24}
"
# Another image whose name only starts with the repository name is not
# this one.
expect docker-other-image "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 0 '' \
  "other.yml=${OTHER_WORKFLOW}      - uses: docker://ghcr.io/trufflesecurity/trufflehog-extra:1
"
# A reference whose path only starts with the repository name is another
# action, not this one.
expect other-action-prefix "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 0 '' \
  "other.yml=${OTHER_WORKFLOW}      - uses: trufflesecurity/trufflehog-extra@${SHA}
"

# The version file must be exactly one X.Y.Z line, final newline included.
expect version-v-prefix "${GOOD_WORKFLOW}" $'v3.99.4\n' 1 "$(findings "$(bad_shape $'v3.99.4\n')")"
expect version-two-lines "${GOOD_WORKFLOW}" "${GOOD_VERSION}${GOOD_VERSION}" 1 \
  "$(findings "$(bad_shape "${GOOD_VERSION}${GOOD_VERSION}")")"
expect version-no-final-newline "${GOOD_WORKFLOW}" '3.99.4' 1 "$(findings "$(bad_shape '3.99.4')")"
expect version-two-parts "${GOOD_WORKFLOW}" $'3.99\n' 1 "$(findings "$(bad_shape $'3.99\n')")"
expect version-latest "${GOOD_WORKFLOW}" $'latest\n' 1 "$(findings "$(bad_shape $'latest\n')")"
expect version-nul-padded "${GOOD_WORKFLOW}" "${NUL_PADDED}" 1 \
  "$(findings 'DIR/version: holds a NUL byte; want one line X.Y.Z')"

# trufflehog.yml must run the release script in both forms. A commented-
# out line runs nothing, so it does not count.
expect no-scan-invocation "$(workflow "${VERIFY_RUN}" 'echo scanning')" "${GOOD_VERSION}" 1 \
  "$(findings "${NO_SCAN}")"
expect no-verify-invocation "$(workflow 'echo verifying' "${SCAN_RUN}")" "${GOOD_VERSION}" 1 \
  "$(findings "${NO_VERIFY}")"
expect commented-scan "$(workflow "${VERIFY_RUN}" "# ${SCAN_RUN}")" "${GOOD_VERSION}" 1 \
  "$(findings "${NO_SCAN}")"
expect neither-invocation "$(workflow 'true' 'true')" "${GOOD_VERSION}" 1 \
  "$(findings "${NO_VERIFY}" "${NO_SCAN}")"
# Every finding is reported, not only the first.
expect all-findings "$(workflow 'true' "${SCAN_RUN}" "${ACTION_STEP}")" $'v3.99.4\n' 1 \
  "$(findings "$(bad_shape $'v3.99.4\n')" \
    "$(action_use trufflehog.yml "trufflesecurity/trufflehog@${SHA}")" "${NO_VERIFY}")"

# A missing input is a could-not-run.
expect version-missing "${GOOD_WORKFLOW}" "${ABSENT}" 2 \
  'DIR/version: missing or unreadable; scripts/trufflehog-release.sh reads the pinned version from it'
expect workflow-missing "${ABSENT}" "${GOOD_VERSION}" 2 \
  'DIR/wf/trufflehog.yml: missing; it runs the TruffleHog scan' "other.yml=${OTHER_WORKFLOW}"
# A scanned file yq cannot parse is a finding, and the scan goes on to
# report the other files' findings.
expect unparsable-workflow "${GOOD_WORKFLOW}" "${GOOD_VERSION}" 1 \
  "$(findings 'DIR/wf/broken.yml: yq parse failed; the TruffleHog version pin cannot be verified' \
    "$(action_use other.yml "trufflesecurity/trufflehog@${SHA}")")" \
  $'broken.yml=on: push\njobs:\n  a: [\n' "other.yml=${OTHER_WORKFLOW}${ACTION_STEP}"
# An unparsable trufflehog.yml is reported once, not again as missing both
# invocations.
expect unparsable-trufflehog-yml $'on: push\njobs:\n  a: [\n' "${GOOD_VERSION}" 1 \
  "$(findings 'DIR/wf/trufflehog.yml: yq parse failed; the TruffleHog version pin cannot be verified')"

# The live tree passes.
live_exit=0
live_err="$(cd -- "${REPO_ROOT}" && "${SCRIPT}" 2>&1 >/dev/null)" || live_exit=$?
if [[ ${live_exit} != 0 || -n ${live_err} ]]; then
  printf 'FAIL live-tree: exit %s (want 0)\n  stderr: %s\n' "${live_exit}" "${live_err}" >&2
  failures=$((failures + 1))
else
  printf 'OK   live tree\n'
fi

# An empty scan set and a missing yq are could-not-run, exit 2.
empty_dir="$(mktemp --directory)"
empty_exit=0
empty_err="$(env --unset=LINT_ALLOW_EMPTY_SCAN WORKFLOWS_DIR_OVERRIDE="${empty_dir}" \
  "${SCRIPT}" 2>&1 >/dev/null)" || empty_exit=$?
rm --recursive --force -- "${empty_dir}"
if [[ ${empty_exit} != 2 || ${empty_err} != *'matched 0 files'* ]]; then
  printf 'FAIL empty-scan: exit %s (want 2)\n  stderr: %s\n' "${empty_exit}" "${empty_err}" >&2
  failures=$((failures + 1))
else
  printf 'OK   empty scan set exits tooling code\n'
fi

bash_abs="$(command -v bash)"
noyq_exit=0
noyq_err="$(env --unset=BASH_ENV PATH=/nonexistent \
  "${bash_abs}" "${SCRIPT}" 2>&1 >/dev/null)" || noyq_exit=$?
if [[ ${noyq_exit} != 2 || ${noyq_err} != *'yq'* ]]; then
  printf 'FAIL yq-absent: exit %s (want 2)\n  stderr: %s\n' "${noyq_exit}" "${noyq_err}" >&2
  failures=$((failures + 1))
else
  printf 'OK   yq absent exits tooling code\n'
fi

if ((failures > 0)); then
  printf '%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'all tests passed\n'
