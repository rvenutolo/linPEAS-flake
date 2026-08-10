#!/usr/bin/env bash
# scripts/check-no-yq-procsub.sh
#
# @description Lint: no scripts/*.sh may feed a redirection from a yq
# process substitution (`< <(yq ...)`). A procsub's exit status is
# invisible to `set -Eeuo pipefail`, so a yq parse failure yields empty
# loop input and the calling check passes wholesale (fail-open). Use
# the capture-into-variable idiom (or a temp file for NUL-delimited
# output) so parse failures abort loudly.
#
# Honors SCRIPTS_DIR_OVERRIDE (default: scripts) for fixtures.
# Exit 0 clean, 1 on any hit, 2 on operational error.
set -Eeuo pipefail
IFS=$'\n\t'

readonly DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"
[[ -d ${DIR} ]] || {
  printf 'scripts dir not found: %s\n' "${DIR}" >&2
  exit 2
}

# The bracket-escaped `(` keeps this file's own pattern-definition
# line from matching itself.
readonly PATTERN='< <[(][[:space:]]*yq'
# Doc comments are allowed to name the banned idiom (e.g. explaining why
# a script uses the capture idiom instead); only live code is a hit.
readonly COMMENT_LINE='^[0-9]+:[[:space:]]*#'

failed=0
shopt -s nullglob
for f in "${DIR}"/*.sh; do
  while IFS= read -r hit; do
    [[ -z ${hit} ]] && continue
    printf '%s: yq process substitution feeds a redirection (fail-open under pipefail): %s\n' \
      "${f}" "${hit}" >&2
    failed=$((failed + 1))
  done <<<"$(grep --extended-regexp --line-number -- "${PATTERN}" "${f}" |
    grep --invert-match --extended-regexp -- "${COMMENT_LINE}" || true)"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d yq process-substitution site(s) found\n' "${failed}" >&2
  exit 1
fi
exit 0
