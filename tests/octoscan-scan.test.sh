#!/usr/bin/env bash
# tests/octoscan-scan.test.sh
#
# Failure-mode harness for scripts/octoscan-scan.sh.
# Covers argument-parsing errors, the octoscan-missing branch and the
# has-finding / exit-code contract against a stubbed `octoscan` on PATH,
# without running the real scanner.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/octoscan-scan.sh"

failures=0

# @description Run the script; assert exit code + optional stderr/stdout substrings.
# @arg $1 scenario name
# @arg $2 expected exit code (0 or 1)
# @arg $3 expected stderr substring (empty skips the check)
# @arg $4 expected stdout substring (empty skips the check)
# @arg $5 expected stdout classification substring (empty skips the check)
# @arg $6 env override string passed to `env` (e.g. "PATH=/nonexistent"), or empty
# @arg $7... arguments forwarded to the script
function run_scenario() {
  local -r name="$1"
  local -r expected_exit="$2"
  local -r expected_stderr="$3"
  local -r expected_stdout="$4"
  local -r expected_class="$5"
  local -r env_override="$6"
  shift 6

  local stdout_file stderr_file outcome_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  if [[ -n ${env_override} ]]; then
    # Unset BASH_ENV so that .bashrc (and any profile it sources) cannot
    # re-inject system PATH entries into the controlled environment.
    env --unset=BASH_ENV "${env_override}" "${SCRIPT}" "$@" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  else
    "${SCRIPT}" "$@" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  fi
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  # One run is one scenario. Its record is the whole observable outcome —
  # exit code, stdout, stderr — carrying the substring expected of each
  # stream. Recording the run once per stream would make those two records
  # byte-identical siblings, which no substring can separate.
  harness_assert_record "${name}" "${expected_stdout}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stderr} ]]; then
    harness_assert_also "${expected_stderr}"
  fi
  if [[ -n ${expected_class} ]]; then
    harness_assert_also "${expected_class}"
  fi

  local failed=0

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failed=1
  fi

  if [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failed=1
  fi

  if [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    printf 'stdout was:\n' >&2
    cat -- "${stdout_file}" >&2
    failed=1
  fi

  if [[ -n ${expected_class} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_class}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing classification %q\n' "${name}" "${expected_class}" >&2
    printf 'stdout was:\n' >&2
    cat -- "${stdout_file}" >&2
    failed=1
  fi

  if [[ ${failed} -eq 0 ]]; then
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  else
    failures=$((failures + 1))
  fi

  rm --force -- "${stdout_file}" "${stderr_file}" "${outcome_file}"
}

# @description Make a temp dir whose `octoscan` stub exits with a fixed code,
#              standing in for octoscan's scan return so the has-finding /
#              exit-code contract can be exercised without the real scanner.
#              The runner-label probe is the only call that passes
#              `runner-label`, and it gets its own code. A `--format sarif`
#              call prints one result whose location is the path the script
#              passed to `scan`, so the merged SARIF shows which path form
#              reaches code scanning.
# @arg $1 exit code the stub returns for a workflow scan
# @arg $2 exit code for the runner-label probe (default 2: label still flagged)
function make_octoscan_stub() {
  local -r code="$1"
  local -r probe_code="${2:-2}"
  local d
  d="$(mktemp -d)"
  cat >"${d}/octoscan" <<STUB
#!/usr/bin/env bash
target=""
sarif=0
prev=""
for a in "\$@"; do
  [[ \${a} == runner-label ]] && exit ${probe_code}
  [[ \${prev} == scan ]] && target="\${a}"
  [[ \${prev} == --format && \${a} == sarif ]] && sarif=1
  prev="\${a}"
done
if ((sarif)); then
  printf '{"runs":[{"tool":{"driver":{"name":"octoscan"}},"results":[{"ruleId":"stub-rule","locations":[{"physicalLocation":{"artifactLocation":{"uri":"%s"}}}]}]}]}\n' "\${target}"
fi
exit ${code}
STUB
  chmod +x "${d}/octoscan"
  printf '%s' "${d}"
}

# @description Make a temp dir whose `octoscan` stub exits 1 on its first
#              invocation and 2 on every later one — a per-file scanner error
#              on one workflow mixed with a finding on another within a single
#              octoscan-scan run.
# @noargs
function make_octoscan_stub_seq() {
  local d
  d="$(mktemp -d)"
  cat >"${d}/octoscan" <<SEQ
#!/usr/bin/env bash
for a in "\$@"; do [[ \${a} == runner-label ]] && exit 2; done
counter="${d}/n"
n=0
[[ -f "\${counter}" ]] && n="\$(cat -- "\${counter}")"
n=\$((n + 1))
printf '%s' "\${n}" >"\${counter}"
if ((n == 1)); then exit 1; else exit 2; fi
SEQ
  chmod +x "${d}/octoscan"
  printf '%s' "${d}"
}

# @description Run the script with `--sarif` against a stub and assert the
#              merged SARIF's locations are repo-relative workflow paths:
#              code scanning attaches an alert to the file its URI names, so
#              an absolute path or a container mount prefix lands the alert
#              on no file in the repository.
# @arg $1 scenario name
# @arg $2 stub directory to put first on PATH
function run_sarif_location_scenario() {
  local -r name="$1"
  local -r stub_dir="$2"
  local stdout_file stderr_file outcome_file sarif_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"
  sarif_file="$(mktemp)"

  local actual_exit=0
  env --unset=BASH_ENV "PATH=${stub_dir}:${PATH}" "${SCRIPT}" --sarif "${sarif_file}" \
    >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" '"uri": ".github/workflows/' \
    "${outcome_file}" "${stdout_file}" "${stderr_file}" "${sarif_file}"
  harness_assert_also 'has-finding=true'
  harness_assert_also 'classification=findings'

  local failed=0 uris bad
  if [[ ${actual_exit} -ne 1 ]] ||
    ! grep --fixed-strings --quiet -- 'has-finding=true' "${stdout_file}" ||
    ! grep --fixed-strings --quiet -- 'classification=findings' "${stdout_file}"; then
    printf 'FAIL: %s — expected exit 1 with has-finding=true and classification=findings, got exit %d:\n' \
      "${name}" "${actual_exit}" >&2
    cat -- "${stdout_file}" >&2
    failed=1
  fi
  uris="$(jq --raw-output '.runs[0].results[].locations[0].physicalLocation.artifactLocation.uri' \
    "${sarif_file}" 2>/dev/null || true)"
  bad="$(grep --invert-match --extended-regexp '^\.github/workflows/[^/]+\.ya?ml$' <<<"${uris}" || true)"
  if [[ -z ${uris} ]]; then
    printf 'FAIL: %s — merged SARIF has no result locations (exit %d)\n' "${name}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failed=1
  elif [[ -n ${bad} ]]; then
    printf 'FAIL: %s — SARIF locations not repo-relative workflow paths:\n%s\n' "${name}" "${bad}" >&2
    failed=1
  fi
  if [[ ${failed} -eq 0 ]]; then
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  else
    failures=$((failures + 1))
  fi
  rm --force -- "${stdout_file}" "${stderr_file}" "${outcome_file}" "${sarif_file}"
}

function main() {
  run_scenario 'unknown argument exits 1' \
    1 'unknown argument' '' '' '' \
    --bogus

  run_scenario '--sarif without path exits 1' \
    1 'requires a path' '' '' '' \
    --sarif

  # Build a PATH that excludes any directory containing an octoscan binary
  # (the dev shell puts one there) so that `command -v octoscan` fails inside
  # the script. Strip each colon-separated entry that contains one.
  local no_octoscan_path=""
  local dir
  while IFS= read -r -d ':' dir || [[ -n ${dir} ]]; do
    [[ -x "${dir}/octoscan" ]] || no_octoscan_path="${no_octoscan_path:+${no_octoscan_path}:}${dir}"
  done <<<"${PATH}:"
  run_scenario 'missing octoscan exits 2 with SKIP hint and has-finding=false' \
    2 'SKIP=octoscan' 'has-finding=false' \
    'classification=infra-failure (octoscan unavailable)' "PATH=${no_octoscan_path}"

  # has-finding / exit-code contract, octoscan return stubbed:
  #   scan rc 0 -> has-finding=false, exit 0
  #   scan rc 2 -> has-finding=true,  exit 1
  #   scan rc other -> has-finding=false, exit 1 (tool error)
  local stub0 stub2 stub3
  stub0="$(make_octoscan_stub 0)"
  stub2="$(make_octoscan_stub 2)"
  stub3="$(make_octoscan_stub 3)"
  run_scenario 'octoscan clean -> has-finding=false exit 0' \
    0 '' 'has-finding=false' 'classification=clean' "PATH=${stub0}:${PATH}"
  run_scenario 'octoscan finding -> has-finding=true exit 1' \
    1 '' 'has-finding=true' 'classification=findings' "PATH=${stub2}:${PATH}"
  # has-finding=false + exit 1 is also what a clean-but-broken run prints, so
  # the classification is what says the scanner never analyzed the files.
  run_scenario 'octoscan tool error -> has-finding=false exit 1' \
    1 '' 'has-finding=false' \
    'classification=infra-failure (no findings recorded)' "PATH=${stub3}:${PATH}"
  rm --recursive --force -- "${stub0}" "${stub2}" "${stub3}"

  # A suppressed runner label the probe no longer sees flagged is a dead
  # suppression: the scan itself was clean, but the run fails under its own
  # classification so the entry is removed. A probe that errors is a scanner
  # error like any per-file one.
  local stub_stale stub_probe_err
  stub_stale="$(make_octoscan_stub 0 0)"
  stub_probe_err="$(make_octoscan_stub 0 3)"
  run_scenario 'stale runner-label suppression -> exit 1' \
    1 'octoscan now accepts runner label' 'has-finding=false' \
    'classification=stale-suppression' "PATH=${stub_stale}:${PATH}"
  run_scenario 'runner-label probe error -> infra failure' \
    1 'could not probe runner label' 'has-finding=false' \
    'classification=infra-failure (no findings recorded)' \
    "PATH=${stub_probe_err}:${PATH}"
  rm --recursive --force -- "${stub_stale}" "${stub_probe_err}"

  # A per-file scanner error (rc 1 = file never analyzed) mixed with a finding
  # (rc 2) must classify as an infra failure — has-finding=false, exit 1 — so
  # the errored file routes to the infra-failure path and is re-examined, not
  # hidden behind the finding and reported clean. The exit code and
  # has-finding line are identical to the all-errored run above; only the
  # classification says findings were recorded from an incomplete scan.
  local stub_seq
  stub_seq="$(make_octoscan_stub_seq)"
  run_scenario 'per-file error mixed with finding -> infra failure not finding' \
    1 '' 'has-finding=false' \
    'classification=infra-failure (findings recorded but incomplete)' \
    "PATH=${stub_seq}:${PATH}"
  rm --recursive --force -- "${stub_seq}"

  local stub_sarif
  stub_sarif="$(make_octoscan_stub 2)"
  run_sarif_location_scenario 'merged SARIF names repo-relative workflow paths' "${stub_sarif}"
  rm --recursive --force -- "${stub_sarif}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
