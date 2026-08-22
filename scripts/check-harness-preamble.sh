#!/usr/bin/env bash
# scripts/check-harness-preamble.sh
#
# @description Lint: every test harness matching `tests/*.test.sh`
# opens with the canonical preamble — `#!/usr/bin/env bash` as the
# exact first line, `set -Eeuo pipefail`, the tab/newline IFS line,
# and a `readonly REPO_ROOT` derived from
# `git rev-parse --show-toplevel`.

# tests/README.md documents this preamble as universal, and a harness
# that drops a piece of it fails differently from its siblings: without
# pipefail a failing script-under-test can score as a pass, without the
# strict IFS a fixture path containing a space word-splits, and without
# a readonly REPO_ROOT derived from the repo top-level a harness run
# from another directory resolves the wrong tree. This lint makes the
# documented claim true by construction rather than by review.
#
# The REPO_ROOT rule accepts both documented spellings — the direct
# form (`REPO_ROOT=…` then `readonly REPO_ROOT`) and the two-step form
# (`repo_root=…` then `readonly REPO_ROOT="${repo_root}"`) — by
# asserting the `readonly` line and the rev-parse derivation
# separately rather than one exact shape.
#
# The scan is non-recursive on purpose: fixture harnesses under
# tests/fixtures/ exist to violate rules and stay out of scope.
#
# Honors TESTS_DIR_OVERRIDE + TEST_FILE_FILTER for fixtures. Exits 0
# clean, 1 on any drift, 2 when enumeration selects nothing.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly DEFAULT_DIR="tests"
readonly DIR="${TESTS_DIR_OVERRIDE:-${DEFAULT_DIR}}"
readonly FILE_FILTER="${TEST_FILE_FILTER:-}"

readonly WANT_SHEBANG="#!/usr/bin/env bash"
readonly WANT_SET_LINE="set -Eeuo pipefail"
readonly WANT_IFS_LINE="IFS=\$'\\n\\t'"
# The substitution is literal search text, never expanded here.
# shellcheck disable=SC2016
readonly WANT_DERIVE='$(git rev-parse --show-toplevel)'

failed=0
shopt -s nullglob
declare -a harnesses=()
glob_into harnesses 'test harnesses' "${DIR}/*.test.sh"
declare -a selected=()
filter_into selected 'test harnesses' "${FILE_FILTER}" "${harnesses[@]}"
for f in "${selected[@]}"; do
  [[ -f ${f} ]] || continue

  first_line="$(head -n 1 "${f}")"
  if [[ ${first_line} != "${WANT_SHEBANG}" ]]; then
    printf '%s: first line is %q; must be %q\n' \
      "${f}" "${first_line}" "${WANT_SHEBANG}" >&2
    failed=$((failed + 1))
  fi

  # Accept the same setting as part of a longer set line too
  # (e.g. `set -Eeuo pipefail -x`), but reject if absent.
  if ! grep --quiet --extended-regexp '^set -Eeuo pipefail([[:space:]]|$)' "${f}"; then
    printf '%s: missing %q (need it as its own line)\n' \
      "${f}" "${WANT_SET_LINE}" >&2
    failed=$((failed + 1))
  fi

  if ! grep --quiet --fixed-strings --line-regexp -- "${WANT_IFS_LINE}" "${f}"; then
    printf '%s: missing the %s field-separator line\n' \
      "${f}" "${WANT_IFS_LINE}" >&2
    failed=$((failed + 1))
  fi

  if ! grep --quiet --extended-regexp -- '^readonly REPO_ROOT($|=)' "${f}"; then
    printf '%s: REPO_ROOT is never made readonly (direct or two-step form; see tests/README.md)\n' \
      "${f}" >&2
    failed=$((failed + 1))
  elif ! grep --quiet --fixed-strings -- "${WANT_DERIVE}" "${f}"; then
    printf '%s: REPO_ROOT is not derived from %s\n' \
      "${f}" "${WANT_DERIVE}" >&2
    failed=$((failed + 1))
  fi
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d preamble violation(s) across test harnesses\n' "${failed}" >&2
  exit 1
fi
exit 0
