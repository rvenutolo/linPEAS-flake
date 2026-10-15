# scripts/lib/job-keys.sh
#
# @description Shared reading rules for the `jobs:` map of a workflow.
# Several lints list the job keys one per line and read each key back,
# so a key the line cannot carry (an empty one, one holding a tab, a line
# break, a carriage return or a NUL, one that is not a scalar) is read as
# other names or as none,
# and a merge key (`<<`) directly under `jobs:` lists as the key `<<`
# while the jobs it brings in are never read. GitHub Actions refuses a
# job id outside `[A-Za-z_][A-Za-z0-9_-]*`, so no runnable workflow has
# such a key; a lint reads files GitHub has not validated, and counts the
# key as a finding instead of reading around it.
#
# A merge key given a list (`<<: [*P, *Q]`) with a conflicting key is
# read first mapping wins, as the YAML merge specification says. `yq`
# reads it last mapping wins unless it is given
# `--yaml-fix-merge-anchor-to-spec`, so the scripts that source this
# library pass `"${YQ_MERGE_SPEC[@]}"` on their reads of a workflow that
# follow a merge key. The flag also silences the warning `yq` prints when it is absent.
# Source after `set -Eeuo pipefail`.
# shellcheck shell=bash

readonly YQ_MERGE_SPEC=(--yaml-fix-merge-anchor-to-spec)

# A root key of a workflow, the text `@KEY@` standing for its name. It is
# the one root key that is the name or an alias of it, as GitHub Actions
# reads a root key written as an alias: a root holding more than one
# makes `yq` fail ("<name>: is given more than once"). With no such key
# it is `.<name>`, which is how a key a root merge key brings in is read,
# since the merged keys are not the root's own; a root that is no map
# holds none. The key's value is read through an alias: `explode` handed
# only that node resolves it in one pass, since an anchor cannot sit on
# an alias. An absent key reads as null rather than as nothing at all.
# A script reads one key with `${ROOT_KEY_NODE//@KEY@/<name>}`.
# shellcheck disable=SC2016 # yq program literal; its $ names are yq variables
readonly ROOT_KEY_NODE='.@KEY@ as $plain | [select(kind == "map") | to_entries[] | select((.key | explode(.)) == "@KEY@") | .value] as $all | with(select($all | length > 1); error("@KEY@: is given more than once")) | ($all + [$plain] | .[0]) | [(select(kind == "alias") | explode(.)), select(kind != "alias")] | .[0]'

# The `jobs:` node.
readonly JOBS_NODE="${ROOT_KEY_NODE//@KEY@/jobs}"

# Two `explode` passes read the job keys of a `jobs:` node. One pass
# replaces the aliases the node holds with what they stand for and leaves
# the aliases inside those copies, so a `jobs:` written as an alias, or
# one that merges in a map, still holds a key written as an alias after
# it. A second pass resolves those. A job key is a scalar, so a key alias
# stands for a scalar and no third level exists: a merge chain of any
# depth resolves in the same two passes.
# shellcheck disable=SC2034 # read by the scripts that source this library
readonly RESOLVE_JOB_ALIASES='explode(.) | explode(.)'

# A `yq` condition on a key: it is not a scalar, is empty, or holds a tab,
# a line break, a carriage return or a NUL. Such a key cannot be listed
# one per line and read back as itself.
readonly UNLISTABLE_JOB_KEY='kind != "scalar" or (tostring | test("^$|[\t\n\r\x00]"))'

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
  rows="$(yq eval "${YQ_MERGE_SPEC[@]}" "[${JOBS_NODE}"' | select(kind == "map") | to_entries[] | .key | explode(.) | select(tag == "!!merge" or '"${UNLISTABLE_JOB_KEY}"') | tostring | to_json(0)] | .[0] // ""' "$1")" || return
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
  printf '%s: jobs: holds a job key that is empty, holds a tab, a line break, a carriage return or a NUL, is not a scalar, or is a merge key, which GitHub Actions refuses; its jobs are not read (first: %s)\n' \
    "$1" "$2"
}

# @description Print the first key of the job ids a script lists that the
# list cannot carry, as a JSON string, or nothing when every key is
# carriable. The keys are those the job-id read returns: `jobs:` and the
# keys in it are resolved through `RESOLVE_JOB_ALIASES` first, so a merge
# key brings in the jobs it names, which are checked, and is not itself a
# key. A key is refused when it is not a scalar, is empty, or holds a tab,
# a line break, a carriage return or a NUL.
# @arg $1 workflow path
# @stdout the first refused key of the first document holding one, as one
# line of JSON, or nothing
# @exitcode 1 yq could not evaluate the file
function first_unlistable_job_key() {
  local rows line
  rows="$(yq eval "${YQ_MERGE_SPEC[@]}" '[(.jobs // {}) | '"${RESOLVE_JOB_ALIASES}"' | select(kind == "map") | to_entries[] | .key | select('"${UNLISTABLE_JOB_KEY}"') | tostring | to_json(0)] | .[0] // ""' "$1")" || return
  while IFS= read -r line; do
    if [[ -n ${line} ]]; then
      printf '%s\n' "${line}"
      return 0
    fi
  done <<<"${rows}"
}
