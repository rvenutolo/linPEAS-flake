#!/usr/bin/env bash
# scripts/check-workflow-ascii-space.sh
#
# @description Lint: workflow and composite-action YAML holds no Unicode
# space or line separator (U+0085, U+00A0, U+1680, U+2000 to U+200B,
# U+2028, U+2029, U+202F, U+205F, U+3000) in any position. The lints that
# scan these files by text read blankness with `[[:space:]]`, which
# matches U+1680, U+2000 to U+2006, U+2008 to U+200A, U+2028, U+2029,
# U+205F and U+3000 in every UTF-8 locale, `C.UTF-8` included, while YAML
# separates tokens with space and tab only. U+0085 (next line), the
# no-break spaces U+00A0, U+2007 and U+202F, and the zero-width space
# U+200B are outside that class; they are in the list because each is a
# line break, looks like a space or is invisible in a diff. A character
# between a key and its value, in an indent or before a `#` could make a
# lint and the consumer read the same line differently, and which reading
# GitHub Actions takes cannot be checked offline. Refusing the character
# keeps the text scanners and the consumers on one reading. A character
# that is wanted as data is written as an escape inside a double-quoted
# scalar (`"\u2003"`), which holds ASCII only in the file.
#
# The search is `grep --fixed-strings --text` for each separator's UTF-8
# bytes, which matches bytes, so the result does not depend on the locale
# the lint runs in.
#
# Scan set: `.github/workflows/*.yml` and `*.yaml`, and
# `.github/actions/*/action.yml` and `action.yaml`. Honors
# WORKFLOWS_DIR_OVERRIDE and ACTIONS_DIR_OVERRIDE for fixtures, and
# LINT_ALLOW_EMPTY_SCAN=1 for an empty scan set.
#
# Exits 0 when no file holds one, 1 when one does. Exits 2 when the check
# cannot run: `grep` absent from PATH, the scan globs together matching
# no regular file, or `grep` failing on a file.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-.github/workflows}"
readonly ACTIONS_DIR="${ACTIONS_DIR_OVERRIDE:-.github/actions}"

require_tool grep

# code point (hex, without U+) and its UTF-8 bytes, one per element
readonly -a SEPARATORS=(
  '0085:\xc2\x85' '00A0:\xc2\xa0' '1680:\xe1\x9a\x80'
  '2000:\xe2\x80\x80' '2001:\xe2\x80\x81' '2002:\xe2\x80\x82'
  '2003:\xe2\x80\x83' '2004:\xe2\x80\x84' '2005:\xe2\x80\x85'
  '2006:\xe2\x80\x86' '2007:\xe2\x80\x87' '2008:\xe2\x80\x88'
  '2009:\xe2\x80\x89' '200A:\xe2\x80\x8a' '200B:\xe2\x80\x8b'
  '2028:\xe2\x80\xa8' '2029:\xe2\x80\xa9' '202F:\xe2\x80\xaf'
  '205F:\xe2\x81\x9f' '3000:\xe3\x80\x80'
)

declare -a files=()
glob_into files 'workflow and composite-action YAML' \
  "${WORKFLOWS_DIR}/*.yml" "${WORKFLOWS_DIR}/*.yaml" \
  "${ACTIONS_DIR}/*/action.yml" "${ACTIONS_DIR}/*/action.yaml"

failed=0
bad_files=0
scanned=0
lines=0
for f in "${files[@]}"; do
  [[ -f ${f} ]] || continue
  scanned=$((scanned + 1))
  failed_before=${failed}
  # An unreadable file or a grep failure is a could-not-run, not a count.
  # grep --count exits 1 for a file with no line, which is a count of 0.
  rc=0
  n="$(grep --count --text '' -- "${f}")" || rc=$?
  if ((rc > 1)); then
    log_err "grep failed (exit ${rc}) reading ${f}"
    exit 2
  fi
  lines=$((lines + n))
  for entry in "${SEPARATORS[@]}"; do
    code="${entry%%:*}"
    bytes="$(printf '%b' "${entry#*:}")"
    # grep exits 1 for no match and 2 for an error; only 1 is "clean".
    rc=0
    hits="$(grep --fixed-strings --line-number --text -- "${bytes}" "${f}")" || rc=$?
    if ((rc == 0)); then
      while IFS= read -r hit; do
        printf '%s:%s: U+%s is not YAML whitespace; write it as an escape in a double-quoted scalar\n' \
          "${f}" "${hit%%:*}" "${code}" >&2
        failed=$((failed + 1))
      done <<<"${hits}"
    elif ((rc != 1)); then
      log_err "grep failed (exit ${rc}) reading ${f}"
      exit 2
    fi
  done
  if ((failed > failed_before)); then bad_files=$((bad_files + 1)); fi
done

if ((scanned == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
  log_err "no regular file among the scan globs — a real tree cannot have an empty scan set; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate"
  exit 2
fi

if ((failed > 0)); then
  printf 'workflow-ascii-space: %d Unicode space(s) in %d file(s)\n' "${failed}" "${bad_files}" >&2
  exit 1
fi
printf 'workflow-ascii-space: %d file(s), %d line(s) clean\n' "${scanned}" "${lines}"
