#!/usr/bin/env bash
# scripts/check-required-checks-no-paths.sh
#
# @description Lint: no workflow listed in
# docs/security/required-checks.md declares `paths:` or
# `paths-ignore:` under `on.pull_request:` — avoiding the auto-merge
# path-filter skip trap.

# Verify that no workflow listed in docs/security/required-checks.md
# declares `paths:` or `paths-ignore:` under `on.pull_request:`. Such filters
# would create the auto-merge path-filter trap (skipped checks merging with
# zero coverage on path-narrow PRs).
#
# Exits 0 if every listed workflow is clean, 1 otherwise.
set -Eeuo pipefail
IFS=$'\n\t'

readonly doc='docs/security/required-checks.md'

if [[ ! -f ${doc} ]]; then
  printf 'required-checks-no-paths lint: %s missing\n' "${doc}" >&2
  exit 1
fi

# Parse markdown table column 4 (`.github/workflows/<file>`) — dedupe.
mapfile -t workflows < <(
  awk -F'|' '/^\|[[:space:]]*\.github\/workflows\// {gsub(/[[:space:]]+/, "", $4); print $4}' \
    "${doc}" | sort --unique
)

if ((${#workflows[@]} == 0)); then
  # Tests reference fixtures under tests/fixtures/required-checks/ — accept
  # that form too. Parse any row whose 4th column ends in `.yml`.
  mapfile -t workflows < <(
    awk -F'|' '/\.yml[[:space:]]*\|/ {gsub(/[[:space:]]+/, "", $4); print $4}' \
      "${doc}" | sort --unique
  )
fi

if ((${#workflows[@]} == 0)); then
  printf 'required-checks-no-paths lint: no workflows found in %s — aborting\n' "${doc}" >&2
  exit 1
fi

failed=0
for wf in "${workflows[@]}"; do
  # Test harness writes a fixture filename into the doc; resolve relative
  # to .github/workflows/ first, then to tests/fixtures/required-checks/.
  wf_base="$(basename "${wf}")"
  candidates=(
    ".github/workflows/${wf}"
    "${wf}"
    "tests/fixtures/required-checks/${wf}"
    ".github/workflows/${wf_base}"
    "tests/fixtures/required-checks/${wf_base}"
  )
  resolved=""
  for c in "${candidates[@]}"; do
    if [[ -f ${c} ]]; then
      resolved="${c}"
      break
    fi
  done

  if [[ -z ${resolved} ]]; then
    printf 'required-checks-no-paths lint: %s listed in %s but file missing\n' "${wf}" "${doc}" >&2
    failed=1
    continue
  fi

  if yq --exit-status '
    .on.pull_request | (
      has("paths") or has("paths-ignore")
    )
  ' "${resolved}" >/dev/null 2>&1; then
    printf 'required-checks-no-paths lint: %s declares paths/paths-ignore under pull_request\n' \
      "${resolved}" >&2
    failed=1
  fi
done

exit "${failed}"
