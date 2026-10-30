#!/usr/bin/env bash
# tests/refresh-trufflehog-image.test.sh
#
# Resolve + drift harness for scripts/refresh-trufflehog-image.sh. A
# `curl` stub sits first on PATH and answers from files each scenario
# writes, so no scenario reaches the network; each scenario's workflow
# and image file live in its own directory, so the checkout is only read.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-trufflehog-image.sh"

readonly SHA='0123456789abcdef0123456789abcdef01234567'
readonly OLD_DIGEST='sha256:00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'
readonly NEW_DIGEST='sha256:ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100'

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

work="$(mktemp --directory)"
function cleanup() {
  rm --recursive --force -- "${work}"
}
trap cleanup EXIT

# The stub answers a token request with <case>/token.body and exit
# <case>/token.rc, and a manifest request with <case>/manifest.out and
# exit <case>/manifest.rc. Every call's arguments are appended to
# <case>/curl.log, one argument per line and a `--` line after each call.
readonly STUB_DIR="${work}/stub"
mkdir -- "${STUB_DIR}"
cat >"${STUB_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" -- >>"${STUB_CASE}/curl.log"
url="${*: -1}"
case "${url}" in
  https://ghcr.io/token\?*) kind=token ;;
  https://ghcr.io/v2/*/manifests/*) kind=manifest ;;
  *)
    printf 'stub curl: unexpected URL %s\n' "${url}" >&2
    exit 99
    ;;
esac
if [[ -f ${STUB_CASE}/${kind}.body ]]; then cat -- "${STUB_CASE}/${kind}.body"; fi
if [[ -f ${STUB_CASE}/${kind}.out ]]; then cat -- "${STUB_CASE}/${kind}.out"; fi
exit "$(cat -- "${STUB_CASE}/${kind}.rc" 2>/dev/null || printf 0)"
EOF
chmod +x -- "${STUB_DIR}/curl"

# A registry answer naming one digest, CRLF line ends as HTTP sends them.
# @arg $1 the Docker-Content-Digest value
function manifest_headers() {
  printf 'HTTP/2 200 \r\ncontent-type: application/vnd.docker.distribution.manifest.list.v2+json\r\ndocker-content-digest: %s\r\netag: "%s"\r\n\r\n' "$1" "$1"
}

# @description Create a scenario directory: a one-step workflow pinned at
# the given release, an image file, and registry answers naming NEW_DIGEST.
# @arg $1 scenario name  @arg $2 pin comment version
# @arg $3 image file content, or `<absent>`
# @stdout the scenario directory
function new_case() {
  local -r dir="${work}/$1"
  mkdir -- "${dir}"
  printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: trufflesecurity/trufflehog@%s # v%s\n' \
    "${SHA}" "$2" >"${dir}/trufflehog.yml"
  if [[ $3 != '<absent>' ]]; then printf '%s' "$3" >"${dir}/image"; fi
  printf '{"token":"stub-token"}' >"${dir}/token.body"
  manifest_headers "${NEW_DIGEST}" >"${dir}/manifest.out"
  printf '%s' "${dir}"
}

gen_rc=0
# @description Run the generator on a scenario directory and record it
# with the discrimination gate.
# @arg $1 scenario directory  @arg $2 scenario name  @arg $3 asserted substring
# @arg $@ generator arguments
function run_gen() {
  local -r dir="$1" name="$2" expect="$3"
  shift 3
  gen_rc=0
  STUB_CASE="${dir}" PATH="${STUB_DIR}:${PATH}" \
    TRUFFLEHOG_WORKFLOW_OVERRIDE="${dir}/trufflehog.yml" \
    TRUFFLEHOG_IMAGE_FILE_OVERRIDE="${dir}/image" \
    "${SCRIPT}" "$@" >"${dir}/out" 2>"${dir}/err" || gen_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${gen_rc}" >"${dir}/outcome"
  harness_assert_record "${name}" "${expect}" "${dir}/outcome" "${dir}/out" "${dir}/err"
}

# @description Assert the exit status, a substring of stdout+stderr, and
# the image file's bytes afterwards.
# @arg $1 scenario directory  @arg $2 scenario name  @arg $3 expected exit
# @arg $4 asserted substring  @arg $5 expected image content, or `<absent>`
function check() {
  local -r dir="$1" name="$2" want_exit="$3" want_msg="$4" want_image="$5"
  local got_image='<absent>' output
  if [[ -f ${dir}/image ]]; then
    IFS= read -r -d '' got_image <"${dir}/image" || true
  fi
  output="$(cat -- "${dir}/out" "${dir}/err")"
  if [[ ${gen_rc} != "${want_exit}" ]]; then
    fail "${name}: exit ${gen_rc}, want ${want_exit}: ${output}"
  elif [[ ${output} != *"${want_msg}"* ]]; then
    fail "${name}: output lacks $(printf '%q' "${want_msg}"): ${output}"
  elif [[ ${got_image} != "${want_image}" ]]; then
    fail "${name}: image file holds $(printf '%q' "${got_image}"), want $(printf '%q' "${want_image}")"
  else
    pass "${name} (exit ${gen_rc})"
  fi
}

readonly OLD_IMAGE="3.99.4@${OLD_DIGEST}"$'\n'
readonly NEW_IMAGE="3.99.5@${NEW_DIGEST}"$'\n'

# A bumped pin with the file still on the old release: --check reports
# it stale and leaves the file alone, and the write mode resolves the
# new release's digest and writes it.
dir="$(new_case check-stale 3.99.5 "${OLD_IMAGE}")"
run_gen "${dir}" check-stale "is stale: it holds 3.99.4@${OLD_DIGEST}; it should hold 3.99.5@" --check
check "${dir}" check-stale 1 "is stale: it holds 3.99.4@${OLD_DIGEST}; it should hold 3.99.5@" "${OLD_IMAGE}"

dir="$(new_case write-stale 3.99.5 "${OLD_IMAGE}")"
run_gen "${dir}" write-stale "wrote 3.99.5@${NEW_DIGEST} to ${dir}/image"
check "${dir}" write-stale 0 "wrote 3.99.5@${NEW_DIGEST} to ${dir}/image" "${NEW_IMAGE}"

# The registry requests: an anonymous pull token scoped to the image,
# then the manifest of the pin's tag (no `v`), asking for an index or
# manifest list first and sending the token.
log="$(cat -- "${dir}/curl.log" 2>/dev/null)" || log=''
if [[ ${log} == *$'https://ghcr.io/token?scope=repository:trufflesecurity/trufflehog:pull&service=ghcr.io\n--'* &&
  ${log} == *$'Authorization: Bearer stub-token\n'* &&
  ${log} == *'Accept: application/vnd.oci.image.index.v1+json'* &&
  ${log} == *$'https://ghcr.io/v2/trufflesecurity/trufflehog/manifests/3.99.5\n--'* ]]; then
  pass 'write-stale: requests the scoped token and the pin tag manifest'
else
  fail "write-stale: unexpected registry requests: ${log}"
fi

# A file already naming the resolved ref is current in both modes.
dir="$(new_case check-current 3.99.5 "${NEW_IMAGE}")"
run_gen "${dir}" check-current "${dir}/image is current: 3.99.5@${NEW_DIGEST}" --check
check "${dir}" check-current 0 "${dir}/image is current: 3.99.5@${NEW_DIGEST}" "${NEW_IMAGE}"

# The same release with a different digest (a repointed tag) is stale.
dir="$(new_case check-repointed 3.99.5 "3.99.5@${OLD_DIGEST}"$'\n')"
run_gen "${dir}" check-repointed "it holds 3.99.5@${OLD_DIGEST}; it should hold 3.99.5@${NEW_DIGEST}" --check
check "${dir}" check-repointed 1 "it holds 3.99.5@${OLD_DIGEST}; it should hold 3.99.5@${NEW_DIGEST}" "3.99.5@${OLD_DIGEST}"$'\n'

# An absent file is stale under --check and created by the write mode.
dir="$(new_case check-absent 3.99.5 '<absent>')"
run_gen "${dir}" check-absent 'is missing; it should hold 3.99.5@' --check
check "${dir}" check-absent 1 'is missing; it should hold 3.99.5@' '<absent>'

dir="$(new_case write-absent 3.99.5 '<absent>')"
run_gen "${dir}" write-absent "wrote 3.99.5@${NEW_DIGEST} to ${dir}/image"
check "${dir}" write-absent 0 "wrote 3.99.5@${NEW_DIGEST} to ${dir}/image" "${NEW_IMAGE}"

# Every way the run cannot produce a trustworthy ref exits 2 and leaves
# the file as it was.
dir="$(new_case token-fails 3.99.5 "${OLD_IMAGE}")"
printf '22' >"${dir}/token.rc"
run_gen "${dir}" token-fails 'could not get a pull token from ghcr.io'
check "${dir}" token-fails 2 'could not get a pull token from ghcr.io' "${OLD_IMAGE}"

dir="$(new_case token-malformed 3.99.5 "${OLD_IMAGE}")"
printf '{"nope":1}' >"${dir}/token.body"
run_gen "${dir}" token-malformed 'ghcr.io answered the token request without a token'
check "${dir}" token-malformed 2 'ghcr.io answered the token request without a token' "${OLD_IMAGE}"

dir="$(new_case manifest-fails 3.99.5 "${OLD_IMAGE}")"
printf '22' >"${dir}/manifest.rc"
run_gen "${dir}" manifest-fails 'could not read the manifest of trufflesecurity/trufflehog:3.99.5'
check "${dir}" manifest-fails 2 'could not read the manifest of trufflesecurity/trufflehog:3.99.5' "${OLD_IMAGE}"

dir="$(new_case digest-absent 3.99.5 "${OLD_IMAGE}")"
printf 'HTTP/2 200 \r\ncontent-type: text/plain\r\n\r\n' >"${dir}/manifest.out"
run_gen "${dir}" digest-absent 'ghcr.io named 0 Docker-Content-Digest header(s) for 3.99.5; want one'
check "${dir}" digest-absent 2 'ghcr.io named 0 Docker-Content-Digest header(s) for 3.99.5; want one' "${OLD_IMAGE}"

dir="$(new_case digest-twice 3.99.5 "${OLD_IMAGE}")"
{
  manifest_headers "${NEW_DIGEST}"
  manifest_headers "${OLD_DIGEST}"
} >"${dir}/manifest.out"
run_gen "${dir}" digest-twice 'ghcr.io named 2 Docker-Content-Digest header(s) for 3.99.5; want one'
check "${dir}" digest-twice 2 'ghcr.io named 2 Docker-Content-Digest header(s) for 3.99.5; want one' "${OLD_IMAGE}"

dir="$(new_case digest-malformed 3.99.5 "${OLD_IMAGE}")"
manifest_headers 'sha256:abc' >"${dir}/manifest.out"
run_gen "${dir}" digest-malformed "ghcr.io answered digest sha256:abc for 3.99.5"
check "${dir}" digest-malformed 2 "ghcr.io answered digest sha256:abc for 3.99.5" "${OLD_IMAGE}"

# The header name matches in any letter case, as HTTP header names do.
dir="$(new_case digest-recased 3.99.5 "${OLD_IMAGE}")"
manifest_headers "${NEW_DIGEST}" | sed --expression='s/^docker-content-digest:/Docker-Content-Digest:/' >"${dir}/manifest.out"
run_gen "${dir}" digest-recased "wrote 3.99.5@${NEW_DIGEST} to ${dir}/image"
check "${dir}" digest-recased 0 "wrote 3.99.5@${NEW_DIGEST} to ${dir}/image" "${NEW_IMAGE}"

# The workflow must name one release: no pinned step, a step with no pin
# comment, and two steps on different releases are each a could-not-run.
dir="$(new_case no-step 3.99.5 "${OLD_IMAGE}")"
printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@%s # v7.0.1\n' "${SHA}" >"${dir}/trufflehog.yml"
run_gen "${dir}" no-step 'names no trufflesecurity/trufflehog step'
check "${dir}" no-step 2 'names no trufflesecurity/trufflehog step' "${OLD_IMAGE}"

dir="$(new_case no-comment 3.99.5 "${OLD_IMAGE}")"
printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: trufflesecurity/trufflehog@%s\n' "${SHA}" >"${dir}/trufflehog.yml"
run_gen "${dir}" no-comment 'has a trufflesecurity/trufflehog step with no # vX.Y.Z pin comment'
check "${dir}" no-comment 2 'has a trufflesecurity/trufflehog step with no # vX.Y.Z pin comment' "${OLD_IMAGE}"

dir="$(new_case two-releases 3.99.5 "${OLD_IMAGE}")"
printf '      - uses: trufflesecurity/trufflehog@%s # v3.99.6\n' "${SHA}" >>"${dir}/trufflehog.yml"
run_gen "${dir}" two-releases 'pins trufflesecurity/trufflehog at more than one release: 3.99.5 3.99.6'
check "${dir}" two-releases 2 'pins trufflesecurity/trufflehog at more than one release: 3.99.5 3.99.6' "${OLD_IMAGE}"

dir="$(new_case workflow-absent 3.99.5 "${OLD_IMAGE}")"
rm --force -- "${work}/workflow-absent/trufflehog.yml"
run_gen "${dir}" workflow-absent 'trufflehog.yml not found'
check "${dir}" workflow-absent 2 'trufflehog.yml not found' "${OLD_IMAGE}"

dir="$(new_case unknown-arg 3.99.5 "${OLD_IMAGE}")"
run_gen "${dir}" unknown-arg 'unknown arg: --bogus' --bogus
check "${dir}" unknown-arg 2 'unknown arg: --bogus' "${OLD_IMAGE}"

# The workflow's pin is read as the live file writes it: the live
# trufflehog.yml resolves to the release the live image file names.
dir="${work}/live-release"
mkdir -- "${dir}"
cp -- "${REPO_ROOT}/.github/workflows/trufflehog.yml" "${dir}/trufflehog.yml"
cp -- "${REPO_ROOT}/.github/trufflehog-image" "${dir}/image"
live_ref="$(cat -- "${dir}/image")"
printf '{"token":"stub-token"}' >"${dir}/token.body"
manifest_headers "${live_ref#*@}" >"${dir}/manifest.out"
run_gen "${dir}" live-release "${dir}/image is current: ${live_ref}" --check
check "${dir}" live-release 0 "${dir}/image is current: ${live_ref}" "${live_ref}"$'\n'

harness_assert_verify || failures=$((failures + 1))

if ((failures > 0)); then
  printf '%d failure(s)\n' "${failures}" >&2
  exit 1
fi
printf 'all passed\n'
