#!/usr/bin/env bash
# scripts/check-gh-api-version-header.sh
#
# @description Lint: every `gh api` invocation and `api.github.com`
# request in scripts/*.sh passes an explicit
# `X-GitHub-Api-Version: <date>` header.

# Lint: assert every `gh api` invocation and every `api.github.com`
# request in scripts/*.sh passes an explicit
# `X-GitHub-Api-Version: <date>` header.
#
# Without the header, GitHub treats the client as unversioned and may
# auto-promote it to a future API version whose response shape differs
# from what the script parses. Pre-commit + CI run this lint so any
# new offender trips before merging.
#
# Logic: coalesce backslash-continued lines into one logical statement,
# then for each non-comment statement that calls `gh api` or hits
# `api.github.com`, require an `X-GitHub-Api-Version` token somewhere
# in the same statement.
#
# Honors SCRIPTS_DIR_OVERRIDE for the test harness (defaults to
# scripts/, repo-relative).
#
# Exits 0 when every call carries the header, 1 on any offender, 2 when
# the scan could not run because the scripts directory is missing. A
# directory that was never scanned holds no offenders, so it must not
# borrow the violation code.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/awk-path.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
readonly REPO_ROOT
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-${REPO_ROOT}/scripts}"

# Self-exclude: this checker may mention `gh api` and `api.github.com`
# in its own help text and comments; it does not actually issue an
# API request. The checker script is filtered by basename.
readonly SELF_BASENAME='check-gh-api-version-header.sh'

if [[ ! -d ${SCRIPTS_DIR} ]]; then
  printf 'scripts dir not found: %s\n' "${SCRIPTS_DIR}" >&2
  exit 2
fi

# Scope tallies behind the clean-path summary: how many files the glob
# reached, how many statements were held to the header rule, and how many
# API mentions were set aside because they sit in a comment.
scanned=0
verified=0
commented=0
self_excluded='none'

# @description Scan a single shell file for offending statements, and add
# its statements to the scope tallies. Prints
# `file:line: <statement preview>` to stderr for each offender.
# Returns 0 on clean, 1 on any offender.
# @arg $1 path to .sh file
function scan_file() {
  local -r file="$1"
  # Coalesce backslash-continued lines into a single logical statement
  # before searching. POSIX-awk: collect a line that ends in `\` (after
  # optional trailing whitespace) into a buffer; emit the joined line
  # tagged with the original starting line number.
  local records
  records="$(
    awk '
      function flush() {
        if (buf == "") return
        stripped = buf
        sub(/^[[:space:]]+/, "", stripped)
        # Look for API call markers.
        is_call = (buf ~ /(^|[[:space:]])gh[[:space:]]+api([[:space:]]|$)/ ||
          buf ~ /api\.github\.com/)
        # A comment naming an API call is a mention, not a call. Report
        # it as set aside so the caller can say why a file with API text
        # in it contributed no verified call site.
        if (substr(stripped, 1, 1) == "#") {
          if (is_call) printf "comment:%d:\n", start
          buf = ""; start = 0; return
        }
        if (is_call) {
          # Require an explicit version header somewhere in the
          # statement.
          if (buf ~ /X-GitHub-Api-Version/) {
            printf "header:%d:\n", start
          } else {
            # Trim to one-line preview for the error message.
            preview = buf
            gsub(/[[:space:]]+/, " ", preview)
            if (length(preview) > 120) preview = substr(preview, 1, 117) "..."
            printf "offender:%d: %s\n", start, preview
          }
        }
        buf = ""; start = 0
      }
      {
        line = $0
        if (start == 0) start = NR
        # Strip trailing CR for safety.
        sub(/\r$/, "", line)
        # Continuation: ends in `\` (optionally followed by whitespace).
        if (line ~ /\\[[:space:]]*$/) {
          sub(/\\[[:space:]]*$/, "", line)
          buf = buf line " "
          next
        }
        buf = buf line
        flush()
      }
      END { flush() }
    ' "$(awk_path "${file}")"
  )"

  scanned=$((scanned + 1))

  local offenders=0
  local entry kind rest lineno preview
  while IFS= read -r entry; do
    [[ -z ${entry} ]] && continue
    kind="${entry%%:*}"
    rest="${entry#*:}"
    case ${kind} in
    header) verified=$((verified + 1)) ;;
    comment) commented=$((commented + 1)) ;;
    offender)
      offenders=$((offenders + 1))
      lineno="${rest%%:*}"
      preview="${rest#*: }"
      printf '%s:%s: missing X-GitHub-Api-Version header: %s\n' \
        "${file}" "${lineno}" "${preview}" >&2
      ;;
    esac
  done <<<"${records}"

  ((offenders == 0))
}

failed=0
shopt -s nullglob
declare -a repo_scripts=()
glob_into repo_scripts 'repo shell scripts' "${SCRIPTS_DIR}/*.sh"
for sh in "${repo_scripts[@]}"; do
  base="${sh##*/}"
  if [[ ${base} == "${SELF_BASENAME}" ]]; then
    self_excluded="${base}"
    continue
  fi
  scan_file "${sh}" || failed=$((failed + 1))
done
shopt -u nullglob

if ((failed > 0)); then
  printf '\n%d script(s) call the GitHub API without an explicit X-GitHub-Api-Version header.\n' \
    "${failed}" >&2
  printf 'Add `--header '\''X-GitHub-Api-Version: 2022-11-28'\''` (or matching API version) to each call.\n' >&2
  exit 1
fi

# A clean run reports the scope it covered, not just the verdict: a tree
# whose API calls all carry the header and a tree whose only API text
# sits in comments both pass, and the counts are what tell an operator
# which one the run actually saw. The self-exclusion is named because a
# file this lint never reads is the one place a regression could hide.
printf '%s: scanned %d script(s); %d API call site(s) carry an explicit header; %d comment mention(s) skipped; self-excluded: %s\n' \
  'gh-api-version-header' "${scanned}" "${verified}" "${commented}" \
  "${self_excluded}"
exit 0
