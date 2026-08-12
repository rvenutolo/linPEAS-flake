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
# Exits 0 if every listed workflow is clean, 1 on a path filter, 2 when
# the doc that names the workflows is not there to read.
set -Eeuo pipefail
IFS=$'\n\t'

readonly doc='docs/security/required-checks.md'

if [[ ! -f ${doc} ]]; then
  printf 'required-checks-no-paths lint: %s missing\n' "${doc}" >&2
  exit 2
fi

# @description Read the doc's table rows matching an awk pattern, take
# column 4, dedupe, and load the result into the `workflows` array. The
# pipeline is captured rather than fed to `mapfile` through a process
# substitution, whose subshell would swallow a dead awk and leave the
# lint reporting an empty table as a clean one.
# @arg $1 awk program
function load_workflows() {
  local rows
  if ! rows="$(awk -F'|' "$1" "${doc}" | sort --unique)"; then
    printf 'required-checks-no-paths lint: could not read the workflow table in %s\n' "${doc}" >&2
    exit 2
  fi
  workflows=()
  # An empty capture read by `<<<` still yields one line, so the array
  # would gain a phantom entry and the emptiness test below would never
  # fire.
  if [[ -n ${rows} ]]; then
    mapfile -t workflows <<<"${rows}"
  fi
}

# Parse markdown table column 4 (`.github/workflows/<file>`) — dedupe.
# shellcheck disable=SC2016 # awk program: `$4` is an awk field, not a shell expansion
load_workflows '/^\|[[:space:]]*\.github\/workflows\// {gsub(/[[:space:]]+/, "", $4); print $4}'

if ((${#workflows[@]} == 0)); then
  # Tests reference fixtures under tests/fixtures/required-checks/ — accept
  # that form too. Parse any row whose 4th column ends in `.yml`.
  # shellcheck disable=SC2016 # awk program: `$4` is an awk field, not a shell expansion
  load_workflows '/\.yml[[:space:]]*\|/ {gsub(/[[:space:]]+/, "", $4); print $4}'
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
