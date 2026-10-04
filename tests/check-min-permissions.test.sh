#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-min-permissions.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/min-permissions"

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

expect good.yml 0 ""
expect bad-no-top.yml 1 "missing top-level"
expect bad-top-nonempty.yml 1 "non-empty"
expect bad-top-write-all.yml 1 "scalar"
# The lint quotes the key in backticks; Q holds one, so that no
# assertion string here does.
readonly Q=$'\x60'
expect bad-job-missing.yml 1 "bad-job-missing.yml: job a missing ${Q}permissions:${Q} block (every job must declare its own)"
expect bad-top-list.yml 1 "unexpected shape"
expect bad-job-shape.yml 1 "unexpected shape"
expect no-such-workflow.yml 2 'selected 0 of'

expect_unparsable 'permissions: [\n' 'bad-unparsable.yml: could not evaluate'

# Every read of the top-level `permissions:` after its shape has been
# read is held to the run-stopping line, on a workflow that holds the
# fault the read is for and on one that does not. Each stub text is
# carried by that read alone: the scalar read is `eval .permissions`
# followed by the fixture's absolute path.
expect_failed_read bad-top-write-all.yml 'eval .permissions /' 7 'the top-level permissions'
expect_failed_read good.yml '.permissions | length' 9 'the top-level permissions size'
expect_failed_read bad-top-nonempty.yml '.permissions | length' 11 'the top-level permissions size'
expect_failed_read bad-top-nonempty.yml 'keys | join' 13 'the top-level permissions keys'

# The per-job read can fail on the workflow's own shape, so its failure
# is a counted finding, not a could-not-run.
jobs_dir="$(mktemp --directory)"
printf 'permissions: {}\njobs: 5\n' >"${jobs_dir}/jobs-number.yml"
jobs_exit=0
jobs_stderr="$(WORKFLOWS_DIR_OVERRIDE="${jobs_dir}" "${SCRIPT}" 2>&1 >/dev/null)" || jobs_exit=$?
rm --recursive --force -- "${jobs_dir}"
# The lines before these two are yq's own, whose wording is not the lint's.
jobs_want="${jobs_dir}/jobs-number.yml: could not evaluate workflow with yq (malformed?)"$'\n''1 permissions posture violation(s) found'
if [[ ${jobs_exit} != 1 || ${jobs_stderr} != *$'\n'"${jobs_want}" ]]; then
  printf 'FAIL jobs-number.yml: exit %s, want 1, and stderr ending %q\n  got: %s\n' \
    "${jobs_exit}" "${jobs_want}" "${jobs_stderr}" >&2
  exit 1
fi
printf 'OK   jobs-number.yml: a jobs: yq cannot list is a counted finding\n'

# A node whose tag yq cannot decode fails a later read too: the run
# stops, as it does for yq failing, though the fault is the workflow's.
mistag_dir="$(mktemp --directory)"
printf 'permissions: !!map 5\njobs: {}\n' >"${mistag_dir}/mistag.yml"
mistag_exit=0
mistag_stderr="$(WORKFLOWS_DIR_OVERRIDE="${mistag_dir}" "${SCRIPT}" 2>&1 >/dev/null)" || mistag_exit=$?
rm --recursive --force -- "${mistag_dir}"
mistag_want="cannot read the top-level permissions keys of ${mistag_dir}/mistag.yml: yq exited 1"
if [[ ${mistag_exit} != 2 || ${mistag_stderr} != *$'\n'"${mistag_want}" ]]; then
  printf 'FAIL mistag.yml: exit %s, want 2, and stderr ending %q\n  got: %s\n' \
    "${mistag_exit}" "${mistag_want}" "${mistag_stderr}" >&2
  exit 1
fi
printf 'OK   mistag.yml: a node yq cannot decode stops the run\n'

# @description Scan one workflow written to a temp dir at run time and
# compare the whole of stderr, so the shapes built here (tags) are not
# tracked files a formatter or workflow linter reads.
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

# A job's permissions are read by kind: a map carrying a tag of its own
# is still read, and a scalar carrying a map tag is no map.
expect_body job-mapscalar.yml $'permissions: {}\njobs:\n  a:\n    permissions: !!map write-all\n' 1 \
  $'DIR/job-mapscalar.yml: job a permissions has unexpected shape (kind=scalar, tag=!!map)\n1 permissions posture violation(s) found'
expect_body job-null.yml $'permissions: {}\njobs:\n  c:\n    permissions:\n' 1 \
  "DIR/job-null.yml: job c missing ${Q}permissions:${Q} block (every job must declare its own)"$'\n1 permissions posture violation(s) found'
expect_body job-scalar.yml $'permissions: {}\njobs:\n  d: 5\n' 1 \
  $'DIR/job-scalar.yml: job d has unexpected shape (kind=scalar, tag=!!int); expected a map\n1 permissions posture violation(s) found'
# A job written as an alias is read through it, as GitHub Actions reads it.
expect_body job-alias.yml $'x-job: &j\n  permissions: {}\n  steps:\n    - run: echo PAYLOAD_RAN\npermissions: {}\njobs:\n  e: *j\n' 0 ''
expect_body job-alias-bare.yml $'x-job: &j\n  steps:\n    - run: echo PAYLOAD_RAN\npermissions: {}\njobs:\n  f: *j\n' 1 \
  "DIR/job-alias-bare.yml: job f missing ${Q}permissions:${Q} block (every job must declare its own)"$'\n1 permissions posture violation(s) found'
expect_body job-alias-scalar.yml $'x-s: &s 5\npermissions: {}\njobs:\n  g: *s\n' 1 \
  $'DIR/job-alias-scalar.yml: job g has unexpected shape (kind=scalar, tag=!!int); expected a map\n1 permissions posture violation(s) found'
# GitHub Actions refuses a merge key, and the jobs one brings into jobs:
# are not listed as its own, so a merge key there is a finding.
readonly MERGE='jobs: holds a merge key, which GitHub Actions refuses; the jobs it brings in are not read'
expect_body jobs-merge.yml $'x-b: &b\n  permissions: {}\n  evil:\n    runs-on: x\npermissions: {}\njobs:\n  <<: *b\n  a:\n    permissions: {}\n' 1 \
  "DIR/jobs-merge.yml: ${MERGE}"$'\n1 permissions posture violation(s) found'
expect_body jobs-merge-inline.yml $'permissions: {}\njobs:\n  <<:\n    evil:\n      runs-on: x\n' 1 \
  "DIR/jobs-merge-inline.yml: ${MERGE}"$'\n1 permissions posture violation(s) found'
# The job rows are tab-separated, and GitHub Actions refuses a job id
# holding a tab or a line break, so such an id is a finding and the
# workflow's jobs are not read.
readonly ODD_ID='jobs: holds a job id with a tab or a line break, which GitHub Actions refuses; its jobs are not read'
expect_body job-id-tab.yml $'permissions: {}\njobs:\n  "x\\t!!str\\tmap !!map\\tmap !!map":\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 \
  "DIR/job-id-tab.yml: ${ODD_ID}"$'\n1 permissions posture violation(s) found'
expect_body job-id-xtag.yml $'permissions: {}\njobs:\n  !x "x\\t!!str\\tmap !!map\\tmap !!map":\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 \
  "DIR/job-id-xtag.yml: ${ODD_ID}"$'\n1 permissions posture violation(s) found'
expect_body job-id-merge-tag.yml $'permissions: {}\njobs:\n  !!merge "x\\t!!str\\tmap !!map\\tmap !!map":\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 \
  "DIR/job-id-merge-tag.yml: ${ODD_ID}"$'\n1 permissions posture violation(s) found'
expect_body job-id-break.yml $'permissions: {}\njobs:\n  "y\\nz":\n    permissions: {}\n' 1 \
  "DIR/job-id-break.yml: ${ODD_ID}"$'\n1 permissions posture violation(s) found'
# The job-id read failing is a counted finding, like the job rows' read.
yq_stub 'select(tostring | test(' 7
ids_exit=0
ids_stderr="$(PATH="${STUB_DIR}:${PATH}" WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
  WORKFLOW_FILE_FILTER=good.yml "${SCRIPT}" 2>&1 >/dev/null)" || ids_exit=$?
rm --recursive --force -- "${STUB_DIR}"
ids_want="${FIXTURES}/good.yml: could not evaluate workflow with yq (malformed?)"$'\n''1 permissions posture violation(s) found'
if [[ ${ids_exit} != 1 || ${ids_stderr} != "${ids_want}" ]]; then
  printf 'FAIL good.yml with the job-id read failing: exit %s, want 1, and stderr %q\n  got: %s\n' \
    "${ids_exit}" "${ids_want}" "${ids_stderr}" >&2
  exit 1
fi
printf 'OK   good.yml with the job-id read failing\n'
# yq prints one job-id count per document; counts of 0 in a file of
# several documents are no odd id, and a document whose jobs: is null
# has no ids to count rather than a read that fails. (Several documents are not refused by
# this lint; only the id message is held here.)
docs_dir="$(mktemp --directory)"
printf 'permissions: {}\njobs:\n  a:\n    permissions: {}\n---\npermissions: {}\njobs:\n' \
  >"${docs_dir}/two-docs.yml"
docs_exit=0
docs_stderr="$(WORKFLOWS_DIR_OVERRIDE="${docs_dir}" "${SCRIPT}" 2>&1 >/dev/null)" || docs_exit=$?
rm --recursive --force -- "${docs_dir}"
if [[ ${docs_exit} != 1 || ${docs_stderr} == *'tab or a line break'* || ${docs_stderr} == *'could not evaluate'* ]]; then
  printf 'FAIL two-docs.yml: exit %s, want 1, and no job-id line\n  got: %s\n' "${docs_exit}" "${docs_stderr}" >&2
  exit 1
fi
printf 'OK   two-docs.yml: per-document id counts of 0\n'
expect_body job-xtag.yml $'permissions: {}\njobs:\n  a:\n    permissions: !x\n      contents: read\n' 0 ''
expect_body job-strseq.yml $'permissions: {}\njobs:\n  b:\n    permissions: !!str [contents]\n' 1 \
  $'DIR/job-strseq.yml: job b permissions has unexpected shape (kind=seq, tag=!!str)\n1 permissions posture violation(s) found'

printf 'all tests passed\n'
