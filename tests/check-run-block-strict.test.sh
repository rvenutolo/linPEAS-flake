#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-run-block-strict.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/run-block-strict"

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

# Composite-action scenarios live one directory deep, each holding a single
# `action.yml`, mirroring the real `.github/actions/<name>/action.yml` layout
# the lint walks. Selection is by directory rather than by basename because
# every composite file is named `action.yml`.
function expect_composite() {
  local -r scenario="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(ACTIONS_DIR_OVERRIDE="${FIXTURES}/${scenario}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${scenario}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${scenario}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${scenario}"
}

expect good.yml 0 ""
expect good-with-comment.yml 0 ""
expect bad-missing.yml 1 "must start with"
expect bad-weak.yml 1 "must start with"
expect good-folded.yml 0 ""
expect bad-folded-missing.yml 1 "bad-folded-missing.yml: job build step[0]"
expect bad-malformed.yml 1 "could not evaluate"
expect no-such-workflow.yml 2 'selected 0 of'

expect_composite composite-good 0 ""
expect_composite composite-bad-missing 1 "composite-bad-missing/action.yml: composite step[0]"

# A composite whose YAML cannot be parsed must fail loud, exactly as a
# malformed workflow does. The fixture is generated at runtime: a committed
# unparsable `action.yml` would need its own formatter exclusion, and the
# scenario needs nothing durable beyond the parse failure itself.
malformed_dir="$(mktemp --directory)"
printf 'runs:\n  using: composite\n  steps: [this is not: valid yaml\n' \
  >"${malformed_dir}/action.yml"
malformed_exit=0
malformed_err="$(ACTIONS_DIR_OVERRIDE="${malformed_dir}" \
  "${SCRIPT}" 2>&1 >/dev/null)" || malformed_exit=$?
rm --recursive --force -- "${malformed_dir}"
if [[ ${malformed_exit} != 1 || ${malformed_err} != *"could not evaluate"* ]]; then
  printf 'FAIL malformed composite: exit %s (want 1)\n  stderr: %s\n' \
    "${malformed_exit}" "${malformed_err}" >&2
  exit 1
fi
printf 'OK   malformed composite rejected\n'

# Roots that exist and hold nothing leave the lint with no file to read, and
# an unasserted scan set makes that run byte-identical to a clean pass over a
# fully compliant tree. The diagnostic is asserted, not just the exit code: a
# check keyed on exit 2 alone passes just as happily when the message names
# the wrong scan set.
empty_workflows="$(mktemp --directory)"
empty_actions="$(mktemp --directory)"
empty_exit=0
empty_err="$(WORKFLOWS_DIR_OVERRIDE="${empty_workflows}" \
  ACTIONS_DIR_OVERRIDE="${empty_actions}" \
  "${SCRIPT}" 2>&1 >/dev/null)" || empty_exit=$?
rm --recursive --force -- "${empty_workflows}" "${empty_actions}"
if [[ ${empty_exit} != 2 ||
  ${empty_err} != *'matched 0 files via workflow and composite-action files'* ]]; then
  printf 'FAIL empty scan set: exit %s (want 2)\n  stderr: %s\n' \
    "${empty_exit}" "${empty_err}" >&2
  exit 1
fi
printf 'OK   empty scan set rejected\n'

# A job key is data, never expression text or a row field. Each key
# below closes a quoted segment if spliced into a `yq` expression (it
# would read the strict decoy's block, or print an environment variable
# or a file through `error()`), or holds the row separator `|`, which
# would move text into the step index. Read as data, every one names its
# own weak block.
key_dir="$(mktemp --directory)"
trap 'rm --recursive --force -- "${key_dir}"' EXIT
printf 'FILE_READ_MARK\n' >"${key_dir}/probe.txt"
# @arg $1 scenario name  @arg $2 the job key, written single-quoted
function expect_spliced_key() {
  local -r name="$1" key="$2"
  local got_exit=0 got_stderr want
  mkdir -- "${key_dir}/${name}"
  cat >"${key_dir}/${name}/w.yml" <<EOF
name: ${name}
on: push
jobs:
  '${key//\'/\'\'}':
    runs-on: ubuntu-latest
    steps:
      - name: weak
        run: |
          set -euo pipefail
          echo PAYLOAD_RAN
  decoy:
    runs-on: ubuntu-latest
    steps:
      - name: strict
        run: |
          set -Eeuo pipefail
          echo PAYLOAD_RAN
EOF
  got_stderr="$(PROBE=PAYLOAD_RAN PROBE_FILE="${key_dir}/probe.txt" WORKFLOWS_DIR_OVERRIDE="${key_dir}/${name}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  printf -v want '%s: job %q step[0] run: block must start with %q (got %q)\n1 run: block(s) missing strict-mode prelude' \
    "${key_dir}/${name}/w.yml" "${key}" 'set -Eeuo pipefail' 'set -euo pipefail'
  if [[ ${got_exit} != 1 || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want 1\n  stderr: %s\n' "${name}" "${got_exit}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
expect_spliced_key job-key-reads-decoy 'x" // .jobs."decoy'
expect_spliced_key job-key-env-no-pipe 'x" // error(strenv(PROBE)) // .jobs."y'
expect_spliced_key job-key-reads-env 'x" | error(strenv(PROBE)) | ."y'
expect_spliced_key job-key-reads-file 'x" | error(load_str(strenv(PROBE_FILE))) | ."y'
expect_spliced_key job-key-quote 'k"x'
expect_spliced_key job-key-backslash 'k\x'
expect_spliced_key job-key-row-separator 'a|1'
expect_spliced_key job-key-row-separator-index 'decoy|0'

# Each block is read from its own document: in a composite of two
# documents whose second holds the weak block, that block is reported,
# not judged by the first document's strict one.
mkdir -- "${key_dir}/two-docs"
printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: |\n        set -Eeuo pipefail\n---\nruns:\n  using: composite\n  steps:\n    - shell: bash\n      run: |\n        set -euo pipefail\n' \
  >"${key_dir}/two-docs/action.yml"
two_docs_exit=0
two_docs_err="$(ACTIONS_DIR_OVERRIDE="${key_dir}/two-docs" "${SCRIPT}" 2>&1 >/dev/null)" || two_docs_exit=$?
printf -v two_docs_want '%s: composite step[0] run: block must start with %q (got %q)\n1 run: block(s) missing strict-mode prelude' \
  "${key_dir}/two-docs/action.yml" 'set -Eeuo pipefail' 'set -euo pipefail'
if [[ ${two_docs_exit} != 1 || ${two_docs_err} != "${two_docs_want}" ]]; then
  printf 'FAIL composite-second-document: exit %s, want 1\n  stderr: %s\n' "${two_docs_exit}" "${two_docs_err}" >&2
  exit 1
fi
printf 'OK   composite-second-document\n'

# A workflow's job is read from its own document, and its message names
# the key it is written under, through an alias.
# @arg $1 scenario name  @arg $2 workflow body  @arg $3 expected exit
# @arg $4 expected stderr, whole, with @F@ standing for the file
# @arg $5 PATH to run under (optional)
function expect_workflow() {
  local -r name="$1" body="$2" want_exit="$3" run_path="${5:-${PATH}}"
  local got_exit=0 got_stderr want
  mkdir -- "${key_dir}/${name}"
  printf '%s' "${body}" >"${key_dir}/${name}/w.yml"
  want="${4//@F@/${key_dir}/${name}/w.yml}"
  got_stderr="$(PATH="${run_path}" WORKFLOWS_DIR_OVERRIDE="${key_dir}/${name}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
readonly WEAK_STEP=$'    steps:\n      - run: |\n          set -euo pipefail\n          echo PAYLOAD_RAN\n'
readonly STRICT_STEP=$'    steps:\n      - run: |\n          set -Eeuo pipefail\n          echo PAYLOAD_RAN\n'
printf -v weak_tail ' step[0] run: block must start with %q (got %q)\n1 run: block(s) missing strict-mode prelude' \
  'set -Eeuo pipefail' 'set -euo pipefail'
expect_workflow workflow-second-document \
  $'jobs:\n  a:\n'"${STRICT_STEP}"$'---\njobs:\n  b:\n'"${WEAK_STEP}" 1 "@F@: job b${weak_tail}"
expect_workflow job-key-alias \
  $'x-name: &ka named\njobs:\n  *ka :\n'"${WEAK_STEP}" 1 "@F@: job named${weak_tail}"
# A failing read of the job's key stops the run rather than naming no job.
mkdir -- "${key_dir}/stub"
printf '#!/usr/bin/env bash\ncase "$*" in *"].key | explode"*) exit 7 ;; esac\nexec %q "$@"\n' \
  "$(command -v yq)" >"${key_dir}/stub/yq"
chmod +x -- "${key_dir}/stub/yq"
expect_workflow job-key-unread $'jobs:\n  a:\n'"${WEAK_STEP}" 2 \
  '@F@: cannot read the key of the job at position 0' "${key_dir}/stub:${PATH}"

# A job key the job list cannot carry, and a merge key under `jobs:`,
# are findings: the weak run: block each one hides is otherwise unread.
readonly REFUSED_KEY='which GitHub Actions refuses'
readonly KEY_TAIL=$'\n1 run: block(s) missing strict-mode prelude'
expect_workflow job-key-line-break $'jobs:\n  "a\\nb":\n'"${WEAK_STEP}" 1 \
  "@F@: jobs: holds a job key that is empty, holds a line break or a tab, is not a scalar, or is a merge key, ${REFUSED_KEY}; its jobs are not read (first: \"a\\nb\")${KEY_TAIL}"
expect_workflow job-key-empty $'jobs:\n  "":\n'"${WEAK_STEP}" 1 \
  "@F@: jobs: holds a job key that is empty, holds a line break or a tab, is not a scalar, or is a merge key, ${REFUSED_KEY}; its jobs are not read (first: \"\")${KEY_TAIL}"
expect_workflow job-key-merge-key $'x: &base\n  j:\n'"${WEAK_STEP}"$'jobs:\n  <<: *base\n' 1 \
  "@F@: jobs: holds a job key that is empty, holds a line break or a tab, is not a scalar, or is a merge key, ${REFUSED_KEY}; its jobs are not read (first: \"<<\")${KEY_TAIL}"

printf 'all tests passed\n'
