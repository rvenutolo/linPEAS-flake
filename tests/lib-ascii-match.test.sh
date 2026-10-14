#!/usr/bin/env bash
# @subject scripts/lib/ascii-match.sh
# tests/lib-ascii-match.test.sh — proves ascii_match reads a regex range
# as ASCII under en_US.UTF-8, keeps the C.UTF-8 reading of a character
# class, leaves BASH_REMATCH set, gives the caller its locale back, and
# passes a regex that does not compile through as exit 2; and that
# ascii_fold_regex prints a bracket of both cases per lower-case letter
# and refuses text holding anything but lower-case letters, digits, `/`,
# `-` and `_`.
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

# The fold probe sources the library, runs one ascii_fold_regex call, and
# prints its status and the regex it printed.
# shellcheck disable=SC2016 # the probe's own text
printf '%s\n' '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  "source '${LIB}'" \
  'rc=0' \
  'regex="$(ascii_fold_regex "$1" 2>/dev/null)" || rc=$?' \
  'printf "status=%d regex=%s\n" "${rc}" "${regex}"' \
  >"${work}/fold-probe.sh"
chmod +x "${work}/fold-probe.sh"

# @description Run one ascii_fold_regex call under en_US.UTF-8 and compare
# the whole of stdout, which starts with the text folded so that every
# scenario's output is its own.
# @arg $1 scenario name  @arg $2 text
# @arg $3 the whole expected stdout after the text
function run_fold_scenario() {
  local -r name="$1" text="$2"
  local -r want="fold=${text} $3"
  local out err outcome rc=0
  out="$(mktemp)"
  err="$(mktemp)"
  outcome="$(mktemp)"
  {
    printf 'fold=%s ' "${text}"
    env --unset=BASH_ENV LC_ALL=en_US.UTF-8 "${work}/fold-probe.sh" "${text}" 2>"${err}"
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

# The Kelvin sign is written as its UTF-8 bytes; a case-insensitive regex
# flag folds it to k, and a two-letter bracket does not.
readonly KELVIN=$'\342\204\252'

run_fold_scenario 'a lower-case letter becomes a bracket of both cases' 'ab' \
  'status=0 regex=[aA][bB]'
run_fold_scenario 'a digit, a slash, a hyphen and an underscore stay as written' 'a1/b-c_d' \
  'status=0 regex=[aA]1/[bB]-[cC]_[dD]'
run_fold_scenario 'the last letter of the alphabet pairs with its own capital' 'z' \
  'status=0 regex=[zZ]'
run_fold_scenario 'an upper-case letter is refused' 'Ab' \
  'status=2 regex='
run_fold_scenario 'a regex metacharacter is refused' 'a.b' \
  'status=2 regex='
run_fold_scenario 'a non-ASCII letter is refused' "${KELVIN}" \
  'status=2 regex='
run_fold_scenario 'the empty text is refused' '' \
  'status=2 regex='

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -ne 0 ]]; then
  printf '%d failure(s)\n' "${failures}" >&2
  exit 1
fi
