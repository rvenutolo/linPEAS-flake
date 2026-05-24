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

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
readonly REPO_ROOT
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-${REPO_ROOT}/scripts}"

# Self-exclude: this checker may mention `gh api` and `api.github.com`
# in its own help text and comments; it does not actually issue an
# API request. The checker script is filtered by basename.
readonly SELF_BASENAME='check-gh-api-version-header.sh'

if [[ ! -d ${SCRIPTS_DIR} ]]; then
  printf 'scripts dir not found: %s\n' "${SCRIPTS_DIR}" >&2
  exit 1
fi

# @description Scan a single shell file for offending statements.
# Prints `file:line: <statement preview>` to stderr for each.
# Returns 0 on clean, 1 on any offender.
# @arg $1 path to .sh file
function scan_file() {
  local -r file="$1"
  # Coalesce backslash-continued lines into a single logical statement
  # before searching. POSIX-awk: collect a line that ends in `\` (after
  # optional trailing whitespace) into a buffer; emit the joined line
  # tagged with the original starting line number.
  local offenders
  offenders="$(
    awk '
      function flush() {
        if (buf == "") return
        # Skip pure-comment statements.
        stripped = buf
        sub(/^[[:space:]]+/, "", stripped)
        if (substr(stripped, 1, 1) == "#") { buf = ""; start = 0; return }
        # Look for API call markers.
        if (buf ~ /(^|[[:space:]])gh[[:space:]]+api([[:space:]]|$)/ ||
            buf ~ /api\.github\.com/) {
          # Require an explicit version header somewhere in the
          # statement.
          if (buf !~ /X-GitHub-Api-Version/) {
            # Trim to one-line preview for the error message.
            preview = buf
            gsub(/[[:space:]]+/, " ", preview)
            if (length(preview) > 120) preview = substr(preview, 1, 117) "..."
            printf "%d: %s\n", start, preview
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
    ' "${file}"
  )"

  if [[ -z ${offenders} ]]; then
    return 0
  fi

  while IFS= read -r entry; do
    [[ -z ${entry} ]] && continue
    local lineno="${entry%%:*}"
    local preview="${entry#*: }"
    printf '%s:%s: missing X-GitHub-Api-Version header: %s\n' \
      "${file}" "${lineno}" "${preview}" >&2
  done <<<"${offenders}"
  return 1
}

failed=0
shopt -s nullglob
for sh in "${SCRIPTS_DIR}"/*.sh; do
  base="${sh##*/}"
  if [[ ${base} == "${SELF_BASENAME}" ]]; then
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
exit 0
