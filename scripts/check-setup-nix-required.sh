#!/usr/bin/env bash
# scripts/check-setup-nix-required.sh
#
# Asserts every workflow that installs Nix does so through the
# composite `./.github/actions/setup-nix` and passes
# `github-token: ${{ secrets.GITHUB_TOKEN }}`. Direct use of
# `cachix/install-nix-action` from a workflow is forbidden — that
# path skips the access-token injection and is the root cause of
# the recurring HTTP 401 flake-input fetches under runner-IP-pool
# contention. See docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift, 2 on missing yq.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_DIR=".github/workflows"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"
# shellcheck disable=SC2016  # single quotes intentional: literal string, no expansion wanted
readonly EXPECTED_TOKEN='${{ secrets.GITHUB_TOKEN }}'

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

# Strip whitespace inside `${{ ... }}` so equivalent forms compare equal.
function normalize_expr() {
  local s="$1"
  s="${s//$'\n'/ }"
  printf '%s' "${s}" | sed -E 's/\$\{\{[[:space:]]*/\${{ /g; s/[[:space:]]*\}\}/ }}/g'
}

failed=0
shopt -s nullglob
for f in "${DIR}"/*.yml "${DIR}"/*.yaml; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  # 1) Any direct cachix/install-nix-action use is forbidden.
  # shellcheck disable=SC2016  # single quotes intentional: yq expression, no bash expansion wanted
  while IFS=$'\t' read -r job step_uses; do
    [[ -z ${step_uses} || ${step_uses} == "null" ]] && continue
    if [[ ${step_uses} == cachix/install-nix-action* ]]; then
      printf '%s: job %q: direct cachix/install-nix-action forbidden; use ./.github/actions/setup-nix\n' \
        "${f}" "${job}" >&2
      failed=$((failed + 1))
    fi
  done < <(yq -r '
    .jobs // {} | to_entries[] |
    .key as $job |
    (.value.steps // []) [] |
    [$job, (.uses // "null")] | @tsv
  ' "${f}")

  # 2) Every ./.github/actions/setup-nix caller must pass the exact token.
  # shellcheck disable=SC2016  # single quotes intentional: yq expression, no bash expansion wanted
  while IFS=$'\t' read -r job token; do
    [[ -z ${job} ]] && continue
    if [[ ${token} == "null" || -z ${token} ]]; then
      printf '%s: job %q: setup-nix caller missing github-token input\n' \
        "${f}" "${job}" >&2
      failed=$((failed + 1))
      continue
    fi
    norm="$(normalize_expr "${token}")"
    if [[ ${norm} != "${EXPECTED_TOKEN}" ]]; then
      printf '%s: job %q: setup-nix caller has wrong github-token (got %q, want %q)\n' \
        "${f}" "${job}" "${norm}" "${EXPECTED_TOKEN}" >&2
      failed=$((failed + 1))
    fi
  done < <(yq -r '
    .jobs // {} | to_entries[] |
    .key as $job |
    (.value.steps // []) [] |
    select(.uses == "./.github/actions/setup-nix") |
    [$job, (.with["github-token"] // "null")] | @tsv
  ' "${f}")
done

if ((failed > 0)); then
  printf 'check-setup-nix-required: %d violation(s)\n' "${failed}" >&2
  exit 1
fi
printf 'check-setup-nix-required: clean\n'
