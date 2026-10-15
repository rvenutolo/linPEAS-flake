#!/usr/bin/env bash
# @subject scripts/lib/job-keys.sh
# tests/lib-job-keys.test.sh — proves scripts/lib/job-keys.sh names the
# first job key the job list cannot carry (a line break, a carriage
# return, an empty key, a key that is not a scalar, a merge key) and the
# first key of a job-id list that the list cannot carry, reads `jobs:`
# written as an alias and a root key written as an alias of `jobs`,
# refuses a root `jobs:` given twice, prints nothing for carriable keys or a
# `jobs:` that is no map, and reads a merge list first mapping wins
# without yq's warning that the flag is false.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly LIB="${REPO_ROOT}/scripts/lib/job-keys.sh"

failures=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

# @description Read a workflow body through the library and compare the
# output with the wanted text.
# @arg $1 scenario name  @arg $2 workflow body  @arg $3 snippet run after
#   sourcing the library (given the workflow path as $1)  @arg $4 wanted
#   stdout, one line
function expect_out() {
  local -r name="$1" body="$2" snippet="$3" want="$4"
  local -r wf="${work}/${name}.yml" out="${work}/${name}.out" err="${work}/${name}.err" outcome="${work}/${name}.outcome"
  local rc=0
  printf '%s' "${body}" >"${wf}"
  # The output leads with the scenario name, so no two scenarios share one.
  bash -c 'set -Eeuo pipefail; source "$1"; got="$('"${snippet}"')"; printf "%s: %s\n" "$3" "${got}"' _ "${LIB}" "${wf}" "${name}" >"${out}" 2>"${err}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${name}: ${want}" "${outcome}" "${out}" "${err}"
  if [[ ${rc} -eq 0 && "$(<"${out}")" == "${name}: ${want}" && ! -s ${err} ]]; then
    printf 'PASS: %s\n' "${name}"
  else
    printf 'FAIL: %s: exit %d, want stdout %q\n  got: %s\n  err: %s\n' "${name}" "${rc}" "${want}" "$(<"${out}")" "$(<"${err}")" >&2
    failures=$((failures + 1))
  fi
}

# shellcheck disable=SC2016 # snippet is bash source text for a child process
readonly ODD='first_odd_job_key "$2"'
expect_out line-break $'jobs:\n  ok: {a: 1}\n  "a\\nb": {x: 1}\n' "${ODD}" '"a\nb"'
expect_out carriage-return $'jobs:\n  "a\\rb": {x: 1}\n' "${ODD}" '"a\rb"'
expect_out tab $'jobs:\n  "a\\tb": {x: 1}\n' "${ODD}" '"a\tb"'
expect_out empty $'jobs:\n  "": {x: 1}\n' "${ODD}" '""'
expect_out block-sequence $'jobs:\n  ? - a\n    - b\n  : {y: 1}\n' "${ODD}" '"- a\n- b"'
expect_out merge-key $'x: &b\n  j: {a: 1}\njobs:\n  <<: *b\n' "${ODD}" '"<<"'
expect_out aliased-jobs $'x: &b\n  "a\\nb": {a: 1}\njobs: *b\n' "${ODD}" '"a\nb"'
expect_out first-of-several $'jobs:\n  "": {x: 1}\n  "a\\nb": {x: 1}\n' "${ODD}" '""'
expect_out flow-sequence-key $'jobs:\n  ? [a, b]\n  : {y: 1}\n' "${ODD}" '"[a, b]"'
expect_out flow-map-key $'jobs:\n  ? {a: 1}\n  : {y: 1}\n' "${ODD}" '"{a: 1}"'
expect_out nul $'jobs:\n  "a\\0b": {x: 1}\n' "${ODD}" '"a\u0000b"'
expect_out aliased-key $'x: &k "a\\nb"\njobs:\n  *k : {x: 1}\n' "${ODD}" '"a\nb"'
expect_out jobs-scalar $'jobs: hello\n' "${ODD}" ''
expect_out carriable $'jobs:\n  ok: {a: 1}\n  other-job_2: {a: 1}\n' "${ODD}" ''
expect_out jobs-not-a-map $'jobs: [1, 2]\n' "${ODD}" ''
expect_out no-jobs $'on: push\n' "${ODD}" ''
# One line however many documents: a clean first document must not lead
# the output with an empty line.
expect_out second-document-key $'jobs:\n  ok: {a: 1}\n---\njobs:\n  "a\\nb": {x: 1}\n' "${ODD}" '"a\nb"'
expect_out later-document-merge $'jobs:\n  ok: {a: 1}\n---\nx: &b\n  j: {a: 1}\njobs:\n  <<: *b\n' "${ODD}" '"<<"'
expect_out clean-two-documents $'jobs:\n  ok: {a: 1}\n---\njobs:\n  fine: {a: 1}\n' "${ODD}" ''
# One line even when several documents each hold a refused key: the first
# is named and the rest are not.
expect_out two-odd-documents $'jobs:\n  "a\\nb": {x: 1}\n---\njobs:\n  "": {x: 1}\n' "${ODD}" '"a\nb"'
# A file yq cannot parse is a failure of the call, not an empty answer.
# shellcheck disable=SC2016 # snippet is bash source text for a child process
expect_out unparsable $'jobs: [\n' 'first_odd_job_key "$2" 2>/dev/null || printf "failed=%d" "$?"' 'failed=1'
# `jobs:` read through an alias is expanded once, and a merge list inside it
# must not make `yq` warn.
expect_out aliased-jobs-merge-list $'p: &P\n  permissions: {contents: write}\nq: &Q\n  permissions: {contents: read}\nx: &b\n  a:\n    <<: [*P, *Q]\njobs: *b\n' "${ODD}" ''

# A root key written as an alias of `jobs` is the `jobs:` node, as GitHub
# Actions reads it; a key given twice, one plain and one an alias, is
# refused by yq. A key whose text holds a `*` is compared as text, not as
# a pattern. A root merge key still brings `jobs:` in, and a root that is
# no map holds no `jobs:`.
# shellcheck disable=SC2016 # snippet is bash source text for a child process
readonly NODE_KEYS='yq eval "${YQ_MERGE_SPEC[@]}" "${JOBS_NODE}"" | keys | join(\",\")" "$2" 2>&1'
expect_out root-alias-key $'name: &k jobs\non: push\n*k :\n  a: {x: 1}\n' "${NODE_KEYS}" 'a'
expect_out root-alias-key-alias-value $'name: &k jobs\nx: &j {q: {x: 1}}\n*k : *j\n' "${NODE_KEYS}" 'q'
expect_out root-alias-key-given-twice $'name: &k jobs\njobs: {b: {x: 1}}\n*k : {a: {x: 1}}\n' "${NODE_KEYS} || true" 'Error: jobs: is given more than once'
expect_out root-alias-key-glob-text $'name: &k "j*"\n*k : {a: {x: 1}}\njobs: {b: {x: 1}}\n' "${NODE_KEYS}" 'b'
expect_out root-merge-key $'x: &b {jobs: {m: {x: 1}}}\n<<: *b\n' "${NODE_KEYS}" 'm'
# shellcheck disable=SC2016 # snippet is bash source text for a child process
expect_out root-scalar $'hello\n' 'yq eval "${YQ_MERGE_SPEC[@]}" "${JOBS_NODE}" "$2" 2>&1' 'null'
expect_out root-alias-key-odd $'name: &k jobs\n*k :\n  "": {x: 1}\n' "${ODD}" '""'

# A merge list is read first mapping wins, silently.
readonly PQ=$'p: &P\n  permissions: {contents: write}\nq: &Q\n  permissions: {contents: read}\n'
# shellcheck disable=SC2016 # snippet is bash source text for a child process
readonly READ='yq eval "${YQ_MERGE_SPEC[@]}" ".jobs.a.permissions.contents" "$2"'
expect_out merge-list-first-wins "${PQ}"$'jobs:\n  a:\n    <<: [*Q, *P]\n' "${READ}" 'read'
expect_out merge-list-first-wins-write "${PQ}"$'jobs:\n  a:\n    <<: [*P, *Q]\n' "${READ}" 'write'

# The keys a script lists are those of `jobs:` resolved through its
# aliases, so a merge key is read through to the jobs it brings in.
# shellcheck disable=SC2016 # snippet is bash source text for a child process
readonly UNLISTABLE='first_unlistable_job_key "$2"'
expect_out line-break-listed $'jobs:\n  ok: {a: 1}\n  "a\\nb": {x: 1}\n' "${UNLISTABLE}" '"a\nb"'
expect_out carriage-return-listed $'jobs:\n  "a\\rb": {x: 1}\n' "${UNLISTABLE}" '"a\rb"'
expect_out tab-listed $'jobs:\n  "a\\tb": {x: 1}\n' "${UNLISTABLE}" '"a\tb"'
expect_out empty-listed $'jobs:\n  "": {x: 1}\n' "${UNLISTABLE}" '""'
expect_out nul-listed $'jobs:\n  "a\\0b": {x: 1}\n' "${UNLISTABLE}" '"a\u0000b"'
expect_out sequence-key-listed $'jobs:\n  ? [a, b]\n  : {y: 1}\n' "${UNLISTABLE}" '"[a, b]"'
expect_out aliased-key-listed $'x: &k "a\\nb"\njobs:\n  *k : {x: 1}\n' "${UNLISTABLE}" '"a\nb"'
expect_out aliased-jobs-listed $'x: &b\n  "": {a: 1}\njobs: *b\n' "${UNLISTABLE}" '""'
expect_out merged-in-key-listed $'x: &b\n  "": {a: 1}\njobs:\n  <<: *b\n  ok: {a: 1}\n' "${UNLISTABLE}" '""'
expect_out merge-key-alone-listed $'x: &b\n  j: {a: 1}\njobs:\n  <<: *b\n' "${UNLISTABLE}" ''
expect_out second-document-listed $'jobs:\n  ok: {a: 1}\n---\njobs:\n  "a\\nb": {x: 1}\n' "${UNLISTABLE}" '"a\nb"'
expect_out carriable-listed $'jobs:\n  ok: {a: 1}\n  other-job_2: {a: 1}\n' "${UNLISTABLE}" ''
expect_out scalar-jobs-listed $'jobs: hello\n' "${UNLISTABLE}" ''
expect_out sequence-jobs-listed $'jobs: [a, b]\n' "${UNLISTABLE}" ''
expect_out no-jobs-listed $'on: push\n' "${UNLISTABLE}" ''
# shellcheck disable=SC2016 # snippet is bash source text for a child process
expect_out unparsable-listed $'jobs: [\n' 'first_unlistable_job_key "$2" 2>/dev/null || printf "failed=%d" "$?"' 'failed=1'
# A root key written as an alias of `jobs` is the `jobs:` node; one given
# twice, plain and as an alias, fails the read.
expect_out root-alias-key-listed $'name: &k jobs\n*k :\n  "": {x: 1}\n' "${UNLISTABLE}" '""'
# shellcheck disable=SC2016 # snippet is bash source text for a child process
expect_out root-alias-key-given-twice-listed $'name: &k jobs\njobs: {b: {x: 1}}\n*k : {"": {x: 1}}\n' 'first_unlistable_job_key "$2" 2>&1 || true' 'Error: jobs: is given more than once'

# The message names the file and the key.
# shellcheck disable=SC2016 # snippet is bash source text for a child process
expect_out message '' 'odd_job_key_message f.yml "\"<<\""' 'f.yml: jobs: holds a job key that is empty, holds a tab, a line break, a carriage return or a NUL, is not a scalar, or is a merge key, which GitHub Actions refuses; its jobs are not read (first: "<<")'

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
