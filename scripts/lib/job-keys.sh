# scripts/lib/job-keys.sh
#
# @description Shared reading rules for the `jobs:` map of a workflow.
# Several lints list the job keys one per line and read each key back,
# so a key the line cannot carry (an empty one, one holding a line break
# or a tab, one that is not a scalar) is read as other names or as none,
# and a merge key (`<<`) directly under `jobs:` lists as the key `<<`
# while the jobs it brings in are never read. GitHub Actions refuses a
# job id outside `[A-Za-z_][A-Za-z0-9_-]*`, so no runnable workflow has
# such a key; a lint reads files GitHub has not validated, and counts the
# key as a finding instead of reading around it.
#
# A merge key given a list (`<<: [*P, *Q]`) with a conflicting key is
# read first mapping wins, as the YAML merge specification says. `yq`
# reads it last mapping wins unless it is given
# `--yaml-fix-merge-anchor-to-spec`, so every `yq` read of a workflow
# that follows a merge key passes `"${YQ_MERGE_SPEC[@]}"`. The flag also
# silences the warning `yq` prints when it is absent.
# Source after `set -Eeuo pipefail`.
# shellcheck shell=bash

readonly YQ_MERGE_SPEC=(--yaml-fix-merge-anchor-to-spec)

# The `jobs:` node, read through an alias: `explode` handed only that
# node resolves it in one pass, since an anchor cannot sit on an alias.
readonly JOBS_NODE='[(.jobs | select(kind == "alias") | explode(.)), (.jobs | select(kind != "alias"))] | .[0]'

# @description Print the first job key the job list cannot carry, as a
# JSON string, or nothing when every key is carriable. A key is refused
# when it is a merge key, is not a scalar, is empty, or holds a tab, a
# line break, a carriage return or a NUL. Each key is resolved through an
# alias first. A `jobs:` that is not a map holds no keys.
# @arg $1 workflow path
# @stdout the first refused key of the first document holding one, as one
# line of JSON, or nothing
# @exitcode 1 yq could not evaluate the file
function first_odd_job_key() {
  local rows line
  rows="$(yq eval "${YQ_MERGE_SPEC[@]}" "[${JOBS_NODE}"' | select(kind == "map") | to_entries[] | .key | explode(.) | select(tag == "!!merge" or kind != "scalar" or (tostring | test("^$|[\t\n\r\x00]"))) | tostring | to_json(0)] | .[0] // ""' "$1")" || return
  while IFS= read -r line; do
    if [[ -n ${line} ]]; then
      printf '%s\n' "${line}"
      return 0
    fi
  done <<<"${rows}"
}

# @description Print the finding for a refused job key.
# @arg $1 workflow path
# @arg $2 the key as JSON, from `first_odd_job_key`
function odd_job_key_message() {
  printf '%s: jobs: holds a job key that is empty, holds a line break or a tab, is not a scalar, or is a merge key, which GitHub Actions refuses; its jobs are not read (first: %s)\n' \
    "$1" "$2"
}
