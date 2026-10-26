#!/usr/bin/env bash
# tests/check-notify-label-descriptions.test.sh
#
# Verdict + failure-mode matrix for
# scripts/check-notify-label-descriptions.sh. Every workflow a scenario
# reads is written into a temp directory at run time rather than kept
# under tests/fixtures/: one scenario needs a file that is not valid
# YAML, and a `.yml` on disk that no parser accepts fails the formatter
# before any harness runs.
set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-notify-label-descriptions.sh"

failures=0

# A description of exactly the cap, and one character past it. The cap is
# asserted from both sides so a change that moves the boundary by one
# cannot pass.
readonly AT_CAP='scorecard check(s) scored below 10, the payload was unreadable, or the scan could not run xxxxxxxxxx'
readonly OVER_CAP="${AT_CAP}x"

# @description Write a workflow that files one label through the notify
# composite.
# @arg $1 destination path  @arg $2 label  @arg $3 label description
function write_caller() {
  cat >"$1" <<EOF
name: caller
on:
  workflow_dispatch:
jobs:
  notify:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/notify-workflow-result
        with:
          label: $2
          label-description: "$3"
EOF
}

# @description Write a workflow that files one label through the notify
# composite with each piece given as raw YAML, so a piece can be an alias.
# @arg $1 destination path  @arg $2 anchor lines before `jobs:` (may be empty)
# @arg $3 the step's `uses:`  @arg $4 `label:` value  @arg $5 `label-description:` value
function write_anchored_caller() {
  {
    printf 'name: caller\non: push\n'
    [[ -z $2 ]] || printf '%s\n' "$2"
    printf 'jobs:\n  notify:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: %s\n        with:\n          label: %s\n          label-description: %s\n' \
      "$3" "$4" "$5"
  } >"$1"
}

# @description Write a workflow whose job `a` merges two steps' jobs.
# The over-cap step is P and the in-cap step is Q.
# @arg $1 destination path  @arg $2 merge list, e.g. "*P, *Q"
function write_merge_list_caller() {
  {
    printf 'name: caller\non:\n  workflow_dispatch:\n'
    printf 'x-p: &P {steps: [{uses: ./.github/actions/notify-workflow-result, with: {label: l, label-description: "%s"}}]}\n' "${OVER_CAP}"
    printf 'x-q: &Q {steps: [{uses: ./.github/actions/notify-workflow-result, with: {label: l, label-description: ok}}]}\n'
    printf 'jobs:\n  a: {<<: [%s]}\n' "$2"
  } >"$1"
}

# @description Run the lint against a directory of workflows.
# @arg $1 scenario name  @arg $2 workflow dir  @arg $3 expected exit
# @arg $4 expected output substring (empty skips)
function run_scenario() {
  local -r name="$1" dir="$2" expected_exit="$3" expected_msg="$4"
  local out_file outcome_file
  out_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" "${out_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  harness_assert_record "${name}" "${expected_msg}" "${outcome_file}" "${out_file}"
  rm --force -- "${outcome_file}" "${out_file}"
}

function main() {
  local root
  root="$(mktemp --directory)"

  # A description at the cap passes: the boundary belongs to the legal
  # side, which is what the API accepts.
  mkdir -p "${root}/at-cap"
  write_caller "${root}/at-cap/a.yml" 'alpha-drift' "${AT_CAP}"
  run_scenario 'a description exactly at the cap passes' "${root}/at-cap" 0 \
    '1 label description(s) across 1 caller workflow(s)'

  # One character past the cap is a description the labels API rejects,
  # so the wording in the tree can never reach the label.
  mkdir -p "${root}/over-cap"
  write_caller "${root}/over-cap/a.yml" 'alpha-drift' "${OVER_CAP}"
  run_scenario 'a description one character past the cap fails' "${root}/over-cap" 1 \
    'label alpha-drift description is 101 characters, over the 100-character cap'

  # Two workflows filing one label with different wording overwrite each
  # other whenever one opens an issue, so the description a maintainer sees
  # is whichever opened one last.
  mkdir -p "${root}/conflict"
  write_caller "${root}/conflict/a.yml" 'beta-drift' 'beta drifted, or the check could not run'
  write_caller "${root}/conflict/b.yml" 'beta-drift' 'beta drifted'
  run_scenario 'one label with two descriptions fails' "${root}/conflict" 1 \
    'label beta-drift is filed with more than one description'

  # A merge list inside a job is read first mapping wins, as the YAML
  # merge specification says, so the first-listed step decides.
  mkdir -p "${root}/merge-over-first"
  write_merge_list_caller "${root}/merge-over-first/a.yml" '*P, *Q'
  run_scenario 'a merge list with the over-cap step first fails' "${root}/merge-over-first" 1 \
    'label l description is 101 characters, over the 100-character cap'
  mkdir -p "${root}/merge-ok-first"
  write_merge_list_caller "${root}/merge-ok-first/a.yml" '*Q, *P'
  # A second caller keeps this output distinct from the at-cap scenario.
  write_caller "${root}/merge-ok-first/b.yml" 'gamma-drift' 'gamma'
  run_scenario 'a merge list with the in-cap step first passes' "${root}/merge-ok-first" 0 \
    '2 label description(s) across 2 caller workflow(s)'

  # A merge key directly under jobs: is a key GitHub Actions refuses, and
  # the jobs it brings in are never read, so it is a finding.
  mkdir -p "${root}/merge-under-jobs"
  {
    printf 'name: caller\non:\n  workflow_dispatch:\n'
    printf 'x-base: &base {a: {steps: [{uses: ./.github/actions/notify-workflow-result, with: {label: l, label-description: "%s"}}]}}\n' "${OVER_CAP}"
    printf 'jobs:\n  <<: *base\n'
  } >"${root}/merge-under-jobs/a.yml"
  run_scenario 'a merge key under jobs: is refused' "${root}/merge-under-jobs" 1 \
    "notify-label-descriptions lint: ${root}/merge-under-jobs/a.yml: jobs: holds a job key"

  # A root key written as an alias of `jobs` is `jobs:`, as GitHub Actions
  # reads it, so the description under it is held to the cap. One given
  # twice, plain and as an alias, is a workflow the lint cannot read.
  mkdir -p "${root}/jobs-alias-key" "${root}/jobs-given-twice"
  write_caller "${root}/jobs-alias-key/a.yml" 'epsilon-drift' "${OVER_CAP}"
  sed --in-place --expression='s/^name: caller$/name: \&k jobs/' --expression='s/^jobs:$/*k :/' \
    -- "${root}/jobs-alias-key/a.yml"
  run_scenario 'a jobs: key written as an alias is read' "${root}/jobs-alias-key" 1 \
    'label epsilon-drift description is 101 characters, over the 100-character cap'
  write_caller "${root}/jobs-given-twice/a.yml" 'zeta-drift' 'zeta'
  sed --in-place --expression='s/^name: caller$/name: \&k jobs\njobs: {}/' --expression='s/^jobs:$/*k :/' \
    -- "${root}/jobs-given-twice/a.yml"
  run_scenario 'a jobs: key given twice is a could-not-run' "${root}/jobs-given-twice" 2 \
    "${root}/jobs-given-twice/a.yml could not be parsed"

  # yq's own error text stays out of the output: the lint's line is the
  # whole report for a workflow it could not read.
  mkdir -p "${root}/unparsable-only"
  printf 'jobs: [\n  this is not: valid: yaml\n' >"${root}/unparsable-only/a.yml"
  local only_out only_rc=0
  only_out="$(WORKFLOWS_DIR_OVERRIDE="${root}/unparsable-only" "${SCRIPT}" 2>&1)" || only_rc=$?
  if [[ ${only_rc} -ne 2 || ${only_out} != "notify-label-descriptions lint: ${root}/unparsable-only/a.yml could not be parsed" ]]; then
    printf 'FAIL: an unparsable workflow reports one line — exit %d\n%s\n' "${only_rc}" "${only_out}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: an unparsable workflow reports one line (exit %d)\n' "${only_rc}"
  fi

  # A failing read of the job keys is a could-not-run of its own, even
  # when the read of the steps would succeed. The shim fails only the
  # read that prints keys as JSON.
  local stub_dir real_yq
  stub_dir="$(mktemp --directory)"
  real_yq="$(command -v yq)"
  cat >"${stub_dir}/yq" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ \${arg} == *'to_json(0)'* ]]; then
    exit 9
  fi
done
exec ${real_yq} "\$@"
EOF
  chmod +x -- "${stub_dir}/yq"
  mkdir -p "${root}/key-read-fails"
  write_caller "${root}/key-read-fails/a.yml" 'delta-drift' 'delta'
  PATH="${stub_dir}:${PATH}" run_scenario 'a failing job-key read is a could-not-run' "${root}/key-read-fails" 2 \
    "${root}/key-read-fails/a.yml could not be parsed"
  rm --force -- "${stub_dir}/yq"
  rmdir -- "${stub_dir}"

  # A value written as a YAML alias is read as its anchored text, so the
  # cap and the agreement rule hold for it as they do inline.
  local -r composite='./.github/actions/notify-workflow-result'
  mkdir -p "${root}/uses-alias-over" "${root}/uses-alias-over-sole"
  write_anchored_caller "${root}/uses-alias-over/a.yml" "x-u: &u ${composite}" '*u' 'eta-drift' "\"${OVER_CAP}\""
  write_caller "${root}/uses-alias-over/b.yml" 'theta-drift' 'theta'
  run_scenario 'an over-cap description under an aliased uses fails' "${root}/uses-alias-over" 1 \
    'label eta-drift description is 101 characters, over the 100-character cap'
  write_anchored_caller "${root}/uses-alias-over-sole/a.yml" "x-u: &u ${composite}" '*u' 'iota-drift' "\"${OVER_CAP}\""
  run_scenario 'an aliased uses is the only notify caller' "${root}/uses-alias-over-sole" 1 \
    'label iota-drift description is 101 characters, over the 100-character cap'

  mkdir -p "${root}/label-alias-conflict"
  write_anchored_caller "${root}/label-alias-conflict/a.yml" 'x-l: &l kappa-drift' "${composite}" '*l' 'one'
  write_anchored_caller "${root}/label-alias-conflict/b.yml" '' "${composite}" 'kappa-drift' 'two'
  run_scenario 'an aliased label with two descriptions fails' "${root}/label-alias-conflict" 1 \
    'label kappa-drift is filed with more than one description'

  mkdir -p "${root}/desc-alias-over" "${root}/desc-alias-agree"
  write_anchored_caller "${root}/desc-alias-over/a.yml" "x-d: &d \"${OVER_CAP}\"" "${composite}" 'lambda-drift' '*d'
  run_scenario 'an aliased over-cap description fails' "${root}/desc-alias-over" 1 \
    'label lambda-drift description is 101 characters, over the 100-character cap'
  write_anchored_caller "${root}/desc-alias-agree/a.yml" 'x-d: &d same' "${composite}" 'mu-drift' '*d'
  write_anchored_caller "${root}/desc-alias-agree/b.yml" '' "${composite}" 'mu-drift' 'same'
  write_caller "${root}/desc-alias-agree/c.yml" 'nu-drift' 'nu'
  write_caller "${root}/desc-alias-agree/d.yml" 'xi-drift' 'xi'
  run_scenario 'an aliased description that agrees passes' "${root}/desc-alias-agree" 0 \
    '3 label description(s) across 4 caller workflow(s)'

  # A description anchored on null is no description, as written inline.
  mkdir -p "${root}/desc-alias-null"
  write_anchored_caller "${root}/desc-alias-null/a.yml" 'x-n: &n null' "${composite}" 'omicron-drift' '*n'
  write_caller "${root}/desc-alias-null/b.yml" 'pi-drift' 'pi'
  write_caller "${root}/desc-alias-null/c.yml" 'rho-drift' 'rho'
  write_caller "${root}/desc-alias-null/d.yml" 'sigma-drift' 'sigma'
  run_scenario 'a description aliased to null is no description' "${root}/desc-alias-null" 0 \
    '3 label description(s) across 3 caller workflow(s)'

  # Every piece several aliases deep: the job, its step list, the step, its
  # inputs, the composite and the description.
  mkdir -p "${root}/deep-alias"
  {
    printf 'name: caller\non: push\n'
    printf 'x-u: &u %s\nx-d: &d "%s"\nx-l: &l tau-drift\n' "${composite}" "${OVER_CAP}"
    printf 'x-with: &with\n  label: *l\n  label-description: *d\n'
    printf 'x-step: &step\n  uses: *u\n  with: *with\nx-steps: &steps\n  - *step\n'
    printf 'x-job: &job\n  runs-on: ubuntu-latest\n  steps: *steps\njobs:\n  notify: *job\n'
  } >"${root}/deep-alias/a.yml"
  run_scenario 'a job, steps, step and inputs aliased deep are read' "${root}/deep-alias" 1 \
    'label tau-drift description is 101 characters, over the 100-character cap'

  # An aliased value in a position the lint never reads changes nothing.
  mkdir -p "${root}/unread-alias"
  write_anchored_caller "${root}/unread-alias/a.yml" "x-e: &e unread" "${composite}
        name: *e
        env: {UNREAD: *e}" 'upsilon-drift' "\"${OVER_CAP}\""
  run_scenario 'an aliased value the lint never reads is ignored' "${root}/unread-alias" 1 \
    'label upsilon-drift description is 101 characters, over the 100-character cap'

  # A scan set holding workflows but no notify caller means the composite
  # moved or was renamed. Scored clean, that is a lint reporting on a
  # composite it never found.
  mkdir -p "${root}/no-caller"
  cat >"${root}/no-caller/a.yml" <<'EOF'
name: no caller
on:
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
EOF
  run_scenario 'a scan set with no notify caller is a could-not-run' "${root}/no-caller" 2 \
    'none uses .github/actions/notify-workflow-result'

  # A workflow the parser cannot read is a workflow this lint did not
  # examine, which must not be scored as one holding no violation.
  mkdir -p "${root}/unparsable"
  printf 'jobs: [\n  this is not: valid: yaml\n' >"${root}/unparsable/a.yml"
  run_scenario 'an unparsable workflow is a could-not-run' "${root}/unparsable" 2 \
    "${root}/unparsable/a.yml could not be parsed"

  # An empty scan root is the deliberate-fixture case the shared
  # enumeration helper gates behind LINT_ALLOW_EMPTY_SCAN.
  mkdir -p "${root}/empty"
  local out_file actual_exit=0
  out_file="$(mktemp)"
  WORKFLOWS_DIR_OVERRIDE="${root}/empty" "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  if [[ ${actual_exit} -ne 2 ]] ||
    ! grep --fixed-strings --quiet -- 'empty scan set' "${out_file}"; then
    printf 'FAIL: an empty scan root is a could-not-run — exit %d\n' "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: an empty scan root is a could-not-run (exit %d)\n' "${actual_exit}"
  fi
  rm --force -- "${out_file}"

  rm --recursive --force -- "${root}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
