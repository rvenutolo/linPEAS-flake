#!/usr/bin/env bash
# @subject scripts/lib/locale-gap.sh
# tests/lib-locale-gap.test.sh — proves require_locale_gap passes only for
# a locale in which bash's [0-9] admits a non-ASCII digit, and
# require_grep_locale_gap only for one in which grep's [a-z] admits a
# non-ASCII letter. Each fails loudly, naming the locale, for one that is
# ASCII-only or not installed; the grep probe also for a grep on PATH that
# matches ASCII only.
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly LIB="${REPO_ROOT}/scripts/lib/locale-gap.sh"
failures=0

work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
cat >"${work}/probe.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=\$'\n\t'
source "${LIB}"
require_locale_gap "\$1"
EOF
chmod +x "${work}/probe.sh"
cat >"${work}/grep-probe.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=\$'\n\t'
source "${LIB}"
require_grep_locale_gap "\$1"
EOF
chmod +x "${work}/grep-probe.sh"
# Both probes in one run: each passes silently, so a passing run of one
# would record the same output as a passing run of the other.
cat >"${work}/both-probe.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=\$'\n\t'
source "${LIB}"
require_locale_gap "\$1"
require_grep_locale_gap "\$1"
EOF
chmod +x "${work}/both-probe.sh"
# A grep that matches ASCII only in every locale: the real one, run under
# C. It stands in for a grep whose engine does not follow collation.
real_grep="$(type -P grep)"
readonly real_grep
mkdir -- "${work}/ascii-grep"
printf '#!/usr/bin/env bash\nLC_ALL=C exec %q "$@"\n' "${real_grep}" >"${work}/ascii-grep/grep"
chmod +x "${work}/ascii-grep/grep"

# @description Run one probe script for one locale and compare exit code
# and the whole of stderr.
# @arg $1 scenario name  @arg $2 locale  @arg $3 expected exit
# @arg $4 the whole expected stderr ('' for none)
# @arg $5 probe script under the work dir (default `probe.sh`)
# @arg $6 PATH to run it with (default the current PATH)
function run_scenario() {
  local -r name="$1" locale="$2" expected_exit="$3" expected_err="$4"
  local -r script="${5:-probe.sh}" path="${6:-${PATH}}"
  local out err outcome rc=0
  out="$(mktemp)"
  err="$(mktemp)"
  outcome="$(mktemp)"
  env --unset=BASH_ENV PATH="${path}" "${work}/${script}" "${locale}" >"${out}" 2>"${err}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${expected_err}" "${outcome}" "${out}" "${err}"
  if [[ ${rc} -eq ${expected_exit} && "$(cat -- "${err}")" == "${expected_err}" && ! -s ${out} ]]; then
    printf 'PASS: %s (exit %d)\n' "${name}" "${rc}"
  else
    printf 'FAIL: %s: expected exit %d and stderr %q; got exit %d, stderr %q, stdout %q\n' \
      "${name}" "${expected_exit}" "${expected_err}" "${rc}" "$(cat -- "${err}")" \
      "$(cat -- "${out}")" >&2
    failures=$((failures + 1))
  fi
  rm --force -- "${out}" "${err}" "${outcome}"
}

run_scenario 'en_US.UTF-8 shows the gap to bash and grep' en_US.UTF-8 0 '' both-probe.sh
run_scenario 'C.UTF-8 is refused as ASCII-only' C.UTF-8 1 \
  'probe.sh: locale C.UTF-8 cannot show a locale-bound [0-9] range (probe printed '"''"'); scenarios pinned to it would pass without testing it'
run_scenario 'POSIX is refused as ASCII-only' POSIX 1 \
  'probe.sh: locale POSIX cannot show a locale-bound [0-9] range (probe printed '"''"'); scenarios pinned to it would pass without testing it'

# An uninstalled locale makes bash warn and fall back to C; the warning is
# what the probe printed, so the line names the cause. Its exact wording
# belongs to bash, so only the fixed part of the line is compared whole.
missing_err="$(mktemp)"
missing_out="$(mktemp)"
missing_outcome="$(mktemp)"
missing_rc=0
env --unset=BASH_ENV "${work}/probe.sh" xx_XX.UTF-8 >"${missing_out}" 2>"${missing_err}" ||
  missing_rc=$?
printf 'harness-assert-outcome: exit=%d\n' "${missing_rc}" >"${missing_outcome}"
readonly missing_prefix='probe.sh: locale xx_XX.UTF-8 cannot show a locale-bound [0-9] range (probe printed '
harness_assert_record 'an uninstalled locale is refused' "${missing_prefix}" \
  "${missing_outcome}" "${missing_out}" "${missing_err}"
missing_line="$(cat -- "${missing_err}")"
if [[ ${missing_rc} -eq 1 && ${missing_line} == "${missing_prefix}"*'setlocale'*'); scenarios pinned to it would pass without testing it' ]]; then
  printf 'PASS: an uninstalled locale is refused (exit 1)\n'
else
  printf 'FAIL: an uninstalled locale is refused: exit %d, stderr %q\n' \
    "${missing_rc}" "${missing_line}" >&2
  failures=$((failures + 1))
fi
rm --force -- "${missing_err}" "${missing_out}" "${missing_outcome}"

# GNU grep keeps a lone `[0-9]` ASCII in every locale but follows the
# locale's collation for a letter range, so the grep probe asks `[a-z]`.
readonly GREP_HEAD='cannot show a locale-bound [a-z] range in grep (probe printed '
readonly GREP_TAIL='); scenarios pinned to it would pass without testing it'
run_scenario 'grep: C.UTF-8 is refused as ASCII-only' C.UTF-8 1 \
  "grep-probe.sh: locale C.UTF-8 ${GREP_HEAD}0${GREP_TAIL}" grep-probe.sh
run_scenario 'grep: POSIX is refused as ASCII-only' POSIX 1 \
  "grep-probe.sh: locale POSIX ${GREP_HEAD}0${GREP_TAIL}" grep-probe.sh
run_scenario 'grep: an ASCII-only grep on PATH is refused under en_US.UTF-8' en_US.UTF-8 1 \
  "grep-probe.sh: locale en_US.UTF-8 ${GREP_HEAD}0${GREP_TAIL}" grep-probe.sh \
  "${work}/ascii-grep:${PATH}"

# An uninstalled locale makes bash warn as it sets LC_ALL for grep, and
# grep falls back to C; the warning is part of what the probe printed.
missing_err="$(mktemp)"
missing_out="$(mktemp)"
missing_outcome="$(mktemp)"
missing_rc=0
env --unset=BASH_ENV "${work}/grep-probe.sh" xx_XX.UTF-8 >"${missing_out}" 2>"${missing_err}" ||
  missing_rc=$?
printf 'harness-assert-outcome: exit=%d\n' "${missing_rc}" >"${missing_outcome}"
readonly grep_missing_prefix="grep-probe.sh: locale xx_XX.UTF-8 ${GREP_HEAD}"
harness_assert_record 'grep: an uninstalled locale is refused' "${grep_missing_prefix}" \
  "${missing_outcome}" "${missing_out}" "${missing_err}"
missing_line="$(cat -- "${missing_err}")"
if [[ ${missing_rc} -eq 1 && ${missing_line} == "${grep_missing_prefix}"*'setlocale'*"${GREP_TAIL}" ]]; then
  printf 'PASS: grep: an uninstalled locale is refused (exit 1)\n'
else
  printf 'FAIL: grep: an uninstalled locale is refused: exit %d, stderr %q\n' \
    "${missing_rc}" "${missing_line}" >&2
  failures=$((failures + 1))
fi
rm --force -- "${missing_err}" "${missing_out}" "${missing_outcome}"

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -ne 0 ]]; then
  printf '%d failure(s)\n' "${failures}" >&2
  exit 1
fi
