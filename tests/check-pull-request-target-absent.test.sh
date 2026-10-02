#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-pull-request-target-absent.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/pull-request-target-absent"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
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

# @description Scan a workflow that does not parse, written to a temp
# dir at run time so no unparsable file sits in the tree for the
# formatters to choke on. A file that does not parse is a fact about
# this repo, so it is a finding against that file; what the read must
# not do is leave yq's status unchecked, which ends the run mid-tree and
# leaves every workflow after this one unscanned.
# @arg $1 file body  @arg $2 expected stderr substring
function expect_unparsable() {
  local -r body="$1" want_msg="$2"
  local dir got_exit=0 got_stderr
  dir="$(mktemp --directory)"
  printf '%s' "${body}" >"${dir}/bad-unparsable.yml"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" \
    WORKFLOW_FILE_FILTER='bad-unparsable.yml' \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != 1 ]]; then
    printf 'FAIL unparsable workflow: exit %s, want 1\n  stderr: %s\n' \
      "${got_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL unparsable workflow: stderr missing %q\n  got: %s\n' \
      "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   unparsable workflow reported as a finding\n'
}

# @description Make a directory holding a `yq` that exits with a given
# status for every call whose arguments hold a given string and hands any
# other call to the real `yq`, and point STUB_DIR at it. A scenario puts
# the directory first on PATH for its own run only.
# @arg $1 argument text that marks the failing call
# @arg $2 exit status for that call
function yq_stub() {
  local real_yq
  real_yq="$(command -v yq)"
  STUB_DIR="$(mktemp --directory)"
  printf '#!/usr/bin/env bash\ncase "$*" in *%q*) exit %d ;; esac\nexec %q "$@"\n' \
    "$1" "$2" "${real_yq}" >"${STUB_DIR}/yq"
  chmod +x -- "${STUB_DIR}/yq"
}

# @description Scan one fixture with one `yq` read failing. The workflow
# has already parsed by then, so the failure says nothing about it: the
# run must stop as a could-not-run, on a line naming what was being read,
# `yq` and the status it exited with, whatever the workflow holds.
# @arg $1 fixture  @arg $2 argument text of the failing read
# @arg $3 status the stub exits with  @arg $4 what the line says was read
function expect_failed_read() {
  local -r fixture="$1" pattern="$2" status="$3" thing="$4"
  local -r want="cannot read ${thing} of ${FIXTURES}/${fixture}: yq exited ${status}"
  local got_exit=0 got_stderr
  yq_stub "${pattern}" "${status}"
  got_stderr="$(PATH="${STUB_DIR}:${PATH}" WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${STUB_DIR}"
  if [[ ${got_exit} != 2 ]]; then
    printf 'FAIL %s with a failing yq read: exit %s, want 2\n  stderr: %s\n' \
      "${fixture}" "${got_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s with a failing yq read: stderr is not %q\n  got: %s\n' \
      "${fixture}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s with a failing yq read (%s)\n' "${fixture}" "${thing}"
}

# @description Scan one workflow written to a temp dir at run time and
# hold the lint to its exit status and to the whole of what it prints on
# stderr. The shapes scanned this way (aliases, merge keys, tags, several
# documents) are built here so that no formatter or workflow linter reads
# them as tracked files. The line `yq` itself prints when it resolves a
# merge key carries a timestamp, so it is dropped before the comparison;
# every line the lint prints is compared.
# @arg $1 file name, which is also the scenario's label
# @arg $2 file body  @arg $3 expected exit status
# @arg $4 expected stderr, with DIR standing for the temp dir
function expect_body() {
  local -r name="$1" body="$2" want_exit="$3"
  local dir got_exit=0 got_stderr want
  dir="$(mktemp --directory)"
  printf '%s' "${body}" >"${dir}/${name}"
  want="${4//DIR/${dir}}"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  got_stderr="$(grep --invert-match --fixed-strings -- '--yaml-fix-merge-anchor-to-spec' <<<"${got_stderr}" || true)"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: stderr is not %q\n  got: %s\n' "${name}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}

expect good-map.yml 0 ""
expect good-string.yml 0 ""
expect bad-map.yml 1 'bad-map.yml: uses '
expect bad-map-null.yml 1 'bad-map-null.yml: uses '
expect bad-string.yml 1 'bad-string.yml: uses '
expect bad-seq.yml 1 'bad-seq.yml: uses '
expect no-such-workflow.yml 2 'selected 0 of'

# A trigger written through an anchor is the trigger. Each shape an alias
# can take in `on:` is read as the name it stands for.
# The lint's lines quote the trigger in backticks; Q holds one, so that no
# assertion string here does.
readonly Q=$'\x60'
readonly USES="uses ${Q}pull_request_target${Q} trigger (forbidden — base-ref workflow with head-ref code + full secrets)"
readonly ONE=$'\n'"1 workflow(s) use forbidden ${Q}pull_request_target${Q} trigger"
expect_body alias-whole-string.yml $'name: &t pull_request_target\non: *t\n' 1 "DIR/alias-whole-string.yml: ${USES}${ONE}"
expect_body alias-whole-list.yml $'env:\n  X: &t [push, pull_request_target]\non: *t\n' 1 "DIR/alias-whole-list.yml: ${USES}${ONE}"
expect_body alias-whole-map.yml $'env:\n  X: &t\n    pull_request_target: {}\non: *t\n' 1 "DIR/alias-whole-map.yml: ${USES}${ONE}"
expect_body alias-list-item.yml $'name: &t pull_request_target\non: [push, *t]\n' 1 "DIR/alias-list-item.yml: ${USES}${ONE}"
expect_body alias-map-key.yml $'name: &t pull_request_target\non:\n  *t : {}\n' 1 "DIR/alias-map-key.yml: ${USES}${ONE}"
expect_body alias-map-key-null.yml $'name: &t pull_request_target\non:\n  push: {}\n  *t :\n' 1 "DIR/alias-map-key-null.yml: ${USES}${ONE}"
# GitHub Actions refuses a merge key, so this workflow cannot run; the
# lint still names the trigger the merge brings in.
expect_body merge-key.yml $'env:\n  X: &t\n    pull_request_target: {}\non:\n  push: {}\n  <<: *t\n' 1 "DIR/merge-key.yml: ${USES}${ONE}"
# An alias is not itself a finding: one standing for another trigger passes.
expect_body alias-whole-clean.yml $'name: &t push\non: *t\n' 0 ''
expect_body alias-list-item-clean.yml $'name: &t pull_request\non: [push, *t]\n' 0 ''
# A list is judged by its items, each as a whole name.
expect_body list-near-miss.yml $'on: [push, pull_request_target_x]\n' 0 ''
expect_body alias-map-key-clean.yml $'name: &t push\non:\n  *t : {}\n' 0 ''
# A list or a map is read whatever tag it carries.
expect_body tagged-map.yml $'on: !x\n  pull_request_target: {}\n' 1 "DIR/tagged-map.yml: ${USES}${ONE}"
expect_body tagged-list.yml $'on: !x [push, pull_request_target]\n' 1 "DIR/tagged-list.yml: ${USES}${ONE}"
expect_body tagged-map-clean.yml $'on: !x\n  push: {}\n' 0 ''
# A scalar is read only as a string or as an absent `on:`.
expect_body no-on.yml $'jobs: {}\n' 0 ''
expect_body null-on.yml $'on:\njobs: {}\n' 0 ''
expect_body number-on.yml $'on: 5\n' 1 $'DIR/number-on.yml: on: has unexpected shape (tag=!!int)'"${ONE}"
expect_body tagged-string.yml $'on: !x pull_request_target\n' 1 $'DIR/tagged-string.yml: on: has unexpected shape (tag=!x)'"${ONE}"
# A file holding several documents has no one `on:` to judge.
expect_body two-documents.yml $'on: push\n---\non: pull_request_target\n' 1 $'DIR/two-documents.yml: on: has unexpected shape (several documents)'"${ONE}"
# Only `on:` is resolved: an alias `yq` cannot resolve elsewhere in the
# file (a merge of a string) does not stop a readable `on:` being read.
expect_body merge-elsewhere.yml $'name: &s str\non:\n  push: {}\njobs:\n  a:\n    <<: *s\n' 0 ''
expect_body merge-elsewhere-bad.yml $'name: &s str\non:\n  pull_request_target: {}\njobs:\n  a:\n    <<: *s\n' 1 "DIR/merge-elsewhere-bad.yml: ${USES}${ONE}"

expect_unparsable 'on: [\n' 'bad-unparsable.yml: could not evaluate'

# One read per shape of `on:`. Each stub text is carried by that read
# alone: `explode(.) /` is the string read followed by the fixture's
# absolute path, which no other read holds, since each of them goes on
# past `explode`.
expect_failed_read bad-string.yml 'explode(.) /' 7 'the on: string'
expect_failed_read bad-seq.yml 'explode(.) | .[]' 9 'the on: list'
expect_failed_read bad-map.yml 'has("pull_request_target")' 11 'the on: keys'
# A workflow without the trigger is not passed on a failed read either.
expect_failed_read good-string.yml 'explode(.) /' 13 'the on: string'
expect_failed_read good-map.yml 'has("pull_request_target")' 15 'the on: keys'

printf 'all tests passed\n'
