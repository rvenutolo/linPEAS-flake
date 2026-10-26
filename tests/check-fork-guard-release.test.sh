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
  'cannot read the if: of job b from DIR/if-unread.yml' '(.if |'

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

# A job key the job list cannot carry (a line break, empty, a merge key
# under `jobs:`) is a finding, never a job that is read as other names or
# as none. Each workflow below holds an unguarded write job a skipped key
# would hide.
# @arg $1 scenario name  @arg $2 workflow body  @arg $3 expected exit
# @arg $4 text stderr must hold
function expect_stderr_has() {
  local -r name="$1" body="$2" want_exit="$3" want="$4"
  local dir got_exit=0 got_stderr
  dir="$(mktemp --directory)"
  printf '%s' "${body}" >"${dir}/${name}"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != *"${want}"* ]]; then
    printf 'FAIL %s: exit %s, want %s and stderr holding %q\n  got: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}
readonly REFUSED='which GitHub Actions refuses'
expect_stderr_has job-key-line-break.yml $'jobs:\n  "a\\nb":\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 "${REFUSED}"
expect_stderr_has job-key-block-sequence.yml $'jobs:\n  ? - a\n    - b\n  : permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 "${REFUSED}"
expect_stderr_has job-key-empty.yml $'jobs:\n  "":\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 "${REFUSED}"
expect_stderr_has job-key-merge-key.yml $'x: &base\n  j:\n    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\njobs:\n  <<: *base\n' 1 "${REFUSED}"

# An App-token step is found through a job written as an alias and
# through a merge key inside the job, as the job's other reads follow both.
expect_stderr_has app-token-job-alias.yml $'x: &D\n  permissions:\n    contents: read\n  steps:\n    - uses: actions/create-github-app-token@v1\njobs:\n  a: *D\n' 1 'missing fork guard'
expect_stderr_has app-token-job-merge-key.yml $'x: &D\n  steps:\n    - uses: actions/create-github-app-token@v1\njobs:\n  a:\n    <<: *D\n    permissions:\n      contents: read\n' 1 'missing fork guard'

# A merge list is read first mapping wins (the YAML merge spec), so the
# job holds the write scope of the first mapping listed.
readonly PQ=$'p: &P\n  permissions:\n    contents: write\nq: &Q\n  permissions:\n    contents: read\n'
expect_stderr_has merge-list-write-first.yml "${PQ}"$'jobs:\n  a:\n    <<: [*P, *Q]\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 'missing fork guard'
expect_stderr_has merge-list-read-first.yml "${PQ}"$'jobs:\n  a:\n    <<: [*Q, *P]\n    steps:\n      - run: echo PAYLOAD_RAN\n' 0 ''

# A refused job key ends the read of that workflow: the unguarded write
# job beside it is not read, so the run holds this finding alone. A
# failure of the read that names the key is a counted finding too, and
# the workflow is read no further.
readonly ODD_MSG='jobs: holds a job key that is empty, holds a tab, a line break, a carriage return or a NUL, is not a scalar, or is a merge key, which GitHub Actions refuses; its jobs are not read'
expect_body odd-key-ends-read.yml $'jobs:\n  "a\\nb":\n    permissions:\n      contents: read\n    steps:\n      - run: echo PAYLOAD_RAN\n'"${WRITE_BARE#jobs:$'\n'}" 1 \
  "DIR/odd-key-ends-read.yml: ${ODD_MSG} (first: \"a\\nb\")${ONE_JOB}"
# A carriage return and a NUL are refused the same way, and the finding
# names each.
expect_body odd-key-carriage-return.yml $'jobs:\n  "a\\rb":\n    permissions:\n      contents: read\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 \
  "DIR/odd-key-carriage-return.yml: ${ODD_MSG} (first: \"a\\rb\")${ONE_JOB}"
expect_body odd-key-nul.yml $'jobs:\n  "a\\0b":\n    permissions:\n      contents: read\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 \
  "DIR/odd-key-nul.yml: ${ODD_MSG} (first: \"a\\u0000b\")${ONE_JOB}"
expect_body odd-key-unread.yml "${WRITE_BARE}" 1 \
  "DIR/odd-key-unread.yml: could not evaluate workflow with yq (malformed?)${ONE_JOB}" '!!merge'

# `jobs:` written as an alias, and a job key written as an alias, are read
# through: a guarded write job passes and an unguarded one is named by its
# own key (an alias key keeps the text the job list prints).
readonly UNGUARDED_TAIL=$'`github.repository == \'rvenutolo/linPEAS-flake\'`; got if=\'\''
readonly ALIASED_WRITE=$'    permissions:\n      contents: write\n    steps:\n      - run: echo PAYLOAD_RAN\n'
readonly ALIASED_GUARD=$'    if: github.repository == \'rvenutolo/linPEAS-flake\'\n'
expect_body jobs-alias-guarded.yml $'x-jobs: &js\n  a:\n'"${ALIASED_GUARD}${ALIASED_WRITE}"$'jobs: *js\n' 0 ''
expect_body jobs-alias-unguarded.yml $'x-jobs: &js\n  a:\n'"${ALIASED_WRITE}"$'jobs: *js\n' 1 \
  "DIR/jobs-alias-unguarded.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body job-key-alias-guarded.yml $'x-k: &k a\njobs:\n  *k :\n'"${ALIASED_GUARD}${ALIASED_WRITE}" 0 ''
expect_body job-key-alias-unguarded.yml $'x-k: &k a\njobs:\n  *k :\n'"${ALIASED_WRITE}" 1 \
  "DIR/job-key-alias-unguarded.yml: job \\*k holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"

# A job minting an App installation token needs the guard whatever the
# case of the ASCII letters in the action's owner and repository. The
# lower-case scenario is the control: neither job names the App's
# private-key secret.
readonly TOKEN_JOB_HEAD=$'on:\n  workflow_dispatch:\npermissions: {}\njobs:\n  a:\n    permissions:\n      contents: read\n    steps:\n      - uses: '
readonly TOKEN_JOB_TAIL=$'@abc\n      - run: echo PAYLOAD_RAN\n'
expect_body app-token-lower-case.yml "${TOKEN_JOB_HEAD}actions/create-github-app-token${TOKEN_JOB_TAIL}" 1 \
  "DIR/app-token-lower-case.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body app-token-mixed-case.yml "${TOKEN_JOB_HEAD}Actions/Create-GitHub-App-Token${TOKEN_JOB_TAIL}" 1 \
  "DIR/app-token-mixed-case.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body app-token-other-action.yml "${TOKEN_JOB_HEAD}actions/cache${TOKEN_JOB_TAIL}" 0 ''

# GitHub Actions reads a secret's name whatever its case, so a job
# naming the App's private key needs the guard however its ASCII letters,
# and those of the `secrets` context, are cased. The other secret is the
# control: it carries no App privilege.
readonly KEY_JOB_HEAD=$'on:\n  workflow_dispatch:\npermissions: {}\njobs:\n  a:\n    permissions:\n      contents: read\n    steps:\n      - run: echo PAYLOAD_RAN\n        env:\n          KEY: ${{ '
readonly KEY_JOB_TAIL=$' }}\n'
for spelling in secrets.BUMP_APP_PRIVATE_KEY secrets.bump_app_private_key Secrets.Bump_App_Private_Key SECRETS.BUMP_APP_PRIVATE_KEY; do
  expect_body "app-key-${spelling}.yml" "${KEY_JOB_HEAD}${spelling}${KEY_JOB_TAIL}" 1 \
    "DIR/app-key-${spelling}.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
done
expect_body app-key-other-secret.yml "${KEY_JOB_HEAD}secrets.bump_app_other_key${KEY_JOB_TAIL}" 0 ''

# GitHub Actions reads a property through the index form as well:
# `secrets['BUMP_APP_PRIVATE_KEY']` names the same key, with spaces inside
# the brackets, or inside a YAML single-quoted scalar that writes each
# quote twice. A double-quoted index is an expression error GitHub
# refuses, so it is no reference, and another secret in the index form
# is the control.
expect_body app-key-index.yml "${KEY_JOB_HEAD}secrets['BUMP_APP_PRIVATE_KEY']${KEY_JOB_TAIL}" 1 \
  "DIR/app-key-index.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body app-key-index-mixed-case.yml "${KEY_JOB_HEAD}Secrets[ 'Bump_App_Private_Key' ]${KEY_JOB_TAIL}" 1 \
  "DIR/app-key-index-mixed-case.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
# shellcheck disable=SC2016 # the workflow expression is literal text
expect_body app-key-index-yaml-single-quoted.yml "${KEY_JOB_HEAD%'${{ '}'\${{ secrets[''BUMP_APP_PRIVATE_KEY''] }}'"$'\n' 1 \
  "DIR/app-key-index-yaml-single-quoted.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body app-key-index-other-secret.yml "${KEY_JOB_HEAD}secrets['bump_app_other_key']${KEY_JOB_TAIL}" 0 ''

# A use of the `secrets` context with no literal name may read the App's
# private key, so the job needs the guard: the whole context, a name the
# expression computes, the object filter, a double-quoted index, the word
# `secrets` inside a string literal, which the reader cannot tell from a
# use, and an expression not closed on its line, which the lint reads one
# line at a time. A step id spelled `secrets` is no use of the context,
# and guarded jobs reading the whole context or holding the string literal
# are the controls.
for case in 'whole-context|toJSON(secrets)' "computed-index|secrets[format('BUMP_APP_{0}', 'PRIVATE_KEY')]" \
  'env-index|secrets[env.NAME]' 'object-filter|secrets.*' 'double-quoted-index|secrets["BUMP_APP_PRIVATE_KEY"]' \
  "string-literal|contains(github.head_ref, 'secrets')"; do
  label="${case%%|*}" shape="${case#*|}"
  expect_body "app-key-unnamed-${label}.yml" "${KEY_JOB_HEAD}${shape}${KEY_JOB_TAIL}" 1 \
    "DIR/app-key-unnamed-${label}.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
done
# shellcheck disable=SC2016 # the workflow expression is literal text
expect_body app-key-unnamed-open.yml "${KEY_JOB_HEAD%'${{ '}"$'>-\n            ${{\n            secrets.BUMP_APP_PRIVATE_KEY }}\n' 1 \
  "DIR/app-key-unnamed-open.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body app-key-unnamed-step-id.yml "${KEY_JOB_HEAD}steps.secrets.outputs.key${KEY_JOB_TAIL}" 0 ''
expect_body app-key-unnamed-guarded.yml "${KEY_JOB_HEAD/$'    permissions:'/$'    if: github.repository == \'rvenutolo/linPEAS-flake\'\n    permissions:'}toJSON(secrets)${KEY_JOB_TAIL}" 0 ''
expect_body app-key-unnamed-string-literal-guarded.yml "${KEY_JOB_HEAD/$'    permissions:'/$'    if: github.repository == \'rvenutolo/linPEAS-flake\'\n    permissions:'}contains(github.head_ref, 'secrets')${KEY_JOB_TAIL}" 0 ''

# Every job inherits the workflow-level `env:`, the one workflow-level key
# GitHub Actions lets read the `secrets` context, so a read of the App's
# private key there, or a use naming no secret, puts every job in the file
# under the guard. A guarded job beside the unguarded one shows the
# finding is per job, and another secret is the control.
readonly WF_ENV_HEAD=$'on: push\nenv:\n  KEY: ${{ '
readonly WF_ENV_TAIL=$' }}\njobs:\n  a:\n    permissions:\n      contents: read\n    steps:\n      - run: echo PAYLOAD_RAN\n  b:\n    if: github.repository == \'rvenutolo/linPEAS-flake\'\n    permissions:\n      contents: read\n    steps:\n      - run: echo PAYLOAD_RAN\n'
for case in 'named|secrets.BUMP_APP_PRIVATE_KEY' 'named-mixed-case|Secrets.Bump_App_Private_Key' \
  "index|secrets['BUMP_APP_PRIVATE_KEY']" 'unnamed|toJSON(secrets)'; do
  label="${case%%|*}" shape="${case#*|}"
  expect_body "workflow-env-${label}.yml" "${WF_ENV_HEAD}${shape}${WF_ENV_TAIL}" 1 \
    "DIR/workflow-env-${label}.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
done
# shellcheck disable=SC2016 # the workflow expression is literal text
expect_body workflow-env-open.yml "${WF_ENV_HEAD%'${{ '}"$'|-\n    ${{\n    secrets.BUMP_APP_OTHER_KEY'"${WF_ENV_TAIL}" 1 \
  "DIR/workflow-env-open.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
# A YAML escape in a double-quoted scalar is read decoded.
expect_body workflow-env-escaped.yml $'on: push\nenv:\n  KEY: "${{ s\\x65crets.BUMP_APP_PRIVATE_KEY'"${WF_ENV_TAIL/$' }}\n'/$' }}"\n'}" 1 \
  "DIR/workflow-env-escaped.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
# An `env:` written as an alias is read as the mapping it stands for.
expect_body workflow-env-alias.yml $'x-env: &e\n  KEY: ${{ toJSON(secrets) }}\nenv: *e'"${WF_ENV_TAIL#' }}'}" 1 \
  "DIR/workflow-env-alias.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body workflow-env-merge-key.yml $'x-env: &e\n  KEY: ${{ toJSON(secrets) }}\nenv:\n  <<: *e\n  OTHER: x'"${WF_ENV_TAIL#' }}'}" 1 \
  "DIR/workflow-env-merge-key.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
# A root key written as an alias of `env` or `jobs` is that key, as GitHub
# Actions reads it; one given twice, plain and as an alias, stops the read.
expect_body workflow-env-alias-key.yml $'name: &k env\non: push\n*k :\n  KEY: ${{ toJSON(secrets) }}'"${WF_ENV_TAIL#' }}'}" 1 \
  "DIR/workflow-env-alias-key.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body workflow-env-given-twice.yml $'name: &k env\non: push\nenv: {A: x}\n*k :\n  KEY: ${{ toJSON(secrets) }}'"${WF_ENV_TAIL#' }}'}" 2 \
  $'Error: env: is given more than once\ncannot read the workflow env: from DIR/workflow-env-given-twice.yml'
expect_body jobs-alias-key.yml $'name: &k jobs\non: push\n*k :'"${WRITE_BARE#jobs:}" 1 \
  "DIR/jobs-alias-key.yml: job c holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body jobs-given-twice.yml $'name: &k jobs\non: push\n'"${READ_ONLY}"$'*k :'"${WRITE_BARE#jobs:}" 1 \
  $'Error: jobs: is given more than once\nDIR/jobs-given-twice.yml: could not evaluate workflow with yq (malformed?)'"${ONE_JOB}"
expect_body workflow-env-other-secret.yml "${WF_ENV_HEAD}secrets.BUMP_APP_OTHER_KEY${WF_ENV_TAIL}" 0 ''
expect_body workflow-env-unread.yml "${WF_ENV_HEAD}secrets.BUMP_APP_OTHER_KEY${WF_ENV_TAIL}" 2 \
  'cannot read the workflow env: from DIR/workflow-env-unread.yml' '.env'

# A job calling a reusable workflow with `secrets: inherit` hands it the
# App's private key with every other secret, though no `${{ }}` names one,
# so it needs the guard. It is read through `yq`, so a quoted or aliased
# value, or a job written as an alias, is read the same. A job naming the
# key in an explicit `secrets:` map is read through that expression. A
# call passing no secrets, an empty `secrets:`, and a guarded inheriting
# job are the controls.
readonly CALL_HEAD=$'on: push\njobs:\n  a:\n    uses: o/r/.github/workflows/x.yml@0123456789012345678901234567890123456789\n'
for case in 'plain|    secrets: inherit' "quoted|    \"secrets\": !!str 'inherit'" \
  $'map|    secrets:\n      K: ${{ secrets.BUMP_APP_PRIVATE_KEY }}'; do
  label="${case%%|*}" shape="${case#*|}"
  expect_body "inherit-${label}.yml" "${CALL_HEAD}${shape}"$'\n' 1 \
    "DIR/inherit-${label}.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
done
expect_body inherit-alias.yml $'x-s: &s inherit\nx: &j\n  uses: o/r/.github/workflows/x.yml@0123456789012345678901234567890123456789\n  secrets: *s\non: push\njobs:\n  a: *j\n' 1 \
  "DIR/inherit-alias.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body inherit-none.yml "${CALL_HEAD}" 0 ''
expect_body inherit-null.yml "${CALL_HEAD}"$'    secrets:\n' 0 ''
expect_body inherit-guarded.yml "${CALL_HEAD}"$'    if: github.repository == \'rvenutolo/linPEAS-flake\'\n    secrets: inherit\n' 0 ''
expect_body inherit-unread.yml "${CALL_HEAD}"$'    secrets: inherit\n' 2 \
  'cannot read the secrets: of job a from DIR/inherit-unread.yml' '.secrets'

# A permission scope or an `if:` written as an alias is read as its
# anchored text, so each verdict matches the inline spelling.
readonly ALIAS_STEPS=$'    steps:\n      - run: echo PAYLOAD_RAN\n'
readonly ALIAS_GUARD_TEXT=$'github.repository == \'rvenutolo/linPEAS-flake\''
expect_body scope-alias-contents-write.yml $'x-w: &w write\njobs:\n  a:\n    permissions:\n      contents: *w\n'"${ALIAS_STEPS}" 1 \
  "DIR/scope-alias-contents-write.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body scope-inline-contents-write.yml $'jobs:\n  a:\n    permissions:\n      contents: write\n'"${ALIAS_STEPS}" 1 \
  "DIR/scope-inline-contents-write.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body scope-alias-id-token-write.yml $'x-w: &w write\njobs:\n  a:\n    permissions:\n      id-token: *w\n'"${ALIAS_STEPS}" 1 \
  "DIR/scope-alias-id-token-write.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body scope-inline-id-token-write.yml $'jobs:\n  a:\n    permissions:\n      id-token: write\n'"${ALIAS_STEPS}" 1 \
  "DIR/scope-inline-id-token-write.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL}${ONE_JOB}"
expect_body scope-alias-contents-read.yml $'x-r: &r read\njobs:\n  a:\n    permissions:\n      contents: *r\n'"${ALIAS_STEPS}" 0 ''
expect_body if-alias-guard.yml $'x-g: &g '"${ALIAS_GUARD_TEXT}"$'\njobs:\n  a:\n    if: *g\n    permissions:\n      contents: write\n'"${ALIAS_STEPS}" 0 ''
expect_body if-alias-other.yml $'x-g: &g other\njobs:\n  a:\n    if: *g\n    permissions:\n      contents: write\n'"${ALIAS_STEPS}" 1 \
  "DIR/if-alias-other.yml: job a holds guard-required write scope but is missing fork guard ${UNGUARDED_TAIL%\'\'}other${ONE_JOB}"

printf 'all tests passed\n'
