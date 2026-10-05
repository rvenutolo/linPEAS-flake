#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-fork-guard-release.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/fork-guard-release"

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

expect good.yml 0 ""
expect good-read-only.yml 0 ""
expect bad-no-if.yml 1 "missing fork guard"
expect bad-wrong-repo.yml 1 "missing fork guard"
expect bad-other-if.yml 1 "missing fork guard"
expect bad-actions-no-if.yml 1 "missing fork guard"
expect good-actions-guarded.yml 0 ""
expect bad-app-token-no-if.yml 1 "missing fork guard"
expect good-app-token-guarded.yml 0 ""

# A workflow yq cannot parse must fail loud, not empty the scan silently.
expect bad-malformed.yml 1 "could not evaluate"
expect no-such-workflow.yml 2 'selected 0 of'

# @description Scan one workflow written to a temp dir at run time and
# compare the whole of stderr, so the shapes built here (several
# documents) are not tracked files a formatter or workflow linter reads.
# With a stub pattern, the `yq` call whose arguments hold it exits 7.
# @arg $1 file name, which is also the scenario's label
# @arg $2 file body  @arg $3 expected exit status
# @arg $4 expected stderr, with DIR standing for the temp dir
# @arg $5 argument text of a `yq` read made to fail (optional)
function expect_body() {
  local -r name="$1" body="$2" want_exit="$3" pattern="${5:-}"
  local dir stub_dir real_yq run_path="${PATH}" got_exit=0 got_stderr want
  dir="$(mktemp --directory)"
  printf '%s' "${body}" >"${dir}/${name}"
  want="${4//DIR/${dir}}"
  if [[ -n ${pattern} ]]; then
    real_yq="$(command -v yq)"
    stub_dir="$(mktemp --directory)"
    printf '#!/usr/bin/env bash\ncase "$*" in *%q*) exit 7 ;; esac\nexec %q "$@"\n' \
      "${pattern}" "${real_yq}" >"${stub_dir}/yq"
    chmod +x -- "${stub_dir}/yq"
    run_path="${stub_dir}:${PATH}"
  fi
  got_stderr="$(PATH="${run_path}" WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ -n ${pattern} ]]; then rm --recursive --force -- "${stub_dir}"; fi
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s, and stderr %q\n  got: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}

# GitHub Actions reads a workflow file as one YAML document and refuses
# one holding several, so such a file is a finding whatever each
# document holds, and is read no further.
readonly SEVERAL='holds several YAML documents; a workflow file must hold one'
readonly ONE_JOB=$'\n1 guard-required job(s) missing fork guard'
readonly READ_ONLY=$'jobs:\n  a:\n    permissions:\n      contents: read\n    steps:\n      - run: echo PAYLOAD_RAN\n'
readonly WRITE_GUARDED=$'jobs:\n  b:\n    if: github.repository == \'rvenutolo/linPEAS-flake\'\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n'
readonly WRITE_BARE=$'jobs:\n  c:\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n'
expect_body several-docs.yml "${READ_ONLY}"$'---\n'"${WRITE_BARE}" 1 "DIR/several-docs.yml: ${SEVERAL}${ONE_JOB}"
expect_body several-docs-first.yml "${WRITE_BARE}"$'---\n'"${READ_ONLY}" 1 "DIR/several-docs-first.yml: ${SEVERAL}${ONE_JOB}"
expect_body several-docs-guarded.yml "${READ_ONLY}"$'---\n'"${WRITE_GUARDED}" 1 "DIR/several-docs-guarded.yml: ${SEVERAL}${ONE_JOB}"
expect_body one-doc-guarded.yml "${WRITE_GUARDED}" 0 ''
# The document count is the workflow's first read: its failure is a
# counted finding, and the workflow is read no further.
expect_body count-unread.yml "${WRITE_BARE}" 1 \
  "DIR/count-unread.yml: could not evaluate workflow with yq (malformed?)${ONE_JOB}" 'document_index'
# A read of one job after the job list has been read stops the run.
expect_body if-unread.yml "${WRITE_GUARDED}" 2 \
  'cannot read the if: of job b from DIR/if-unread.yml' '| .if //'

# A job key is data, never expression text. Each key below closes a
# quoted segment if spliced into a `yq` expression: it would read no
# permission (or the read-only decoy's) and pass the job, or print an
# environment variable or a file through `error()`. Read as data, every
# one names its own unguarded write job.
probe_dir="$(mktemp --directory)"
trap 'rm --recursive --force -- "${probe_dir}"' EXIT
printf 'FILE_READ_MARK\n' >"${probe_dir}/probe.txt"
export PROBE=PAYLOAD_RAN PROBE_FILE="${probe_dir}/probe.txt"
readonly BT=$'\x60'
# @arg $1 scenario name, which is also the file name  @arg $2 the job key
function expect_spliced_key() {
  local -r name="$1" key="$2"
  local quoted
  printf -v quoted '%q' "${key}"
  expect_body "${name}" $'jobs:\n  \''"${key//\'/\'\'}"$'\':\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n  decoy:\n    permissions:\n      contents: read\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 \
    "DIR/${name}: job ${quoted} holds guard-required write scope but is missing fork guard ${BT}github.repository == 'rvenutolo/linPEAS-flake'${BT}; got if=''${ONE_JOB}"
}
expect_spliced_key job-key-reads-decoy.yml 'x" // .jobs."decoy'
expect_spliced_key job-key-reads-nothing.yml 'x" | select(false) | ."y'
expect_spliced_key job-key-reads-env.yml 'x" | error(strenv(PROBE)) | ."y'
expect_spliced_key job-key-reads-file.yml 'x" | error(load_str(strenv(PROBE_FILE))) | ."y'
expect_spliced_key job-key-quote.yml 'k"x'
expect_spliced_key job-key-backslash.yml 'k\x'

# The job's body and its `if:` are read by the same key: a key that
# reads the decoy's body misses an App token the job mints, and one that
# reads the decoy's `if:` borrows its guard.
printf -v quoted_decoy '%q' 'x" // .jobs."decoy'
expect_body job-key-reads-decoy-body.yml $'jobs:\n  \'x" // .jobs."decoy\':\n    permissions:\n      contents: read\n    steps:\n      - uses: actions/create-github-app-token@v1\n  decoy:\n    permissions:\n      contents: read\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 \
  "DIR/job-key-reads-decoy-body.yml: job ${quoted_decoy} holds guard-required write scope but is missing fork guard ${BT}github.repository == 'rvenutolo/linPEAS-flake'${BT}; got if=''${ONE_JOB}"
expect_body job-key-reads-decoy-guard.yml $'jobs:\n  \'x" // .jobs."decoy\':\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n  decoy:\n    if: github.repository == \'rvenutolo/linPEAS-flake\'\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 \
  "DIR/job-key-reads-decoy-guard.yml: job ${quoted_decoy} holds guard-required write scope but is missing fork guard ${BT}github.repository == 'rvenutolo/linPEAS-flake'${BT}; got if=''${ONE_JOB}"
# A key is looked up by its exact text: `*` and `?` are no wildcards.
# Read as a pattern, the key below would borrow its sibling's guard.
expect_body job-key-wildcard.yml $'jobs:\n  \'a*\':\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n  ab:\n    if: github.repository == \'rvenutolo/linPEAS-flake\'\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 \
  "DIR/job-key-wildcard.yml: job a\\* holds guard-required write scope but is missing fork guard ${BT}github.repository == 'rvenutolo/linPEAS-flake'${BT}; got if=''${ONE_JOB}"
# A key written twice is read as `yq`'s own lookup reads it, the last
# one, once for each time the job list holds it.
expect_body job-key-twice.yml $'jobs:\n  a:\n    permissions:\n      contents: read\n    steps:\n      - run: echo PAYLOAD_RAN\n  a:\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 \
  "DIR/job-key-twice.yml: job a holds guard-required write scope but is missing fork guard ${BT}github.repository == 'rvenutolo/linPEAS-flake'${BT}; got if=''"$'\n'"DIR/job-key-twice.yml: job a holds guard-required write scope but is missing fork guard ${BT}github.repository == 'rvenutolo/linPEAS-flake'${BT}; got if=''"$'\n2 guard-required job(s) missing fork guard'
# A job keyed by an alias is looked up by the key the job list prints.
expect_body job-key-alias.yml $'x-name: &ka named\njobs:\n  *ka :\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 \
  "DIR/job-key-alias.yml: job \\*ka holds guard-required write scope but is missing fork guard ${BT}github.repository == 'rvenutolo/linPEAS-flake'${BT}; got if=''${ONE_JOB}"

printf 'all tests passed\n'
