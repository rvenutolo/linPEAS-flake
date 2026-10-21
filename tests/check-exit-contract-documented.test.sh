#!/usr/bin/env bash
# tests/check-exit-contract-documented.test.sh
#
# Behaviour harness for scripts/check-exit-contract-documented.sh.

set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-exit-contract-documented.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/exit-contract-documented"

failures=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

# @description Run the lint over one fixture scan root and assert its exit
#              code and, when given, a substring of its diagnostics.
# @arg $1 fixture directory name
# @arg $2 expected exit code
# @arg $3 substring expected in stderr (empty to skip)
function expect() {
  expect_in "${FIXTURES}/$1/scripts" "$1" "$2" "$3"
}

# @description Run the lint over one scan root and assert its exit code
#              and, when given, a substring of its diagnostics.
# @arg $1 scripts directory
# @arg $2 scenario label
# @arg $3 expected exit code
# @arg $4 substring expected in stderr (empty to skip)
function expect_in() {
  local -r scripts_dir="$1" fixture="$2" want_exit="$3" want_msg="$4"
  local got_exit=0 got_stderr
  got_stderr="$(SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' \
      "${fixture}" "${want_msg}" "${got_stderr}" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'OK   %s\n' "${fixture}"
}

# @description Assert the clean summary names the scope it walked, so a
#              pass states how much it read rather than only that it read
#              something.
# @arg $1 fixture directory name
# @arg $2 substring expected on stdout
function expect_summary() {
  local -r fixture="$1" want="$2"
  local got
  got="$(SCRIPTS_DIR_OVERRIDE="${FIXTURES}/${fixture}/scripts" "${SCRIPT}" 2>/dev/null)"
  if [[ ${got} != *"${want}"* ]]; then
    printf 'FAIL %s: summary missing %q\n  got: %s\n' "${fixture}" "${want}" "${got}" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'OK   %s (summary)\n' "${fixture}"
}

# --- each documented contract shape the tree uses is accepted ---
expect good-dedicated 0 ''
expect good-list 0 ''
expect good-block 0 ''
# The clause sits past any fixed character window from its "Exits", so
# this is what pins the sentence — rather than a character budget — as
# the bound on the list form.
expect good-wrapped 0 ''

# --- a script that cannot reach exit 2 owes no exit-2 sentence ---
expect good-unreachable 0 ''
# A header line naming the code is documentation, not a code path; the
# comment strip is what keeps it from being read as one.
expect good-comment-only 0 ''

# --- both routes to exit 2 are found ---
expect bad-literal 1 'can reach exit 2 but its header documents no exit-2 case'
expect bad-helper 1 'can reach exit 2 but its header documents no exit-2 case'
# The repository-root helper exits 2 in the caller's shell like the others.
expect bad-repo-helper 1 'check-r.sh'

# --- a 2 that is prose rather than an exit code excuses nothing ---
# 2FA and v2 open words; the token guard is what stops either from
# reading as a documented exit code.
expect bad-token-in-word 1 'check-i.sh'
# A standalone 2 in a later sentence is out of the contract sentence.
expect bad-late-sentence 1 'check-j.sh'

# --- an exit code is an ASCII token in every locale ---
# Under en_US.UTF-8 grep's `[A-Za-z]` also admits `é`, so a `2` followed
# by one would read as the start of a word and each form below would go
# unseen. The token guard names ASCII letters and digits, and `é` is
# neither. Each script is written at run time with one contract form.
require_grep_locale_gap en_US.UTF-8 || exit 1
# @description Write a scan root holding one script that reaches exit 2
#              behind the given header lines.
# @arg $1 scan root name  @arg $@ header comment lines
function write_locale_root() {
  local -r name="$1"
  shift
  mkdir --parents -- "${work}/${name}"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# %s\n' "$@"
    printf '\necho PAYLOAD_RAN\nexit 2\n'
  } >"${work}/${name}/check-${name}.sh"
}
write_locale_root locale-dedicated 'Exits 2é when the input is missing.'
write_locale_root locale-list 'Exits 0 when clean, 1 on drift, 2é on a missing input.'
write_locale_root locale-block 'Exit codes:' '  0 clean' '  2é missing input'
LC_ALL=en_US.UTF-8 expect_in "${work}/locale-dedicated" locale-dedicated 0 ''
LC_ALL=en_US.UTF-8 expect_in "${work}/locale-list" locale-list 0 ''
LC_ALL=en_US.UTF-8 expect_in "${work}/locale-block" locale-block 0 ''

# --- a long header is read whole however early its exit-2 item sits ---
# The block form is matched by a reader that quits at its first hit. With
# the `2` item near the top of a header far larger than a pipe buffer,
# the header's writer is still writing when that reader quits, so a
# writer whose exit status counts reads the contract as missing.
mkdir --parents -- "${work}/long-block"
{
  printf '#!/usr/bin/env bash\n'
  printf '# Exit codes:\n#   0 clean\n#   2 missing input\n'
  for ((line = 0; line < 20000; line++)); do
    printf '# padding line %d of a header longer than any pipe buffer\n' "${line}"
  done
  printf '\necho PAYLOAD_RAN\nexit 2\n'
} >"${work}/long-block/check-long.sh"
expect_in "${work}/long-block" long-block 0 ''

# --- a scan root with no script is a could-not-run, not a clean tree ---
expect empty 2 ''

# --- a clean run states its scope ---
expect_summary good-dedicated 'can reach exit 2'

if ((failures)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
