#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-workflow-on-branches.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/workflow-on-branches"

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
# every line the lint prints is compared. With `tail` as a fifth argument
# only the end of stderr is compared, for a run whose first lines are
# `yq`'s own error, whose wording is not the lint's.
# @arg $1 file name, which is also the scenario's label
# @arg $2 file body  @arg $3 expected exit status
# @arg $4 expected stderr, with DIR standing for the temp dir
# @arg $5 `tail` to compare only the end of stderr (optional)
function expect_body() {
  local -r name="$1" body="$2" want_exit="$3" mode="${5:-whole}"
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
  if [[ ${mode} == tail && ${got_stderr} != *$'\n'"${want}" ]] ||
    [[ ${mode} != tail && ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: stderr is not %q\n  got: %s\n' "${name}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}

# @description Print an `env:` block holding a chain of aliases DEPTH
# deep: A0 is anchored on INNERMOST and each later entry is a map holding
# the one before it under `x`. Sixteen `explode` passes resolve a chain
# fifteen deep and leave an alias in one sixteen deep; a key written as
# an alias at the end of a chain fifteen deep is left too.
# @arg $1 depth  @arg $2 innermost value, as YAML flow text
function alias_chain() {
  local -r depth="$1" innermost="$2"
  local i
  printf 'env:\n  A0: &a0 %s\n' "${innermost}"
  for ((i = 1; i <= depth; i++)); do
    printf '  A%d: &a%d {x: *a%d}\n' "${i}" "${i}" "$((i - 1))"
  done
}

expect good.yml 0 ""
expect good-cron-only.yml 0 ""
expect bad-pr-no-branches.yml 1 "bad-pr-no-branches.yml: on.pull_request is missing"
expect bad-pr-wildcard.yml 1 "bad-pr-wildcard.yml: on.pull_request.branches must be exactly"
expect bad-push-extra.yml 1 "bad-push-extra.yml: on.push.branches must be exactly"
expect bad-push-no-branches.yml 1 "bad-push-no-branches.yml: on.push is missing"
expect bad-pr-null.yml 1 "bad-pr-null.yml: on.pull_request is present but null"
expect bad-push-null.yml 1 "bad-push-null.yml: on.push is present but null"
expect no-such-workflow.yml 2 'selected 0 of'

# A trigger, its value or its branch list written through an anchor is
# read as what it stands for.
# The lint's lines quote the branch list in backticks; Q holds one, so
# that no assertion string here does.
readonly Q=$'\x60'
readonly ONE=$'\n'"1 workflow trigger(s) missing or non-canonical ${Q}branches: [main]${Q}"
readonly MISSING="is missing ${Q}branches: [main]${Q} (implicit all-branches forbidden)"
expect_body alias-key.yml $'name: &t push\non:\n  *t : {}\n' 1 "DIR/alias-key.yml: on.push ${MISSING}${ONE}"
expect_body alias-key-null.yml $'name: &t pull_request\non:\n  *t :\n' 1 \
  "DIR/alias-key-null.yml: on.pull_request is present but null (implicit all-branches forbidden; need ${Q}branches: [main]${Q})${ONE}"
expect_body alias-key-good.yml $'name: &t push\non:\n  *t :\n    branches: [main]\n' 0 ''
expect_body alias-value-good.yml $'on:\n  push: &v\n    branches: [main]\n  pull_request: *v\n' 0 ''
expect_body alias-value-no-branches.yml $'env:\n  X: &v\n    types: [opened]\non:\n  pull_request: *v\n' 1 \
  "DIR/alias-value-no-branches.yml: on.pull_request ${MISSING}${ONE}"
expect_body alias-branches-good.yml $'env:\n  X: &b [main]\non:\n  push:\n    branches: *b\n' 0 ''
expect_body alias-branches-extra.yml $'env:\n  X: &b [main, dev]\non:\n  push:\n    branches: *b\n' 1 \
  "DIR/alias-branches-extra.yml: on.push.branches must be exactly ${Q}[main]${Q}; got [\"main\",\"dev\"]${ONE}"
expect_body alias-branch-item.yml $'name: &m dev\non:\n  push:\n    branches: [*m]\n' 1 \
  "DIR/alias-branch-item.yml: on.push.branches must be exactly ${Q}[main]${Q}; got [\"dev\"]${ONE}"
expect_body alias-whole.yml $'env:\n  X: &t\n    push: {}\non: *t\n' 1 "DIR/alias-whole.yml: on.push ${MISSING}${ONE}"
expect_body alias-whole-good.yml $'env:\n  X: &t\n    push:\n      branches: [main]\non: *t\n' 0 ''
# An alias inside what another alias stands for, and an `on` key itself
# written as an alias.
expect_body nested-branches-good.yml $'env:\n  X: &b [main]\n  Y: &v {branches: *b}\non:\n  push: *v\n' 0 ''
expect_body nested-branches-extra.yml $'env:\n  X: &b [main, dev]\n  Y: &v {branches: *b}\non:\n  push: *v\n' 1 \
  "DIR/nested-branches-extra.yml: on.push.branches must be exactly ${Q}[main]${Q}; got [\"main\",\"dev\"]${ONE}"
# Three levels: the branch list is read only after three passes.
expect_body nested-three-deep.yml $'env:\n  C: &c [main]\n  B: &b {branches: *c}\n  A: &a {push: *b}\non: *a\n' 0 ''
# The depth boundary: a chain fifteen deep is read, one sixteen deep is
# refused, and so is one fifteen deep ending in a key written as an
# alias, the one alias the passes leave there. A refused first read is
# a counted finding, and the workflow is read no further.
readonly TOO_DEEP=$'Error: on: holds an alias nested too deep to resolve\n'
readonly ON_TWICE=$'Error: on: is given more than once\n'
readonly UNREAD='could not evaluate workflow with yq (malformed?)'
readonly TWO=$'\n'"2 workflow trigger(s) missing or non-canonical ${Q}branches: [main]${Q}"
expect_body chain-15.yml "$(alias_chain 15 '[main]')"$'\non:\n  push:\n    branches: [main]\n    x: *a15\n' 0 ''
expect_body chain-16.yml "$(alias_chain 16 '[main]')"$'\non:\n  push:\n    branches: [main]\n    x: *a16\n' 1 \
  "${TOO_DEEP}DIR/chain-16.yml: ${UNREAD}${ONE}"
expect_body chain-15-key.yml $'name: &k push\n'"$(alias_chain 15 '{*k : {}}')"$'\non:\n  push:\n    branches: [main]\n    x: *a15\n' 1 \
  "${TOO_DEEP}DIR/chain-15-key.yml: ${UNREAD}${ONE}"
# A file whose root has more than one key that resolves to `on` has no
# one `on:` to read, and an `on:` that is not a map is no trigger map.
expect_body on-twice.yml $'name: &k on\non:\n  push:\n    branches: [main]\n*k :\n  push: {}\n' 1 \
  "${ON_TWICE}DIR/on-twice.yml: ${UNREAD}${ONE}"
expect_body no-on.yml $'jobs: {}\n' 0 ''
expect_body top-list.yml $'- on: push\n' 1 \
  $'DIR/top-list.yml: could not evaluate workflow with yq (malformed?)'"${ONE}" tail
# GitHub Actions refuses a merge key, so this workflow cannot run; an
# `on:` a root merge key brings in is still read.
expect_body root-merge.yml $'env:\n  X: &b {on: {push: {}}}\n<<: *b\n' 1 "DIR/root-merge.yml: on.push ${MISSING}${ONE}"
# The file's own `on` key is read, not one a later merge key would put
# over it: under YAML's merge rule the explicit key wins.
expect_body plain-then-merge.yml $'env:\n  X: &b {on: {push: {}}}\non:\n  push:\n    branches: [main]\n<<: *b\n' 0 ''
# A node whose tag yq cannot decode fails a later read too: the run
# stops, as it does for yq failing, though the fault is the workflow's.
expect_body mistag-branches.yml $'on:\n  pull_request:\n    branches: [.nan]\n' 2 \
  'cannot read the on.pull_request.branches list of DIR/mistag-branches.yml: yq exited 1' tail
expect_body mistag-push.yml $'on:\n  pull_request:\n    branches: [main]\n  push: !!map [a]\n' 2 \
  'cannot read the on.push.branches shape of DIR/mistag-push.yml: yq exited 1' tail
readonly SHAPES='expected a map, a list or a name'
expect_body false-on.yml $'on: false\njobs: {}\n' 1 \
  "DIR/false-on.yml: on: has unexpected shape (kind=scalar, tag=!!bool); ${SHAPES}${ONE}"
expect_body tagged-name.yml $'on: !x push\n' 1 \
  "DIR/tagged-name.yml: on: has unexpected shape (kind=scalar, tag=!x); ${SHAPES}${ONE}"
# GitHub Actions reads a workflow file as one YAML document and refuses
# one holding several, so such a file is a finding whatever each
# document holds, and is read no further.
readonly SEVERAL='holds several YAML documents; a workflow file must hold one'
readonly CLEAN_ON=$'on:\n  pull_request:\n    branches: [main]\n  push:\n    branches: [main]\n'
expect_body several-docs.yml "${CLEAN_ON}"$'---\non: push\n' 1 "DIR/several-docs.yml: ${SEVERAL}${ONE}"
expect_body several-docs-first.yml $'on: push\n---\n'"${CLEAN_ON}" 1 "DIR/several-docs-first.yml: ${SEVERAL}${ONE}"
expect_body several-docs-clean.yml "${CLEAN_ON}"$'---\n'"${CLEAN_ON}" 1 "DIR/several-docs-clean.yml: ${SEVERAL}${ONE}"
expect_body several-docs-trailing.yml "${CLEAN_ON}"$'---\n' 1 "DIR/several-docs-trailing.yml: ${SEVERAL}${ONE}"
# An `on:` written as a name or a list of names runs each trigger it
# names on every branch; one naming neither trigger is out of scope.
readonly NAMED="is given as a name, with no branches (implicit all-branches forbidden; need ${Q}branches: [main]${Q})"
expect_body name-push.yml $'on: push\n' 1 "DIR/name-push.yml: on.push ${NAMED}${ONE}"
expect_body name-pr.yml $'on: pull_request\n' 1 "DIR/name-pr.yml: on.pull_request ${NAMED}${ONE}"
expect_body name-alias.yml $'name: &p push\non: *p\n' 1 "DIR/name-alias.yml: on.push ${NAMED}${ONE}"
expect_body name-dispatch.yml $'on: workflow_dispatch\n' 0 ''
expect_body list-dispatch.yml $'on: [workflow_dispatch, schedule]\n' 0 ''
expect_body list-both.yml $'on: [push, workflow_dispatch, pull_request]\n' 1 \
  "DIR/list-both.yml: on.pull_request ${NAMED}"$'\n'"DIR/list-both.yml: on.push ${NAMED}${TWO}"
expect_body list-tagged.yml $'on: !!str [push]\n' 1 "DIR/list-tagged.yml: on.push ${NAMED}${ONE}"
expect_body list-nested.yml $'on: [workflow_dispatch, [push]]\n' 1 \
  "DIR/list-nested.yml: on: has a list item of unexpected shape (kind=seq, tag=!!seq); expected a name${ONE}"
expect_body list-map-item.yml $'on: [{push: {}}, push]\n' 1 \
  "DIR/list-map-item.yml: on: has a list item of unexpected shape (kind=map, tag=!!map); expected a name"$'\n'"DIR/list-map-item.yml: on.push ${NAMED}${TWO}"
expect_body list-alias.yml $'name: &p pull_request\non: [*p]\n' 1 "DIR/list-alias.yml: on.pull_request ${NAMED}${ONE}"
expect_body nested-key.yml $'name: &k push\nenv:\n  A: &m {*k : {}}\non: *m\n' 1 "DIR/nested-key.yml: on.push ${MISSING}${ONE}"
expect_body alias-on-key.yml $'name: &k on\n*k :\n  push: {}\n' 1 "DIR/alias-on-key.yml: on.push ${MISSING}${ONE}"
# GitHub Actions refuses a merge key, so this workflow cannot run; the
# lint still reads the trigger the merge brings in.
expect_body merge-key.yml $'env:\n  X: &t\n    pull_request: {}\non:\n  <<: *t\n' 1 "DIR/merge-key.yml: on.pull_request ${MISSING}${ONE}"
expect_body tagged-map.yml $'on: !x\n  push: {}\n' 1 "DIR/tagged-map.yml: on.push ${MISSING}${ONE}"
# Only `on:` is resolved: an alias `yq` cannot resolve elsewhere in the
# file (a merge of a string) does not stop a readable `on:` being read.
expect_body merge-elsewhere.yml $'name: &s str\non:\n  push:\n    branches: [main]\njobs:\n  a:\n    <<: *s\n' 0 ''
expect_body merge-elsewhere-bad.yml $'name: &s str\non:\n  push: {}\njobs:\n  a:\n    <<: *s\n' 1 "DIR/merge-elsewhere-bad.yml: on.push ${MISSING}${ONE}"

expect_unparsable 'on: [\n' 'bad-unparsable.yml: could not evaluate'

# The read that tells a trigger present with no value from an absent one,
# once per trigger and once for a workflow that has neither.
expect_failed_read bad-pr-null.yml 'has("pull_request")' 7 'the on.pull_request key'
expect_failed_read bad-push-null.yml 'has("push")' 9 'the on.push key'
expect_failed_read good-cron-only.yml 'has("pull_request")' 11 'the on.pull_request key'

# The reads after a workflow's first: the second trigger's shape, and a
# trigger's branch list, its shape and its rendered value.
expect_failed_read good.yml '"push" | tag' 13 'the on.push trigger'
expect_failed_read bad-push-no-branches.yml '"push" | tag' 15 'the on.push trigger'
expect_failed_read good.yml '"pull_request".branches | tag' 17 'the on.pull_request.branches shape'
expect_failed_read bad-pr-wildcard.yml '"pull_request".branches | tag' 19 'the on.pull_request.branches shape'
expect_failed_read good.yml '--output-format=json' 21 'the on.pull_request.branches list'
expect_failed_read bad-pr-wildcard.yml '--output-format=json' 23 'the on.pull_request.branches list'

# The trigger read is not the workflow's first, and the read of the
# names an `on:` written as a name or a list gives.
expect_failed_read good.yml '"pull_request" | tag' 25 'the on.pull_request trigger'
expect_failed_read bad-on-name.yml '| (select(kind' 27 'the on: names'
expect_failed_read good-on-list.yml '| (select(kind' 29 'the on: names'
expect_failed_read good-on-list.yml 'select(kind != "scalar")' 33 'the on: list items'

# The first read, of the kind of `on:`, failing is a counted finding, and
# the workflow is read no further: its push trigger, which would be a
# finding of its own, is not reported beside a read that failed.
yq_stub 'resolve")) | kind + " " + tag' 31
first_exit=0
first_stderr="$(PATH="${STUB_DIR}:${PATH}" WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
  WORKFLOW_FILE_FILTER=bad-push-extra.yml "${SCRIPT}" 2>&1 >/dev/null)" || first_exit=$?
rm --recursive --force -- "${STUB_DIR}"
first_want="${FIXTURES}/bad-push-extra.yml: could not evaluate workflow with yq (malformed?)"$'\n'"1 workflow trigger(s) missing or non-canonical ${Q}branches: [main]${Q}"
if [[ ${first_exit} != 1 || ${first_stderr} != "${first_want}" ]]; then
  printf 'FAIL first read failing: exit %s, want 1, and stderr %q\n  got: %s\n' \
    "${first_exit}" "${first_want}" "${first_stderr}" >&2
  exit 1
fi
printf 'OK   bad-push-extra.yml with its first read failing\n'

printf 'all tests passed\n'
