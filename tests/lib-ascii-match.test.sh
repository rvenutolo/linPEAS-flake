#!/usr/bin/env bash
# @subject scripts/lib/ascii-match.sh
# tests/lib-ascii-match.test.sh — proves ascii_match reads a regex range
# as ASCII under en_US.UTF-8, keeps the C.UTF-8 reading of a character
# class, leaves BASH_REMATCH set, gives the caller its locale back, and
# passes a regex that does not compile through as exit 2.
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"
readonly LIB="${REPO_ROOT}/scripts/lib/ascii-match.sh"
failures=0

require_locale_gap en_US.UTF-8 || exit 1

work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
# The probe sources the library, runs one ascii_match call, and prints its
# status, the first capture group, and whether the caller's own [0-9]
# still admits a fullwidth digit afterwards (it does under en_US.UTF-8).
# shellcheck disable=SC2016 # the probe's own text
printf '%s\n' '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  "source '${LIB}'" \
  'rc=0' \
  'ascii_match "$1" "$2" 2>/dev/null || rc=$?' \
  'group="${BASH_REMATCH[1]-}"' \
  'caller=ascii' \
  "[[ '５' =~ ^[0-9]\$ ]] && caller=collated" \
  'printf "status=%d group=%s caller=%s\n" "${rc}" "${group}" "${caller}"' \
  >"${work}/probe.sh"
chmod +x "${work}/probe.sh"

# @description Run one ascii_match call under en_US.UTF-8 and compare the
# whole of stdout, which starts with the text matched so that every
# scenario's output is its own.
# @arg $1 scenario name  @arg $2 text  @arg $3 regex
# @arg $4 the whole expected stdout after the text
function run_scenario() {
  local -r name="$1" text="$2" regex="$3"
  local -r want="text=${text} $4"
  local out err outcome rc=0
  out="$(mktemp)"
  err="$(mktemp)"
  outcome="$(mktemp)"
  {
    printf 'text=%s ' "${text}"
    env --unset=BASH_ENV LC_ALL=en_US.UTF-8 "${work}/probe.sh" "${text}" "${regex}" 2>"${err}"
  } >"${out}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${want}" "${outcome}" "${out}" "${err}"
  if [[ ${rc} -eq 0 && "$(cat -- "${out}")" == "${want}" && ! -s ${err} ]]; then
    printf 'PASS: %s\n' "${name}"
  else
    printf 'FAIL: %s: expected stdout %q; got exit %d, stdout %q, stderr %q\n' \
      "${name}" "${want}" "${rc}" "$(cat -- "${out}")" "$(cat -- "${err}")" >&2
    failures=$((failures + 1))
  fi
  rm --force -- "${out}" "${err}" "${outcome}"
}

# The em space is written as its UTF-8 bytes, which bash decodes the same
# way under any locale.
readonly EM_SPACE=$'\342\200\203'

run_scenario 'a fullwidth digit is outside [0-9]' '５' '^([0-9])$' \
  'status=1 group= caller=collated'
run_scenario 'an accented letter is outside [a-z]' 'é' '^([a-z])$' \
  'status=1 group= caller=collated'
run_scenario 'an ASCII digit matches and fills BASH_REMATCH' '7' '^([0-9])$' \
  'status=0 group=7 caller=collated'
run_scenario 'an em space is still [[:space:]]' "${EM_SPACE}x" '^([[:space:]])x$' \
  "status=0 group=${EM_SPACE} caller=collated"
run_scenario 'a regex that does not compile is exit 2' 'x' '([' \
  'status=2 group= caller=collated'

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -ne 0 ]]; then
  printf '%d failure(s)\n' "${failures}" >&2
  exit 1
fi
