#!/usr/bin/env bash
# tests/bump-linpeas.test.sh — proves scripts/bump-linpeas.sh's pin-file
# and upstream-release payload reads are shape-gated to a could-not-run
# (exit 2, source named by kind), never the raw `jq` crash or the
# exit-1/exit-0 misreads an unguarded read used to produce.
#
# bump-linpeas.sh downloads a release asset and rewrites linpeas-pin.json
# on any run that reaches its happy path, so every scenario here stubs
# `gh` on PATH ahead of the real binary — no scenario ever calls the
# network — and asserts the pin fixture is byte-identical afterward, as
# its own proof that no scenario reached the download/rewrite tail.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/bump-linpeas.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/bump-linpeas"

failures=0
passes=0

# @description Write a `gh` stub to stub_dir/gh that ignores its
# arguments and emits the given fixture's content verbatim — the same
# thing a live `gh api` call would emit for a malformed or well-formed
# upstream response.
# @arg $1 stub directory (already created)
# @arg $2 fixture path whose content the stub emits
function write_gh_stub() {
  local -r stub_dir="$1" fixture="$2"
  printf '#!/usr/bin/env bash\ncat -- %q\n' "${fixture}" >"${stub_dir}/gh"
  chmod +x "${stub_dir}/gh"
}

# @description Run one scenario: stub `gh` to emit release_fixture, point
# PIN_FILE_OVERRIDE at pin_fixture, run the script, and record the
# outcome. Asserts the pin fixture was not modified first — the
# discriminator for whether this run stayed inside the gate — then the
# exit code, then the stderr substring.
# @arg $1 scenario name
# @arg $2 pin fixture (under FIXTURES)
# @arg $3 release fixture (under FIXTURES) — the stubbed `gh` emits this
# @arg $4 expected exit code
# @arg $5 expected stderr substring
function run_scenario() {
  local -r name="$1" pin_fixture="$2" release_fixture="$3" \
    want_exit="$4" substring="$5"
  local -r pin_path="${FIXTURES}/${pin_fixture}"
  local -r release_path="${FIXTURES}/${release_fixture}"
  local stub_dir stdout_file stderr_file outcome_file pin_before pin_after
  stub_dir="$(mktemp --directory)"
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"
  write_gh_stub "${stub_dir}" "${release_path}"
  pin_before="$(cat -- "${pin_path}")"

  local rc=0
  PATH="${stub_dir}:${PATH}" \
    PIN_FILE_OVERRIDE="${pin_path}" \
    bash "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome_file}"
  harness_assert_record "${name}" "${substring}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  pin_after="$(cat -- "${pin_path}")"
  if [[ ${pin_before} != "${pin_after}" ]]; then
    printf 'FAIL: %s — the pin fixture was modified\n' "${name}" >&2
    failures=$((failures + 1))
  elif ((rc != want_exit)); then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${want_exit}" "${rc}" >&2
    sed 's/^/    /' "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${substring}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${substring}" >&2
    sed 's/^/    /' "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "${name}"
    passes=$((passes + 1))
  fi

  rm --recursive --force -- "${stub_dir}" "${stdout_file}" "${stderr_file}" "${outcome_file}"
}

function main() {
  if [[ ! -f ${SCRIPT} ]]; then
    printf 'FAIL: script not found at %s\n' "${SCRIPT}" >&2
    exit 1
  fi
  if [[ ! -d ${FIXTURES} ]]; then
    printf 'FAIL: fixtures dir not found at %s\n' "${FIXTURES}" >&2
    exit 1
  fi

  # Pin-file scenarios: the shape gate on linpeas-pin.json trips before
  # the script ever calls `gh`, so which release fixture the stub emits
  # is irrelevant — good-release.json throughout keeps the plumbing
  # identical to the release-payload scenarios below.
  run_scenario 'empty pin payload is a tooling error' \
    'bad-pin-empty.json' 'good-release.json' 2 \
    'empty payload from PIN_FILE_OVERRIDE'
  run_scenario 'pin payload that is not JSON is a tooling error' \
    'bad-pin-not-json.txt' 'good-release.json' 2 \
    'payload from PIN_FILE_OVERRIDE is not valid JSON'
  run_scenario 'boolean-typed pin payload is a tooling error' \
    'bad-pin-wrong-type.json' 'good-release.json' 2 \
    'unexpected payload shape from PIN_FILE_OVERRIDE: payload is boolean, want object'

  # Upstream-release scenarios: the pin is well-formed so execution
  # reaches the `gh api` fetch (the stub above intercepts it), and the
  # shape gate on release_json trips before new_tag is ever read. No
  # override exists for this payload — bump-linpeas.sh always calls
  # `gh`, live or stubbed — so the source is named by the literal API
  # path, matching check-tag-protection.sh's no-override convention.
  run_scenario 'empty release payload is a tooling error' \
    'good-pin.json' 'bad-release-empty.json' 2 \
    'empty payload from repos/peass-ng/PEASS-ng/releases/latest'
  run_scenario 'release payload that is not JSON is a tooling error' \
    'good-pin.json' 'bad-release-not-json.txt' 2 \
    'payload from repos/peass-ng/PEASS-ng/releases/latest is not valid JSON'
  run_scenario 'boolean-typed release payload is a tooling error' \
    'good-pin.json' 'bad-release-wrong-type.json' 2 \
    'unexpected payload shape from repos/peass-ng/PEASS-ng/releases/latest: payload is boolean, want object'

  # Well-formed payloads, already at the upstream tag: both gates pass
  # and the script exits 0 at its "already at latest" short-circuit —
  # before curl or any mutation. Proves the gate does not reject a
  # well-shaped payload, without the harness ever reaching the
  # download/rewrite tail regardless of fixture content.
  run_scenario 'well-formed payloads already at latest, no bump needed' \
    'good-pin.json' 'good-release.json' 0 \
    'already at latest, nothing to do'

  harness_assert_verify || failures=$((failures + 1))

  printf '\n%d passed, %d failed\n' "${passes}" "${failures}"
  if ((failures > 0)); then
    exit 1
  fi
  exit 0
}

main "$@"
