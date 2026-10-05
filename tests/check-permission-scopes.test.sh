#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-permission-scopes.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/permission-scopes"

# Forward-pass cases run filtered to a single fixture in the shared dir.
function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
    SCOPE_ALLOWLIST_OVERRIDE="${FIXTURES}/allowlist.yml" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

# Stale detection lives in the script's reverse pass, which is skipped under
# WORKFLOW_FILE_FILTER (so a single-fixture forward run does not false-positive
# on the shared allowlist's other entries). To genuinely exercise stale
# detection, the stale case runs UNFILTERED against its own isolated subdir
# (tests/fixtures/permission-scopes/stale/) holding just the stale workflow
# plus a matching allowlist, so the reverse pass runs and flags the entry.
function expect_unfiltered() {
  local -r dir="$1" allowlist="$2" want_exit="$3" want_msg="$4" label="$5"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" \
    SCOPE_ALLOWLIST_OVERRIDE="${allowlist}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${label}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${label}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${label}"
}

# Forward-pass-only case with a non-default allowlist: WORKFLOW_FILE_FILTER
# skips the reverse pass, so the verdict can only come from the per-job
# allowlist read in the forward pass. Scored on a string the output must
# carry and one it must not, because the unchecked read fails by printing
# a different, wrong diagnostic rather than by printing nothing.
function expect_forward_allowlist() {
  local -r fixture="$1" allowlist="$2" want_exit="$3" want_msg="$4" want_absent="$5" label="$6"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
    SCOPE_ALLOWLIST_OVERRIDE="${allowlist}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${label}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${label}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_absent} && ${got_stderr} == *"${want_absent}"* ]]; then
    printf 'FAIL %s: stderr must not carry %q\n  got: %s\n' "${label}" "${want_absent}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${label}"
}

expect good.yml 0 ""
expect good-read-only.yml 0 ""
expect bad-over-grant.yml 1 "contents"
expect bad-job-not-in-allowlist.yml 1 "writer"
expect_unfiltered "${FIXTURES}/stale" "${FIXTURES}/stale/allowlist.yml" 1 "stale" bad-stale-allowlist.yml

# An allowlist scope list that is out of sorted order is drift, reported
# with the offending workflow/job. Runs unfiltered like the stale case,
# because the sortedness pass shares the reverse pass's filter skip.
expect_unfiltered "${FIXTURES}/unsorted" "${FIXTURES}/unsorted/allowlist.yml" 1 "not sorted" bad-unsorted-allowlist.yml

# A workflow yq cannot parse must fail loud, not empty the forward scan
# silently.
expect bad-malformed.yml 1 "could not evaluate"

# Scalar `permissions:` at job level: only read-all is a legitimate
# scalar value. write-all (and any other scalar) is a violation; the
# scan must not silently drop it because the scalar breaks the
# map-shaped yq query.
expect bad-scalar-writeall.yml 1 "scalar"
expect good-scalar-readall.yml 0 ""

# An unparsable allowlist file is a precondition failure (tooling
# error), not a workflow-scan drift — exit 2, not 1.
expect_unfiltered "${FIXTURES}/malformed-allowlist" "${FIXTURES}/malformed-allowlist/allowlist.yml" 2 "" bad-malformed-allowlist

# The forward pass reads the allowlist too, once per write scope a job
# grants, and must reach the same verdict. This case drives that read
# specifically: the reverse pass is skipped under WORKFLOW_FILE_FILTER,
# so nothing else opens the allowlist, and good.yml grants a write scope
# so the read actually happens. An unchecked read yields an empty scope
# list, which matches nothing, so the run would end at exit 1 accusing a
# compliant workflow of an over-grant — hence the must-not-carry string.
expect_forward_allowlist good.yml "${FIXTURES}/malformed-allowlist/allowlist.yml" 2 \
  "could not evaluate allowlist" "grants write scope" bad-malformed-allowlist-forward

expect no-such-workflow.yml 2 'selected 0 of'

# --- shapes of a job's permissions:, built at run time ---------------
# A formatter would rewrite a tagged or quoted node checked in as a
# fixture. Each scenario writes a numbered workflow beside an allowlist
# granting job a `contents` and nothing else, runs the forward pass on
# it, and compares the exit code and the whole of stderr.

# @description Run the forward pass on one built workflow.
# @arg $1 scenario name
# @arg $2 workflow text (printf format, no arguments)
# @arg $3 expected exit code
# @arg $4 expected stderr: %W stands for the workflow path, %A for the
#   allowlist path
function expect_built() {
  local -r name="$1" text="$2" want_exit="$3" want="$4"
  local dir got_exit=0 got_stderr base expected
  SCENARIO_N=$((SCENARIO_N + 1))
  dir="$(mktemp --directory)"
  base="wf-${SCENARIO_N}.yml"
  # shellcheck disable=SC2059 # the workflow text is the format
  printf "${text}" >"${dir}/${base}"
  printf '%s:\n  a:\n    - contents\n' "${base}" >"${dir}/allowlist.yml"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" WORKFLOW_FILE_FILTER="${base}" \
    SCOPE_ALLOWLIST_OVERRIDE="${dir}/allowlist.yml" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  expected="${want//%W/${dir}/${base}}"
  expected="${expected//%A/${dir}/allowlist.yml}"
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${expected}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  got:  %q\n  want: %q\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" "${expected}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}
SCENARIO_N=0
readonly ONE='1 permission-scope violation(s) found'
readonly HEAD=$'on: push\njobs:\n'

# @description A scenario whose job a passes: a sentinel job granting a
# scope the allowlist does not list follows it, so the run ends in that
# one finding alone.
# @arg $1 scenario name
# @arg $2 workflow text ending in its jobs: block (printf format)
function expect_passes() {
  expect_built "$1" "$2"'  sentinel:\n    permissions: {issues: write}\n' 1 \
    "%W: job sentinel grants write scope issues not allowed by %A
${ONE}"
}

expect_passes 'a map carrying a tag of its own is read scope by scope' \
  "${HEAD}"'  a:\n    permissions: !x {contents: write}\n'
expect_built 'a tagged map granting an unlisted scope is an over-grant' \
  "${HEAD}"'  a:\n    permissions: !x {pull-requests: write}\n' 1 \
  "%W: job a grants write scope pull-requests not allowed by %A
${ONE}"
expect_built 'an empty scalar carrying the map tag is no map' \
  "${HEAD}""  a:\\n    permissions: !!map ''\\n" 1 \
  "%W: job a permissions has unexpected shape (kind=scalar, tag=\"!!map\", value=\"\"); only a map or the string read-all is allowed
${ONE}"
expect_built 'read-all carrying the map tag is no string' \
  "${HEAD}"'  a:\n    permissions: !!map read-all\n' 1 \
  "%W: job a permissions has unexpected shape (kind=scalar, tag=\"!!map\", value=\"read-all\"); only a map or the string read-all is allowed
${ONE}"
expect_built 'read-all carrying a tag of its own is no string' \
  "${HEAD}"'  a:\n    permissions: !x read-all\n' 1 \
  "%W: job a permissions has unexpected shape (kind=scalar, tag=\"!x\", value=\"read-all\"); only a map or the string read-all is allowed
${ONE}"
expect_built 'a list carrying the string tag is no string' \
  "${HEAD}"'  a:\n    permissions: !!str [contents]\n' 1 \
  "%W: job a permissions has unexpected shape (kind=seq, tag=\"!!str\", value=\"\"); only a map or the string read-all is allowed
${ONE}"
expect_built 'a string other than read-all is a scalar grant' \
  "${HEAD}"'  a:\n    permissions: write-all\n' 1 \
  "%W: job a uses scalar permissions \"write-all\" (only read-all is allowed as a scalar)
${ONE}"
expect_passes 'permissions: written as an alias of a map is read through it' \
  'x-p: &p {contents: write}\n'"${HEAD}"'  a:\n    permissions: *p\n'
expect_passes 'permissions: written as an alias of read-all is read through it' \
  'x-p: &p read-all\n'"${HEAD}"'  a:\n    permissions: *p\n'
expect_built 'a scope value written as an alias is read through it' \
  'x-w: &w write\n'"${HEAD}"'  a:\n    permissions: {pull-requests: *w}\n' 1 \
  "%W: job a grants write scope pull-requests not allowed by %A
${ONE}"
expect_built 'a job written as an alias is read through it' \
  'x-j: &j {permissions: {pull-requests: write}}\n'"${HEAD}"'  a: *j\n' 1 \
  "%W: job a grants write scope pull-requests not allowed by %A
${ONE}"
expect_passes 'a null permissions: yields no scope row' \
  "${HEAD}"'  a:\n    permissions:\n'
expect_built 'a job alias holding a permissions alias holding a value alias is read through all three' \
  'x-w: &w write\nx-p: &p {pull-requests: *w}\nx-j: &j {permissions: *p}\n'"${HEAD}"'  a: *j\n' 1 \
  "%W: job a grants write scope pull-requests not allowed by %A
${ONE}"
expect_built 'a job written as an alias holding an alias is read through both' \
  'x-p: &p {pull-requests: write}\nx-j: &j {permissions: *p}\n'"${HEAD}"'  a: *j\n' 1 \
  "%W: job a grants write scope pull-requests not allowed by %A
${ONE}"
expect_built 'jobs: written as an alias is read through it' \
  'x-js: &js {a: {permissions: {pull-requests: write}}}\non: push\njobs: *js\n' 1 \
  "%W: job a grants write scope pull-requests not allowed by %A
${ONE}"
expect_built 'a second document is read as jobs, with no separator row' \
  "${HEAD}"'  a:\n    permissions: {contents: write}\n---\n'"${HEAD}"'  a:\n    permissions: {deployments: write}\n' 1 \
  "%W: job a grants write scope deployments not allowed by %A
${ONE}"

# A job id or a scope name is raw text in a tab-separated row, so one
# that is not a scalar, is empty, or holds a tab, a line break or a NUL
# is refused and the workflow's jobs are not read.
readonly ODD='jobs: holds a job id or a scope name that is not a scalar, is empty, or holds a tab, a line break or a NUL, which GitHub Actions refuses; its jobs are not read (first: '
expect_built 'a job id holding a tab cannot forge an allowed scope' \
  "${HEAD}"'  "a\\tcontents":\n    permissions: {pull-requests: write}\n' 1 \
  "%W: ${ODD}kind=scalar, name=\"a\\tcontents\")
${ONE}"
expect_built 'a scope name holding a tab is refused' \
  "${HEAD}"'  a:\n    permissions: {"contents\\tx": write}\n' 1 \
  "%W: ${ODD}kind=scalar, name=\"contents\\tx\")
${ONE}"
expect_built 'a scope name holding a line break is refused' \
  "${HEAD}"'  a:\n    permissions: {"x\\ncontents": write}\n' 1 \
  "%W: ${ODD}kind=scalar, name=\"x\\ncontents\")
${ONE}"
expect_built 'a scope name that is a list is refused' \
  "${HEAD}"'  a:\n    permissions: {? [contents] : write}\n' 1 \
  "%W: ${ODD}kind=seq, name=\"[contents]\")
${ONE}"
expect_built 'an empty job id is refused' \
  "${HEAD}"'  "":\n    permissions: {contents: write}\n' 1 \
  "%W: ${ODD}kind=scalar, name=\"\")
${ONE}"
expect_built 'a job id holding a NUL is refused' \
  "${HEAD}"'  "a\\0b":\n    permissions: {contents: write}\n' 1 \
  "%W: ${ODD}kind=scalar, name=\"a\\u0000b\")
${ONE}"

# Names are data, never expression text. Each name below closes a quoted
# segment if spliced into a `yq` expression: a job key would read the
# decoy job's allowlist entry, a scope or job name in the allowlist would
# read `write` or nothing, and either could print an environment variable
# or a file through `error()`. Read as data, each run reports exactly the
# finding its own names earn. Every run is unfiltered, so both passes run.
key_dir="$(mktemp --directory)"
trap 'rm --recursive --force -- "${key_dir}"' EXIT
printf 'FILE_READ_MARK\n' >"${key_dir}/probe.txt"
# @arg $1 scenario name  @arg $2 workflow file name  @arg $3 workflow body
# @arg $4 allowlist body  @arg $5 expected exit  @arg $6 expected stderr,
# whole, with @WF@ standing for the workflow path and @AL@ for the allowlist
function expect_names() {
  local -r name="$1" wf_name="$2" wf_body="$3" al_body="$4" want_exit="$5"
  local got_exit=0 got_stderr want
  mkdir -- "${key_dir}/${name}"
  printf '%s' "${wf_body}" >"${key_dir}/${name}/${wf_name}"
  printf '%s' "${al_body}" >"${key_dir}/${name}.allow.yml"
  want="${6//@WF@/${key_dir}/${name}/${wf_name}}"
  want="${want//@AL@/${key_dir}/${name}.allow.yml}"
  got_stderr="$(PROBE=PAYLOAD_RAN PROBE_FILE="${key_dir}/probe.txt" WORKFLOWS_DIR_OVERRIDE="${key_dir}/${name}" \
    SCOPE_ALLOWLIST_OVERRIDE="${key_dir}/${name}.allow.yml" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s and %q\n  stderr: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${want}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
# The job key names an over-grant; the allowlist lists the decoy job's
# wider grant under the decoy, and the key's own entry under the key.
# @arg $1 scenario name  @arg $2 the job key
function expect_job_key() {
  local -r name="$1" key="$2"
  local -r k="'${key//\'/\'\'}'"
  local quoted
  printf -v quoted '%q' "${key}"
  expect_names "${name}" w.yml \
    $'permissions: {}\njobs:\n  '"${k}"$':\n    permissions:\n      contents: write\n      issues: write\n    steps:\n      - run: echo PAYLOAD_RAN\n  decoy:\n    permissions:\n      contents: write\n      issues: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' \
    $'w.yml:\n  '"${k}"$': [issues]\n  decoy: [contents, issues]\n' 1 \
    "@WF@: job ${quoted} grants write scope contents not allowed by @AL@"$'\n1 permission-scope violation(s) found'
}
expect_job_key job-key-reads-decoy-entry 'x" // ."w.yml"."decoy'
expect_job_key job-key-reads-env 'x" | error(strenv(PROBE)) | ."y'
expect_job_key job-key-reads-file 'x" | error(load_str(strenv(PROBE_FILE))) | ."y'
expect_job_key job-key-quote 'k"x'
expect_job_key job-key-backslash 'k\x'
# An allowlist scope or job name that the workflow does not grant is
# stale, whatever text it holds.
readonly WRITER=$'permissions: {}\njobs:\n  writer:\n    permissions:\n      issues: write\n    steps:\n      - run: echo PAYLOAD_RAN\n'
expect_names scope-name-reads-write w.yml "${WRITER}" \
  $'w.yml:\n  writer: [issues, \'packages" // "write\']\n' 1 \
  '@AL@: stale entry w.yml/writer/packages\"\ //\ \"write (job does not grant that write scope)'$'\n1 permission-scope violation(s) found'
expect_names scope-name-reads-env w.yml "${WRITER}" \
  $'w.yml:\n  writer: [issues, \'x" | error(strenv(PROBE)) | ."y\']\n' 1 \
  '@AL@: stale entry w.yml/writer/x\"\ \|\ error\(strenv\(PROBE\)\)\ \|\ .\"y (job does not grant that write scope)'$'\n1 permission-scope violation(s) found'
expect_names allowlist-job-reads-writer w.yml "${WRITER}" \
  $'w.yml:\n  writer: [issues]\n  \'x" // .jobs."writer\': [issues]\n' 1 \
  '@AL@: stale entry w.yml/x\"\ //\ .jobs.\"writer/issues (job does not grant that write scope)'$'\n1 permission-scope violation(s) found'
# A name is looked up by its exact text: `*` and `?` are no wildcards.
# Read as patterns, the job key would borrow its sibling's entry and the
# file name another workflow's.
expect_names job-key-wildcard w.yml \
  $'permissions: {}\njobs:\n  \'rel*\':\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n  release:\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' \
  $'w.yml:\n  release: [contents]\n' 1 \
  '@WF@: job rel\* grants write scope contents not allowed by @AL@'$'\n1 permission-scope violation(s) found'
expect_names file-name-wildcard 'rel?.yml' \
  $'permissions: {}\njobs:\n  publish:\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' \
  $'relz.yml:\n  publish: [contents]\n' 1 \
  '@WF@: job publish grants write scope contents not allowed by @AL@'$'\n@AL@: stale entry relz.yml/publish/contents (job does not grant that write scope)\n2 permission-scope violation(s) found'
# The stale-entry read looks names up the same way: an allowlist job
# or scope name read as a pattern would find the grant of another.
expect_names allowlist-job-wildcard w.yml \
  $'permissions: {}\njobs:\n  release:\n    permissions:\n      packages: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' \
  $'w.yml:\n  release: [packages]\n  \'rel*\': [packages]\n' 1 \
  '@AL@: stale entry w.yml/rel\*/packages (job does not grant that write scope)'$'\n1 permission-scope violation(s) found'
expect_names allowlist-scope-wildcard w.yml \
  $'permissions: {}\njobs:\n  writer:\n    permissions:\n      issues: write\n      packages: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' \
  $'w.yml:\n  writer: [issues, \'pack*\', packages]\n' 1 \
  '@AL@: stale entry w.yml/writer/pack\* (job does not grant that write scope)'$'\n1 permission-scope violation(s) found'
# The stale-entry read takes a permissions: map, through an alias; the
# string read-all grants no scope.
expect_names allowlist-read-all w.yml \
  $'permissions: {}\njobs:\n  reader:\n    permissions: read-all\n    steps:\n      - run: echo PAYLOAD_RAN\n' \
  $'w.yml:\n  reader: [packages]\n' 1 \
  '@AL@: stale entry w.yml/reader/packages (job does not grant that write scope)'$'\n1 permission-scope violation(s) found'
expect_names allowlist-permissions-alias w.yml \
  $'permissions: {}\nx-perms: &p\n  packages: write\njobs:\n  writer:\n    permissions: *p\n    steps:\n      - run: echo PAYLOAD_RAN\n' \
  $'w.yml:\n  writer: [packages]\n' 0 ''
# A name written twice is read as `yq`'s own lookup reads it, the last
# one; and every listed allowlist row is still checked.
expect_names job-key-twice w.yml \
  $'permissions: {}\njobs:\n  a:\n    permissions:\n      issues: read\n    steps:\n      - run: echo PAYLOAD_RAN\n  a:\n    permissions:\n      issues: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' \
  $'w.yml:\n  a: [issues]\n' 0 ''
expect_names allowlist-job-twice w.yml \
  $'permissions: {}\njobs:\n  a:\n    permissions:\n      issues: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' \
  $'w.yml:\n  a: [contents]\n  a: [issues]\n' 1 \
  '@AL@: stale entry w.yml/a/contents (job does not grant that write scope)'$'\n1 permission-scope violation(s) found'
# The forward pass reads an allowlist entry through an alias or a merge
# key, and refuses an allowlist that is not one map of workflow maps
# (exit 2). Filtered to one workflow, it runs alone.
# @arg $1 scenario name  @arg $2 allowlist body  @arg $3 expected exit
# @arg $4 expected stderr, whole, with @AL@ standing for the allowlist
function expect_allowlist_shape() {
  local -r name="$1" body="$2" want_exit="$3"
  local got_exit=0 got_stderr want
  printf '%s' "${body}" >"${key_dir}/${name}.allow.yml"
  want="${4//@AL@/${key_dir}/${name}.allow.yml}"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" WORKFLOW_FILE_FILTER=good.yml \
    SCOPE_ALLOWLIST_OVERRIDE="${key_dir}/${name}.allow.yml" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  # yq itself warns on stderr about any merge key it reads; that line is
  # yq's, not the lint's.
  got_stderr="$(grep --invert-match --fixed-strings -- '--yaml-fix-merge-anchor-to-spec' <<<"${got_stderr}" || true)"
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s and %q\n  stderr: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${want}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
expect_allowlist_shape allowlist-entry-twice $'good.yml: {writer: [contents]}\ngood.yml: {writer: [issues]}\n' 0 ''
expect_names scope-twice w.yml \
  $'permissions: {}\njobs:\n  writer:\n    permissions:\n      issues: read\n      issues: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' \
  $'w.yml:\n  writer: [issues]\n' 0 ''
expect_allowlist_shape allowlist-entry-alias $'x: &X {writer: [issues]}\ngood.yml: *X\n' 0 ''
expect_allowlist_shape allowlist-entry-merge $'x: &X {writer: [issues]}\ngood.yml:\n  <<: *X\n' 0 ''
expect_allowlist_shape allowlist-root-list $'- good.yml\n' 2 \
  '@AL@: the allowlist must be one map of workflow maps (got seq\ scalar)'
expect_allowlist_shape allowlist-entry-list $'good.yml: [writer]\n' 2 \
  '@AL@: the allowlist must be one map of workflow maps (got map\ seq)'
expect_allowlist_shape allowlist-empty '' 2 '@AL@: the allowlist is empty'
expect_allowlist_shape allowlist-several-documents $'good.yml: {writer: [issues]}\n---\ngood.yml: {writer: [issues]}\n' 2 \
  '@AL@: the allowlist holds several YAML documents; it must hold one'
expect_allowlist_shape allowlist-entry-null $'good.yml:\nother.yml: {writer: [issues]}\n' 1 \
  "${FIXTURES}/good.yml: job writer grants write scope issues not allowed by @AL@"$'\n1 permission-scope violation(s) found'
# A workflow file name is data too.
expect_names file-name-quote 'q"x.yml' "${WRITER}" \
  $'\'q"x.yml\':\n  writer: [issues]\n' 0 ''

# Real-tree guard: the committed allowlist must match the live workflows.
real_exit=0
"${SCRIPT}" >/dev/null 2>&1 || real_exit=$?
if [[ ${real_exit} != 0 ]]; then
  printf 'FAIL real-tree: .github/workflows vs .github/permission-scopes.yml exit %s, want 0\n' "${real_exit}" >&2
  exit 1
fi
printf 'OK   real-tree\n'

printf 'all tests passed\n'
