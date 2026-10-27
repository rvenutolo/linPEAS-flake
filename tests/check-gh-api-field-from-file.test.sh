#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-gh-api-field-from-file.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/gh-api-field-from-file"

# shellcheck disable=SC2016 # literal backticks in the lint's message
readonly HINT='value is built from file contents; send the body on stdin with `--input -`'

# @arg $1 count of offenders
function tail_line() {
  printf '%s gh api argument(s) carry file contents or could not be read' "$1"
}

# Whole stderr is compared, not a substring: each scenario names the flag,
# the field and the block line, so two scenarios that drew the same
# message would show the lint is not telling them apart.
# @arg $1 fixture basename  @arg $2 expected exit  @arg $3 expected stderr
function expect() {
  local -r fixture="$1" want_exit="$2" want="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n  want:   %s\n' \
      "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" "${want}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

# @arg $1 fixture basename  @arg $2 block line  @arg $3 flag  @arg $4 field
function expect_one() {
  expect "$1" 1 "${FIXTURES}/$1: job put step[0] run: line $2: gh api $3 ${HINT}: $4
$(tail_line 1)"
}

# The five call shapes that once sent a file to `gh api` as one argument,
# and the other ways a value comes from a file.
expect_one bad-inline-base64.yml 4 --field content
expect_one bad-var-base64.yml 5 --field content
expect_one bad-array.yml 6 --field content
expect_one bad-cat.yml 2 --raw-field body
expect_one bad-redirect.yml 2 -f body
expect_one bad-jq-slurp.yml 2 -F body
expect_one bad-pipeline.yml 3 --field content
expect_one bad-propagated.yml 4 --raw-field body
expect_one bad-attached.yml 2 --field content

# The stdin shape, small computed values, a here-document read by `cat`,
# a `${{ }}` expression, gh's own `@FILE` reader, a value computed from a
# file-derived variable by a nested command, and an array in a block that
# spells gh but runs no `gh api` all pass.
expect good-stdin.yml 0 ''
expect good-small.yml 0 ''
expect good-no-gh-api.yml 0 ''
expect no-such-workflow.yml 2 \
  "check-gh-api-field-from-file.sh: filter no-such-workflow.yml selected 0 of 12 files for workflow and composite-action files — the filter matched nothing; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate"

# Composite actions sit one directory deep, as the real
# `.github/actions/<name>/action.yml` does.
# @arg $1 scenario directory  @arg $2 expected exit  @arg $3 expected stderr
function expect_composite() {
  local -r scenario="$1" want_exit="$2" want="$3"
  local got_exit=0 got_stderr
  got_stderr="$(ACTIONS_DIR_OVERRIDE="${FIXTURES}/${scenario}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${scenario}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${scenario}"
}
expect_composite composite-good 0 ''
expect_composite composite-bad 1 "${FIXTURES}/composite-bad/action.yml: composite step[0] run: line 2: gh api --field ${HINT}: content
$(tail_line 1)"

work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

# Generated scenarios: a workflow written to its own directory, with @F@
# in the expected stderr standing for its path.
# @arg $1 scenario name  @arg $2 workflow body  @arg $3 expected exit
# @arg $4 expected stderr, or with a leading `~` a text it must end with
# (for a `log_err` line, which opens with a timestamp)
# @arg $5 PATH to run under (optional)
function expect_workflow() {
  local -r name="$1" body="$2" want_exit="$3" run_path="${5:-${PATH}}"
  local got_exit=0 got_stderr want
  mkdir -- "${work}/${name}"
  printf '%s' "${body}" >"${work}/${name}/w.yml"
  want="${4//@F@/${work}/${name}/w.yml}"
  # BASH_ENV is cleared so a startup file that rewrites PATH cannot put
  # back a tool the scenario's PATH leaves out.
  got_stderr="$(BASH_ENV='' PATH="${run_path}" WORKFLOWS_DIR_OVERRIDE="${work}/${name}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  local matched=0
  if [[ ${want} == '~'* ]]; then
    [[ ${got_stderr} == *"${want#'~'}" ]] && matched=1
  else
    [[ ${got_stderr} == "${want}" ]] && matched=1
  fi
  if [[ ${got_exit} != "${want_exit}" || ${matched} == 0 ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n  want:   %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" "${want}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}

readonly BAD_RUN=$'set -Eeuo pipefail\n          gh api x --field content="$(base64 --wrap=0 notes.md)"\n'
readonly BAD_STEP=$'    steps:\n      - run: |\n          '"${BAD_RUN}"
readonly OK_STEP=$'    steps:\n      - run: |\n          set -Eeuo pipefail\n          gh api x --field sha="${SHA}"\n'
bad_tail="$(printf ' step[0] run: line 2: gh api --field %s: content\n%s' "${HINT}" "$(tail_line 1)")"

# Each job is read from its own document and named by its key, through
# an alias, a `jobs:` alias, a step-list alias and a body alias.
expect_workflow second-document \
  $'jobs:\n  a:\n'"${OK_STEP}"$'---\njobs:\n  b:\n'"${BAD_STEP}" 1 "@F@: job b${bad_tail}"
expect_workflow job-key-alias \
  $'x-name: &ka named\njobs:\n  *ka :\n'"${BAD_STEP}" 1 "@F@: job named${bad_tail}"
expect_workflow jobs-alias $'x-jobs: &js\n  a:\n'"${BAD_STEP}"$'jobs: *js\n' 1 "@F@: job a${bad_tail}"
expect_workflow steps-alias \
  $'x-steps: &st\n  - run: |\n      set -Eeuo pipefail\n      gh api x --field content="$(base64 --wrap=0 notes.md)"\njobs:\n  a:\n    steps: *st\n' \
  1 "@F@: job a${bad_tail}"
expect_workflow body-alias \
  $'x-body: &body |\n  set -Eeuo pipefail\n  gh api x --field content="$(base64 --wrap=0 notes.md)"\njobs:\n  a:\n    steps:\n      - run: *body\n' \
  1 "@F@: job a${bad_tail}"

# Two offenders in one block are both reported, in source order.
expect_workflow two-offenders \
  $'jobs:\n  a:\n    steps:\n      - run: |\n          set -Eeuo pipefail\n          a="$(<a.md)"\n          gh api x -f one="${a}" \\\n            --raw-field=two="$(cat b.md)"\n' 1 \
  "$(printf '@F@: job a step[0] run: line 3: gh api -f %s: one\n@F@: job a step[0] run: line 4: gh api --raw-field %s: two\n%s' "${HINT}" "${HINT}" "$(tail_line 2)")"

# An expression is replaced before parsing, as the runner substitutes it,
# so one holding shell syntax neither hides an offender nor breaks the
# parse.
expect_workflow expression-in-block \
  $'jobs:\n  a:\n    steps:\n      - run: |\n          set -Eeuo pipefail\n          echo "${{ github.event.pull_request.title }}"\n          gh api x --field content="$(base64 --wrap=0 ${{ inputs.file }})"\n' \
  1 "$(printf '@F@: job a step[0] run: line 3: gh api --field %s: content\n%s' "${HINT}" "$(tail_line 1)")"

# A block that runs gh and cannot be parsed is a finding, not a pass: its
# arguments were never read. A block that never spells gh is not parsed,
# so a step in another language holding no gh call passes.
expect_workflow unparsable-gh-block \
  $'jobs:\n  a:\n    steps:\n      - run: |\n          gh api x --field a="$(\n' 1 \
  "$(printf '@F@: job a step[0] run: block cannot be parsed as bash\n%s' "$(tail_line 1)")"
expect_workflow unparsable-block-without-gh \
  $'jobs:\n  a:\n    steps:\n      - shell: python\n        run: |\n          print("x" if (1 else\n' 0 ''

# A file whose YAML cannot be parsed is a finding. yq's own error comes
# first.
expect_workflow malformed $'jobs:\n  a: [this is not: valid yaml\n' 1 \
  "$(printf '~@F@: could not evaluate workflow or action with yq (malformed?)\n%s' "$(tail_line 1)")"

# A job key the job list cannot carry is a finding and the file's jobs
# are not read: the offender it hides is not reported.
expect_workflow job-key-line-break $'jobs:\n  "a\\nb":\n'"${BAD_STEP}" 1 \
  "@F@: jobs: holds a job key that is empty, holds a tab, a line break, a carriage return or a NUL, is not a scalar, or is a merge key, which GitHub Actions refuses; its jobs are not read (first: \"a\\nb\")
$(tail_line 1)"

# Failing reads stop the run rather than score the block clean: the job
# key named in a diagnostic, and the parse-tree read.
mkdir -- "${work}/yq-stub" "${work}/jq-stub"
printf '#!/usr/bin/env bash\ncase "$*" in *"].key | explode"*) exit 7 ;; esac\nexec %q "$@"\n' \
  "$(command -v yq)" >"${work}/yq-stub/yq"
printf '#!/usr/bin/env bash\nexit 5\n' >"${work}/jq-stub/jq"
chmod +x -- "${work}/yq-stub/yq" "${work}/jq-stub/jq"
expect_workflow job-key-unread $'jobs:\n  a:\n'"${BAD_STEP}" 2 \
  '@F@: cannot read the key of the job at position 0' "${work}/yq-stub:${PATH}"
expect_workflow jq-fails $'jobs:\n  a:\n'"${OK_STEP}" 2 \
  '~ERROR jq failed reading a shfmt parse tree' "${work}/jq-stub:${PATH}"

# A missing parser is a could-not-run: a run that read no block must not
# report the tree clean. The PATH holds every tool the lint needs except
# shfmt.
mkdir -- "${work}/no-shfmt"
for tool in bash yq jq base64 env; do
  ln --symbolic -- "$(command -v "${tool}")" "${work}/no-shfmt/${tool}"
done
expect_workflow shfmt-absent $'jobs:\n  a:\n'"${OK_STEP}" 2 \
  '~ERROR missing required tool: shfmt' "${work}/no-shfmt"

# Roots that exist and hold nothing leave the lint with no file to read,
# which is a could-not-run rather than a clean tree.
mkdir -- "${work}/empty-workflows" "${work}/empty-actions"
empty_exit=0
empty_err="$(WORKFLOWS_DIR_OVERRIDE="${work}/empty-workflows" \
  ACTIONS_DIR_OVERRIDE="${work}/empty-actions" \
  "${SCRIPT}" 2>&1 >/dev/null)" || empty_exit=$?
if [[ ${empty_exit} != 2 ||
  ${empty_err} != *'matched 0 files via workflow and composite-action files'* ]]; then
  printf 'FAIL empty scan set: exit %s (want 2)\n  stderr: %s\n' \
    "${empty_exit}" "${empty_err}" >&2
  exit 1
fi
printf 'OK   empty scan set rejected\n'
