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
# Exits 0 if every listed workflow is clean. Exits 1 on a path filter, on
# a doc that lists no workflow, on a listed workflow whose file is
# missing, and on one `yq` cannot evaluate: that workflow is named with
# the status `yq` exited with, and the scan goes on to the next. Exits 2
# when the doc that names the workflows is not there to read.
set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"

# An absent `yq` fails every paths/paths-ignore read, which would report
# each listed workflow as one it could not evaluate. That is a tool this
# run lacks, not a fact about the workflows.
require_tool yq

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
  if ! rows="$(awk -F'|' "$1" "$(awk_path "${doc}")" | sort --unique)"; then
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

# The `on:` node every read starts from, with its aliases resolved. It
# is the one root key that is `on` or an alias of `on`: a root holding
# more than one makes `yq` fail ("on: is given more than once"), and
# `.on` is read first so that a root that is not a map fails the read.
# `explode`, handed that node alone, resolves one level of aliases per
# pass: the aliases a node holds, not those inside what they stand for.
# So the node goes through sixteen passes, and one that still holds an
# alias after them is refused by `yq` with an error rather than read. A
# file `yq` reads through this is never passed with an alias left in it.
# shellcheck disable=SC2016 # yq program literal; its $ names are yq variables
readonly ON_NODE='.on as $plain | [to_entries[] | select((.key | explode(.)) == "on") | .value] as $all | with(select($all | length > 1); error("on: is given more than once")) | ($all | .[0]) as $n | [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16][] as $i ireduce ($n; explode(.)) | with(select([... | select(kind == "alias")] | length > 0); error("on: holds an alias nested too deep to resolve"))'

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

  # The answer is the text `yq` prints, read only once its status says
  # the read happened. Judged by status alone (`--exit-status`), an
  # expression that is false and a `yq` that failed both exit 1, and a
  # workflow nothing read would be scored clean. The `select` keeps an
  # `on:` written as a list from failing the read, where `yq` cannot
  # index by key: a list holds no filter, so it prints nothing. It tests
  # the node's kind, not its tag, so a map carrying a tag of its own is
  # still read. It starts from ON_NODE, so a trigger or a filter written
  # through an anchor is read as the map it stands for; `explode` is
  # handed `on:` alone, so a merge key `yq` cannot resolve elsewhere in
  # the file does not fail this read.
  yq_status=0
  has_filter="$(yq "${ON_NODE}"'
    | select(kind == "map") | .pull_request | (
      has("paths") or has("paths-ignore")
    )
  ' "${resolved}")" || yq_status=$?
  if ((yq_status != 0)); then
    printf 'required-checks-no-paths lint: %s: could not evaluate workflow with yq (malformed?): yq exited %d\n' \
      "${resolved}" "${yq_status}" >&2
    failed=1
    continue
  fi
  # A file holding several documents prints an answer for each whose
  # `on:` is a map; any of them declaring a filter is the finding.
  if [[ $'\n'"${has_filter}"$'\n' == *$'\n'true$'\n'* ]]; then
    printf 'required-checks-no-paths lint: %s declares paths/paths-ignore under pull_request\n' \
      "${resolved}" >&2
    failed=1
  fi
done

exit "${failed}"
