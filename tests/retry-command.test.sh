#!/usr/bin/env bash
# tests/retry-command.test.sh
#
# Behavior matrix for scripts/retry-command.sh: the retry count, the
# exit-code passthrough, the stderr progress lines and the usage errors.
# Every stub command is inert: it echoes a marker and bumps a counter file
# in a scratch directory. Offline and deterministic (delay 0).
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/retry-command.sh"

failures=0
scratch="$(mktemp --directory)"
readonly scratch
# shellcheck disable=SC2064 # expanded now on purpose: the path is fixed once created
trap "rm --recursive --force -- '${scratch}'" EXIT

# Stub: bumps the counter file, fails with STUB_FAIL_EXIT until the
# counter reaches STUB_SUCCEED_AT, then prints PAYLOAD_OK and exits 0.
readonly STUB="${scratch}/stub.sh"
cat >"${STUB}" <<'STUB_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
count=0
if [[ -f ${STUB_COUNTER} ]]; then count="$(<"${STUB_COUNTER}")"; fi
count=$((count + 1))
printf '%s' "${count}" >"${STUB_COUNTER}"
if ((count >= STUB_SUCCEED_AT)); then
  printf 'PAYLOAD_OK\n'
  exit 0
fi
printf 'PAYLOAD_FAIL %s\n' "${count}" >&2
exit "${STUB_FAIL_EXIT}"
STUB_EOF
chmod +x "${STUB}"

# @description Run the script once and compare exit code, stdout and
# stderr line counts.
# @arg $1 label  @arg $2 want exit  @arg $3 succeed-at (999 = never)
# @arg $4 fail exit  @arg $5 want attempts run  @arg $6 want stdout
# @arg $7 want "retrying" line count  remaining: script args
function scenario() {
  local -r label="$1" want_exit="$2" succeed_at="$3" fail_exit="$4"
  local -r want_attempts="$5" want_out="$6" want_retry_lines="$7"
  shift 7
  local counter="${scratch}/counter-${label}"
  local out="${scratch}/out-${label}" err="${scratch}/err-${label}" rc=0
  STUB_COUNTER="${counter}" STUB_SUCCEED_AT="${succeed_at}" STUB_FAIL_EXIT="${fail_exit}" \
    bash "${SCRIPT}" "$@" -- "${STUB}" >"${out}" 2>"${err}" || rc=$?
  local attempts=0 retry_lines=0 line
  if [[ -f ${counter} ]]; then attempts="$(<"${counter}")"; fi
  while IFS= read -r line; do
    if [[ ${line} == retry-command:\ attempt\ *failed*retrying\ in* ]]; then
      retry_lines=$((retry_lines + 1))
    fi
  done <"${err}"
  local got_out
  got_out="$(<"${out}")"
  if [[ ${rc} != "${want_exit}" || ${attempts} != "${want_attempts}" ||
    ${got_out} != "${want_out}" || ${retry_lines} != "${want_retry_lines}" ]]; then
    printf 'FAIL %s: exit %s (want %s), attempts %s (want %s), retry lines %s (want %s), stdout %q (want %q)\n' \
      "${label}" "${rc}" "${want_exit}" "${attempts}" "${want_attempts}" \
      "${retry_lines}" "${want_retry_lines}" "${got_out}" "${want_out}" >&2
    failures=1
    return
  fi
  printf 'OK   %s\n' "${label}"
}

# Format of one progress line, checked once exactly.
function check_progress_format() {
  local err
  STUB_COUNTER="${scratch}/counter-fmt" STUB_SUCCEED_AT=999 STUB_FAIL_EXIT=10 \
    bash "${SCRIPT}" 2 0 -- "${STUB}" >/dev/null 2>"${scratch}/err-fmt" || true
  err="$(<"${scratch}/err-fmt")"
  if [[ ${err} != *'retry-command: attempt 1/2 failed (exit 10); retrying in 0s'* ]]; then
    printf 'FAIL progress-format: stderr %q\n' "${err}" >&2
    failures=1
    return
  fi
  if [[ ${err} == *'attempt 2/2 failed'*retrying* ]]; then
    printf 'FAIL progress-format: last attempt printed a retry line\n' >&2
    failures=1
    return
  fi
  printf 'OK   progress-format\n'
}

scenario succeeds-on-third 0 3 10 3 PAYLOAD_OK 2 5 0
scenario always-fails-exit-10 10 999 10 5 '' 4 5 0
scenario succeeds-first-try 0 1 10 1 PAYLOAD_OK 0 5 0
scenario single-attempt-fails 7 999 7 1 '' 0 1 0
check_progress_format

# Usage errors exit 2 and never run the command.
function usage_case() {
  local -r label="$1"
  shift
  local rc=0
  bash "${SCRIPT}" "$@" >/dev/null 2>&1 || rc=$?
  if [[ ${rc} -ne 2 ]]; then
    printf 'FAIL %s: exit %d, want 2\n' "${label}" "${rc}" >&2
    failures=1
    return
  fi
  printf 'OK   %s\n' "${label}"
}
usage_case missing-separator 3 0 true
usage_case attempts-zero 0 0 -- true
usage_case attempts-not-number x 0 -- true
usage_case delay-not-number 3 x -- true
usage_case no-command 3 0 --
usage_case no-args

exit "${failures}"
