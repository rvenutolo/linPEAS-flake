#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-manifest-digest-pinned.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/manifest-digest-pinned"
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(PATHS_OVERRIDE="${FIXTURES}/${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

expect good-digest-literal.yml 0 ""
expect good-digest-var.yml 0 ""
expect good-inspect.yml 0 ""
expect good-manifest-create.yml 0 ""
expect good-manifest-annotate.yml 0 ""
expect good-log-line.yml 0 ""
expect good-prose.md 0 ""
expect bad-mutable-tag.yml 1 "amd64"
expect bad-mixed-continuation.yml 1 "arm64"
expect bad-manifest-create.yml 1 "amd64"
expect bad-manifest-annotate.yml 1 "arm64"
expect bad-nondigest-var.yml 1 "AMD64_REF"
expect bad-fence.md 1 "amd64"

# @description Drive the enumeration itself, not a fixture: with
# PATHS_OVERRIDE unset the script enumerates via `git ls-files`, and an
# unreadable index makes that producer exit 0 with no output. A status
# check cannot see that, so the empty scan set has to be the assertion.
# @arg $1 expected exit code  @arg $2 expected stderr substring
function expect_empty_scan() {
  local -r want_exit="$1" want_msg="$2"
  local got_exit=0 got_stderr index_dir
  index_dir="$(mktemp --directory)"
  got_stderr="$(cd "${REPO_ROOT}" &&
    GIT_INDEX_FILE="${index_dir}/absent.idx" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${index_dir}"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL empty-scan: exit %s, want %s\n  stderr: %s\n' "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL empty-scan: stderr missing %q\n  got: %s\n' "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   empty-scan\n'
}

expect_empty_scan 2 "enumerated 0 files via git ls-files"

# Under en_US.UTF-8 a bash `[A-Za-z_]` range also matches non-ASCII
# letters, so `@${éDIGEST}` would read as a digest variable. bash cannot
# expand that name, so the ref is reported. Built at run time; the whole
# of stderr is compared.
require_locale_gap en_US.UTF-8 || exit 1
md_dir="$(mktemp --directory)"
# shellcheck disable=SC2016 # the ${…} is file text, not an expansion
printf '#!/usr/bin/env bash\ndocker buildx imagetools create --tag ghcr.io/o/i:t ghcr.io/o/i@${éDIGEST}\n' \
  >"${md_dir}/ref.sh"
md_exit=0
md_err="$(LC_ALL=en_US.UTF-8 PATHS_OVERRIDE="${md_dir}/ref.sh" "${SCRIPT}" 2>&1 >/dev/null)" ||
  md_exit=$?
# shellcheck disable=SC2016 # the ${…} is expected output text
md_want="${md_dir}/ref.sh: manifest source ref not digest-pinned: ghcr.io/o/i@\${éDIGEST}; in: docker buildx imagetools create --tag ghcr.io/o/i:t ghcr.io/o/i@\${éDIGEST}
1 manifest source ref(s) not digest-pinned"
rm --recursive --force -- "${md_dir}"
if [[ ${md_exit} != 1 || ${md_err} != "${md_want}" ]]; then
  printf 'FAIL non-ASCII digest variable: exit %s (want 1)\n  stderr: %s\n  want:   %s\n' \
    "${md_exit}" "${md_err}" "${md_want}" >&2
  exit 1
fi
printf 'OK   non-ASCII digest variable reported under en_US.UTF-8\n'

printf 'all tests passed\n'
