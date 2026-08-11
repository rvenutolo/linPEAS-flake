#!/usr/bin/env bash
# tests/octoscan-scan.test.sh
#
# Failure-mode harness for scripts/octoscan-scan.sh.
# Covers argument-parsing errors and the docker-missing branch without
# requiring a live Docker daemon.

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
# @arg $5 env override string passed to `env` (e.g. "PATH=/nonexistent"), or empty
# @arg $6... arguments forwarded to the script
function run_scenario() {
  local -r name="$1"
  local -r expected_exit="$2"
  local -r expected_stderr="$3"
  local -r expected_stdout="$4"
  local -r env_override="$5"
  shift 5

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

  if [[ ${failed} -eq 0 ]]; then
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  else
    failures=$((failures + 1))
  fi

  rm --force -- "${stdout_file}" "${stderr_file}" "${outcome_file}"
}

# @description Make a temp dir whose `docker` stub exits with a fixed code,
#              standing in for octoscan's scan return so the has-finding /
#              exit-code contract can be exercised without a daemon.
# @arg $1 exit code the stub docker returns
function make_docker_stub() {
  local -r code="$1"
  local d
  d="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nexit %s\n' "${code}" >"${d}/docker"
  chmod +x "${d}/docker"
  printf '%s' "${d}"
}

# @description Make a temp dir whose `docker` stub exits 1 on its first
#              invocation and 2 on every later one — a per-file scanner error
#              on one workflow mixed with a finding on another within a single
#              octoscan-scan run.
# @noargs
function make_docker_stub_seq() {
  local d
  d="$(mktemp -d)"
  cat >"${d}/docker" <<SEQ
#!/usr/bin/env bash
counter="${d}/n"
n=0
[[ -f "\${counter}" ]] && n="\$(cat -- "\${counter}")"
n=\$((n + 1))
printf '%s' "\${n}" >"\${counter}"
if ((n == 1)); then exit 1; else exit 2; fi
SEQ
  chmod +x "${d}/docker"
  printf '%s' "${d}"
}

function main() {
  run_scenario 'unknown argument exits 1' \
    1 'unknown argument' '' '' \
    --bogus

  run_scenario '--sarif without path exits 1' \
    1 'requires a path' '' '' \
    --sarif

  # Build a PATH that excludes any directory containing the real docker binary
  # so that `command -v docker` fails inside the script. Strip each colon-
  # separated entry that contains a `docker` executable.
  local no_docker_path=""
  local dir
  while IFS= read -r -d ':' dir || [[ -n ${dir} ]]; do
    [[ -x "${dir}/docker" ]] || no_docker_path="${no_docker_path:+${no_docker_path}:}${dir}"
  done <<<"${PATH}:"
  run_scenario 'missing docker exits 1 with SKIP hint and has-finding=false' \
    1 'SKIP=octoscan' 'has-finding=false' "PATH=${no_docker_path}"

  # has-finding / exit-code contract, docker return stubbed:
  #   scan rc 0 -> has-finding=false, exit 0
  #   scan rc 2 -> has-finding=true,  exit 1
  #   scan rc other -> has-finding=false, exit 1 (tool error)
  local stub0 stub2 stub3
  stub0="$(make_docker_stub 0)"
  stub2="$(make_docker_stub 2)"
  stub3="$(make_docker_stub 3)"
  run_scenario 'octoscan clean -> has-finding=false exit 0' \
    0 '' 'has-finding=false' "PATH=${stub0}:${PATH}"
  run_scenario 'octoscan finding -> has-finding=true exit 1' \
    1 '' 'has-finding=true' "PATH=${stub2}:${PATH}"
  run_scenario 'octoscan tool error -> has-finding=false exit 1' \
    1 '' 'has-finding=false' "PATH=${stub3}:${PATH}"
  rm --recursive --force -- "${stub0}" "${stub2}" "${stub3}"

  # A per-file scanner error (rc 1 = file never analyzed) mixed with a finding
  # (rc 2) must classify as an infra failure — has-finding=false, exit 1 — so
  # the errored file routes to the infra-failure path and is re-examined, not
  # hidden behind the finding and reported clean.
  local stub_seq
  stub_seq="$(make_docker_stub_seq)"
  run_scenario 'per-file error mixed with finding -> infra failure not finding' \
    1 '' 'has-finding=false' "PATH=${stub_seq}:${PATH}"
  rm --recursive --force -- "${stub_seq}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
