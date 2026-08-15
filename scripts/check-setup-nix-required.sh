#!/usr/bin/env bash
# scripts/check-setup-nix-required.sh
#
# @description Lint: every workflow installing Nix goes through the
# composite `./.github/actions/setup-nix` — no vendor Nix-installer
# action directly — and passes
# `github-token: ${{ secrets.GITHUB_TOKEN }}`.

# Asserts every workflow that installs Nix does so through the
# composite `./.github/actions/setup-nix` and passes
# `github-token: ${{ secrets.GITHUB_TOKEN }}`. Calling any vendor
# Nix-installer action directly from a workflow is forbidden — that
# path skips the composite's authenticated-token injection and its
# hardening, so flake-input fetches run unauthenticated and hit
# HTTP 401 under runner-IP-pool contention. See
# docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift, 2 on missing yq.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly DEFAULT_DIR=".github/workflows"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"
# shellcheck disable=SC2016  # single quotes intentional: literal string, no expansion wanted
readonly EXPECTED_TOKEN='${{ secrets.GITHUB_TOKEN }}'
readonly COMPOSITE="./.github/actions/setup-nix"
# Nix-installer actions a workflow must not call directly. Matched
# case-insensitively against the action path (the part before `@`).
# The installers this covers by name:
#   cachix/install-nix-action
#   DeterminateSystems/nix-installer-action
#   DeterminateSystems/determinate-nix-action
#   nixbuild/nix-quick-install-action
# The alternatives are the family patterns those names share, so an
# unlisted vendor publishing the same kind of action is caught too.
readonly INSTALLER_RE='install-nix|nix-installer|nix-quick-install|determinate-nix'

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
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' "${DIR}/*.yml" "${DIR}/*.yaml"
for f in "${workflow_files[@]}"; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  # 1) Any direct Nix-installer action use is forbidden.
  # shellcheck disable=SC2016  # single quotes intentional: yq expression, no bash expansion wanted
  if ! uses_rows="$(yq -r '
    .jobs // {} | to_entries[] |
    .key as $job |
    (.value.steps // []) [] |
    [$job, (.uses // "null")] | @tsv
  ' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  while IFS=$'\t' read -r job step_uses; do
    [[ -z ${step_uses} || ${step_uses} == "null" ]] && continue
    [[ ${step_uses} == "${COMPOSITE}" ]] && continue
    action_path="${step_uses%%@*}"
    if [[ ${action_path,,} =~ ${INSTALLER_RE} ]]; then
      printf '%s: job %q: %s installs Nix outside the composite; use ./.github/actions/setup-nix\n' \
        "${f}" "${job}" "${step_uses}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${uses_rows}"

  # 2) Every ./.github/actions/setup-nix caller must pass the exact token.
  # shellcheck disable=SC2016  # single quotes intentional: yq expression, no bash expansion wanted
  if ! token_rows="$(yq -r '
    .jobs // {} | to_entries[] |
    .key as $job |
    (.value.steps // []) [] |
    select(.uses == "./.github/actions/setup-nix") |
    [$job, (.with["github-token"] // "null")] | @tsv
  ' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
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
  done <<<"${token_rows}"
done

if ((failed > 0)); then
  printf 'check-setup-nix-required: %d violation(s)\n' "${failed}" >&2
  exit 1
fi
printf 'check-setup-nix-required: clean\n'
