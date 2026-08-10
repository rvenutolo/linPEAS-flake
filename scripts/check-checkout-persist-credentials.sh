#!/usr/bin/env bash
# scripts/check-checkout-persist-credentials.sh
#
# @description Lint: every `actions/checkout` step in every workflow
# sets `with.persist-credentials: false` so the GITHUB_TOKEN is not
# left in `.git/config` for subsequent steps to read.

# Lint: every `actions/checkout` step in every workflow under
# `.github/workflows/*.yml` sets `with.persist-credentials: false`.
#
# Without that setting, `actions/checkout` writes the GITHUB_TOKEN
# into `.git/config` and leaves it on disk for the remainder of the
# job. Any subsequent step in the same job — including a third-party
# action or a shell injection in a `run:` — can read the token from
# the working tree.
#
# The check matches `uses:` lines that start with `actions/checkout@`
# (any ref shape). For each match, `with.persist-credentials` must
# be present and exactly the boolean `false`. Strings ("false"),
# missing keys, and `true` all fail.
#
# See docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_DIR=".github/workflows"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

failed=0
shopt -s nullglob
for f in "${DIR}"/*.yml "${DIR}"/*.yaml; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  # Capture yq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(yq ...)`: a process substitution's exit
  # status is not propagated under set -Eeuo pipefail, so a yq failure
  # (unparsable workflow, or a query that errors on a valid-but-odd
  # shape) would yield empty input and the check would pass silently.
  # shellcheck disable=SC2016 # yq expression: literal $ refs, not shell expansion
  if ! rows="$(yq eval '
    .jobs | to_entries[] as $j
    | $j.value.steps | to_entries[]
    | select(.value.uses // "" | test("^actions/checkout@"))
    | $j.key + "|" + (.key | tostring) + "|" + (.value.with."persist-credentials" | tag) + "|" + (.value.with."persist-credentials" | tostring)
  ' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  [[ -n ${rows} ]] || continue
  while IFS='|' read -r job idx tag val; do
    [[ -z ${job} ]] && continue
    case "${tag}" in
    '!!null')
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q step[%s] actions/checkout missing `with.persist-credentials: false`\n' \
        "${f}" "${job}" "${idx}" >&2
      failed=$((failed + 1))
      ;;
    '!!bool')
      if [[ ${val} != "false" ]]; then
        # shellcheck disable=SC2016 # literal backticks in human-readable prose
        printf '%s: job %q step[%s] actions/checkout has `persist-credentials: %s`; must be `false`\n' \
          "${f}" "${job}" "${idx}" "${val}" >&2
        failed=$((failed + 1))
      fi
      ;;
    '!!str')
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q step[%s] actions/checkout has string `persist-credentials: %q`; must be boolean `false`\n' \
        "${f}" "${job}" "${idx}" "${val}" >&2
      failed=$((failed + 1))
      ;;
    *)
      printf '%s: job %q step[%s] actions/checkout persist-credentials has unexpected shape (tag=%s, value=%s); must be boolean false\n' \
        "${f}" "${job}" "${idx}" "${tag}" "${val}" >&2
      failed=$((failed + 1))
      ;;
    esac
  done <<<"${rows}"
done
shopt -u nullglob

if ((failed > 0)); then
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf '%d actions/checkout step(s) missing `persist-credentials: false`\n' "${failed}" >&2
  exit 1
fi
exit 0
