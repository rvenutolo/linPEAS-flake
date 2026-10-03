#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-workflow-concurrency.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/workflow-concurrency"

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

# @description Scan one fixture with one `yq` read failing after the
# workflow's first read has succeeded. The file parses, so the failure
# says nothing about it: the run must stop as a could-not-run, printing
# only a line naming what was being read, `yq` and the status it exited
# with, whatever the workflow holds.
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
# compare the whole of stderr, so the shapes built here (tags, aliases,
# several documents) are not tracked files a formatter or workflow linter
# reads.
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
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s, and stderr %q\n  got: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}

# The lint quotes the key in backticks; Q holds one, so that no
# assertion string here does.
readonly Q=$'\x60'
expect good.yml 0 ""
expect good-no-cancel.yml 0 ""
expect bad-missing.yml 1 "bad-missing.yml: missing top-level"
expect bad-scalar.yml 1 "bad-scalar.yml: top-level concurrency has unexpected shape (kind=scalar, tag=!!str); expected map"
expect bad-no-group.yml 1 "bad-no-group.yml: top-level concurrency is missing ${Q}group:${Q}"
expect bad-empty-group.yml 1 "bad-empty-group.yml: top-level concurrency ${Q}group:${Q} is empty"
expect bad-seq-group.yml 1 "bad-seq-group.yml: top-level concurrency.group has unexpected shape (kind=seq, tag=!!seq); expected string"
expect bad-map-group.yml 1 "bad-map-group.yml: top-level concurrency.group has unexpected shape (kind=map, tag=!!map); expected string"
expect no-such-workflow.yml 2 'selected 0 of'

expect_unparsable 'concurrency: [\n' 'bad-unparsable.yml: could not evaluate'

# Every read after a workflow's first is held to the run-stopping line,
# on a workflow that holds the fault the read is for and on one that
# does not. The group read is `eval .concurrency.group` followed by the
# fixture's absolute path, which the shape read does not hold.
expect_failed_read good.yml '.concurrency.group | kind' 7 'the concurrency group shape'
expect_failed_read bad-seq-group.yml '.concurrency.group | kind' 9 'the concurrency group shape'
expect_failed_read good.yml 'eval .concurrency.group /' 11 'the concurrency group'
expect_failed_read bad-empty-group.yml 'eval .concurrency.group /' 13 'the concurrency group'

# The map and the group are read by kind: a map carrying a tag of its
# own is still read, a list carrying a string tag is no string, and the
# message names the kind and the tag of any other shape. An alias is
# reported by its kind, unresolved.
readonly ONE=$'\n1 workflow(s) missing or invalid top-level concurrency'
readonly TOP='top-level concurrency has unexpected shape'
readonly GROUP='top-level concurrency.group has unexpected shape'
expect_body mistag.yml $'concurrency: !!map [a]\n' 1 "DIR/mistag.yml: ${TOP} (kind=seq, tag=!!map); expected map${ONE}"
expect_body conc-mapint.yml $'concurrency: !!map 5\n' 1 "DIR/conc-mapint.yml: ${TOP} (kind=scalar, tag=!!map); expected map${ONE}"
expect_body conc-xtag.yml $'concurrency: !x\n  group: g\n' 0 ''
expect_body conc-strtag.yml $'concurrency: !!str {group: g}\n' 0 ''
expect_body conc-alias.yml $'x-c: &c\n  group: g\nconcurrency: *c\n' 1 "DIR/conc-alias.yml: ${TOP} (kind=alias, tag=); expected map${ONE}"
expect_body group-strseq.yml $'concurrency:\n  group: !!str [a]\n' 1 "DIR/group-strseq.yml: ${GROUP} (kind=seq, tag=!!str); expected string${ONE}"
expect_body group-mapint.yml $'concurrency:\n  group: !!map 5\n' 1 "DIR/group-mapint.yml: ${GROUP} (kind=scalar, tag=!!map); expected string${ONE}"
expect_body group-xtag.yml $'concurrency:\n  group: !x g\n' 1 "DIR/group-xtag.yml: ${GROUP} (kind=scalar, tag=!x); expected string${ONE}"
expect_body group-alias.yml $'x-s: &s g\nconcurrency:\n  group: *s\n' 1 "DIR/group-alias.yml: ${GROUP} (kind=alias, tag=); expected string${ONE}"
# GitHub Actions reads a workflow file as one YAML document and refuses
# one holding several, so such a file is a finding and is read no
# further.
expect_body several-docs.yml $'concurrency:\n  group: g\n---\non: push\n' 1 \
  "DIR/several-docs.yml: holds several YAML documents; a workflow file must hold one${ONE}"

printf 'all tests passed\n'
