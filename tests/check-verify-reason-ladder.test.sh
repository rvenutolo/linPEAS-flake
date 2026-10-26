#!/usr/bin/env bash
# tests/check-verify-reason-ladder.test.sh
#
# Failure-mode harness for scripts/check-verify-reason-ladder.sh.
#
# Each scenario is a self-contained miniature verify workflow plus the
# reason-token doc it is checked against, so one assertion fires per
# scenario and the expected message discriminates it from its siblings.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-verify-reason-ladder.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/verify-reason-ladder"

failures=0

# @description Run the script against one scenario; assert exit code and stderr.
# @arg $1 scenario directory name under FIXTURES/
# @arg $2 workflow file basename within that directory
# @arg $3 expected exit code (0, 1, or 2)
# @arg $4 expected stderr substring (empty string skips the check)
function expect() {
  local -r scenario="$1"
  local -r workflow="$2"
  local -r want_exit="$3"
  local -r want_msg="$4"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local got_exit=0
  VERIFY_WORKFLOW_OVERRIDE="${FIXTURES}/${scenario}/${workflow}" \
    VERIFICATION_DOC_OVERRIDE="${FIXTURES}/${scenario}/verification.md" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"

  if [[ ${got_exit} -ne ${want_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${scenario}" "${want_exit}" "${got_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${want_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${want_msg}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${scenario}" "${want_msg}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${scenario}" "${got_exit}"
  fi

  harness_assert_record "${scenario}" "${want_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

# @description A reason-ladder-exempt marker on a step the attribution env
# already reads excuses nothing, and neither does one on the attribution
# step itself — but for two different reasons, so each gets its own
# diagnostic: assertion 1 skips the attribution step unconditionally
# regardless of any marker, while it would have passed the referenced step
# because the env already reads it, not because assertion 1 skips it. Both
# arms are covered by the one fixture — 'step-alpha', which the env
# already reads via STEP_ALPHA, and 'attribute', the ladder's own step —
# so both diagnostics come from one invocation. They are asserted on one
# record via harness_assert_also rather than as two separate `expect`
# calls: driving the script twice against the same fixture would produce
# two byte-identical records asserting different substrings, which is
# exactly the collapsed-coverage shape the discrimination gate exists to
# catch.
function expect_unearned_exempt() {
  local -r scenario='bad-unearned-exempt'
  local -r referenced_msg='reason-ladder-exempt marker on step id step-alpha excuses nothing; the attribution env already reads this step, so assertion 1 would have passed it whether or not the marker were there'
  local -r attribute_msg='reason-ladder-exempt marker on step id attribute excuses nothing; assertion 1 skips the attribution step unconditionally, so an exemption on it changes nothing'

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local got_exit=0
  VERIFY_WORKFLOW_OVERRIDE="${FIXTURES}/${scenario}/workflow.yml" \
    VERIFICATION_DOC_OVERRIDE="${FIXTURES}/${scenario}/verification.md" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${scenario}" "${referenced_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  harness_assert_also "${attribute_msg}"

  if [[ ${got_exit} -ne 1 ]]; then
    printf 'FAIL: %s — expected exit 1, got %d\n' "${scenario}" "${got_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${referenced_msg}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing the referenced-step diagnostic\n' "${scenario}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${attribute_msg}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing the attribution-step diagnostic\n' "${scenario}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${scenario}" "${got_exit}"
  fi

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

# @description Run the script on the good workflow rewritten by one sed
# program, and compare exit code and the whole of stderr.
# @arg $1 scenario name  @arg $2 sed program  @arg $3 expected exit
# @arg $4 the whole expected stderr, with DIR for the temp directory
# @arg $5 optional locale the script runs under
function expect_rewritten() {
  local -r name="$1" program="$2" want_exit="$3" locale="${5:-${LC_ALL:-}}"
  local dir stderr_file stdout_file outcome_file want
  dir="$(mktemp --directory)"
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  sed "${program}" -- "${FIXTURES}/good/workflow.yml" >"${dir}/workflow.yml"
  want="${4//DIR/${dir}}"

  local got_exit=0
  LC_ALL="${locale}" VERIFY_WORKFLOW_OVERRIDE="${dir}/workflow.yml" \
    VERIFICATION_DOC_OVERRIDE="${FIXTURES}/good/verification.md" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"

  if [[ ${got_exit} -ne ${want_exit} || "$(cat -- "${stderr_file}")" != "${want}" ]]; then
    printf 'FAIL: %s — expected exit %d and stderr %q; got exit %d and stderr %q\n' \
      "${name}" "${want_exit}" "${want}" "${got_exit}" "$(cat -- "${stderr_file}")" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${got_exit}"
  fi

  # The recorded substring is the first line, as one may not hold a line
  # break.
  local record="${want%%$'\n'*}"
  harness_assert_record "${name}" "${record#"${dir}/"}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --recursive --force -- "${dir}" "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

# @description Run the script under en_US.UTF-8 on the good workflow
# rewritten by one sed program, as `expect_rewritten` does. In that locale
# a bash range such as `[A-Za-z0-9_]` also matches non-ASCII letters.
function expect_en_us() {
  expect_rewritten "$1" "$2" "$3" "$4" en_US.UTF-8
}

# @description A merge list inside the verify job is read first mapping
# wins, as the YAML merge specification says; yq reads the last one unless
# told otherwise. One mapping carries a step the attribution env misses,
# the other does not.
# @arg $1 scenario name  @arg $2 the merge list  @arg $3 expected exit
# @arg $4 expected stderr substring (empty skips the check)
function expect_merge_order() {
  local -r name="$1" order="$2" want_exit="$3" want_msg="$4"
  local dir stderr_file stdout_file outcome_file
  dir="$(mktemp --directory)"
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  cat >"${dir}/workflow.yml" <<EOF
name: fixture-verify
on:
  workflow_dispatch:
permissions: {}
x-with-bravo: &with-bravo
  steps:
    - id: step-alpha
      run: echo PAYLOAD_RAN
    - id: step-bravo
      run: echo PAYLOAD_RAN
    - id: attribute
      env:
        STEP_ALPHA: \${{ steps.step-alpha.outcome }}
      run: |
        if [[ \${STEP_ALPHA} == 'failure' ]]; then reason='alpha-failed'; fi
x-without-bravo: &without-bravo
  steps:
    - id: step-alpha
      run: echo PAYLOAD_RAN
    - id: attribute
      env:
        STEP_ALPHA: \${{ steps.step-alpha.outcome }}
      run: |
        if [[ \${STEP_ALPHA} == 'failure' ]]; then reason='alpha-failed'; fi
jobs:
  verify:
    <<: ${order}
EOF
  local got_exit=0
  VERIFY_WORKFLOW_OVERRIDE="${dir}/workflow.yml" \
    VERIFICATION_DOC_OVERRIDE="${FIXTURES}/good/verification.md" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"

  if [[ ${got_exit} -ne ${want_exit} ]] ||
    { [[ -n ${want_msg} ]] && ! grep --fixed-strings --quiet -- "${want_msg}" "${stderr_file}"; }; then
    printf 'FAIL: %s — expected exit %d and stderr containing %q; got exit %d and stderr %q\n' \
      "${name}" "${want_exit}" "${want_msg}" "${got_exit}" "$(cat -- "${stderr_file}")" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${got_exit}"
  fi

  harness_assert_record "${name}" "${want_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --recursive --force -- "${dir}" "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

# @description A merge list inside the attribution step is read first
# mapping wins as well: the step's env and its run body each come from the
# first mapping that carries them. The env block and the run body are read
# by separate `yq` calls, so each read has its own scenario pair.
# @arg $1 scenario name  @arg $2 `env` or `run`: which key the merge list
# carries  @arg $3 the merge list  @arg $4 expected exit
# @arg $5 expected stderr substring (empty skips the check)
function expect_step_merge() {
  local -r name="$1" carried="$2" order="$3" want_exit="$4" want_msg="$5"
  local dir stderr_file stdout_file outcome_file
  dir="$(mktemp --directory)"
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  {
    cat <<EOF
name: fixture-verify
on:
  workflow_dispatch:
permissions: {}
x-env-alpha: &env-alpha
  env:
    STEP_ALPHA: \${{ steps.step-alpha.outcome }}
x-env-both: &env-both
  env:
    STEP_ALPHA: \${{ steps.step-alpha.outcome }}
    STEP_BRAVO: \${{ steps.step-bravo.outcome }}
x-run-three: &run-three
  run: |
    if [[ \${STEP_ALPHA} == 'failure' ]]; then reason='alpha-failed'; fi
    if [[ \${STEP_BRAVO} == 'failure' ]]; then reason='bravo-failed'; fi
    if [[ \${STEP_BRAVO} == 'cancelled' ]]; then reason='charlie-failed'; fi
x-run-four: &run-four
  run: |
    if [[ \${STEP_ALPHA} == 'failure' ]]; then reason='alpha-failed'; fi
    if [[ \${STEP_BRAVO} == 'failure' ]]; then reason='bravo-failed'; fi
    if [[ \${STEP_BRAVO} == 'cancelled' ]]; then reason='charlie-failed'; fi
    if [[ \${STEP_ALPHA} == 'cancelled' ]]; then reason='unknown'; fi
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: step-bravo
        run: echo PAYLOAD_RAN
      - id: attribute
        <<: ${order}
EOF
    # shellcheck disable=SC2016 # the text is workflow YAML, not shell to expand
    if [[ ${carried} == env ]]; then
      printf '        run: |\n          if [[ ${STEP_ALPHA} == '"'failure'"' ]]; then reason='"'alpha-failed'"'; fi\n'
      printf '          if [[ ${STEP_BRAVO} == '"'failure'"' ]]; then reason='"'bravo-failed'"'; fi\n'
    else
      printf '        env:\n          STEP_ALPHA: ${{ steps.step-alpha.outcome }}\n          STEP_BRAVO: ${{ steps.step-bravo.outcome }}\n'
    fi
  } >"${dir}/workflow.yml"
  local got_exit=0
  VERIFY_WORKFLOW_OVERRIDE="${dir}/workflow.yml" \
    VERIFICATION_DOC_OVERRIDE="${FIXTURES}/good/verification.md" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"

  if [[ ${got_exit} -ne ${want_exit} ]] ||
    { [[ -n ${want_msg} ]] && ! grep --fixed-strings --quiet -- "${want_msg}" "${stdout_file}" "${stderr_file}"; }; then
    printf 'FAIL: %s — expected exit %d and output containing %q; got exit %d and output %q\n' \
      "${name}" "${want_exit}" "${want_msg}" "${got_exit}" "$(cat -- "${stdout_file}" "${stderr_file}")" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${got_exit}"
  fi

  harness_assert_record "${name}" "${want_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --recursive --force -- "${dir}" "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

# @description Run the script on a workflow written with YAML aliases and,
# when one is given, on its twin written inline, and compare each run's
# exit code, stdout and the whole of stderr: an aliased value is read as
# its anchored text, so both reach one verdict and one diagnostic, the file
# path aside. Both runs are recorded as one scenario, as a twin that
# passes prints the same summary line.
# @arg $1 scenario name  @arg $2 expected exit  @arg $3 the whole expected
# stdout  @arg $4 the whole expected stderr, with FILE for the workflow path
# @arg $5 the aliased workflow  @arg $6 the inline twin ('' for none)
function expect_twin() {
  local -r name="$1" want_exit="$2" want_out="$3" want_err="$4"
  local dir variant got_exit captures=()
  dir="$(mktemp --directory)"
  printf '%s\n' "$5" >"${dir}/aliased.yml"
  local variants=(aliased)
  if [[ -n $6 ]]; then
    printf '%s\n' "$6" >"${dir}/inline.yml"
    variants+=(inline)
  fi
  for variant in "${variants[@]}"; do
    got_exit=0
    VERIFY_WORKFLOW_OVERRIDE="${dir}/${variant}.yml" \
      VERIFICATION_DOC_OVERRIDE="${FIXTURES}/good/verification.md" \
      "${SCRIPT}" >"${dir}/${variant}.out" 2>"${dir}/${variant}.err" || got_exit=$?
    printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${dir}/${variant}.exit"
    local want="${want_err//FILE/${dir}/${variant}.yml}"
    if [[ ${got_exit} -ne ${want_exit} ||
      "$(cat -- "${dir}/${variant}.out")" != "${want_out}" ||
      "$(cat -- "${dir}/${variant}.err")" != "${want}" ]]; then
      printf 'FAIL: %s (%s) — expected exit %d, stdout %q and stderr %q; got exit %d, stdout %q and stderr %q\n' \
        "${name}" "${variant}" "${want_exit}" "${want_out}" "${want}" "${got_exit}" \
        "$(cat -- "${dir}/${variant}.out")" "$(cat -- "${dir}/${variant}.err")" >&2
      failures=$((failures + 1))
    else
      printf 'PASS: %s (%s, exit %d)\n' "${name}" "${variant}" "${got_exit}"
    fi
    captures+=("${dir}/${variant}.exit" "${dir}/${variant}.out" "${dir}/${variant}.err")
  done

  # The recorded substring is the first line of whichever stream carries
  # the verdict, without the path, as one may not hold a line break.
  local record="${want_err%%$'\n'*}"
  record="${record#FILE: }"
  harness_assert_record "${name}" "${record:-${want_out}}" "${captures[@]}"
  rm --recursive --force -- "${dir}"
}

# @description Print a YAML mapping entry anchoring a list nested
# through aliases, each level an alias of the one below; `*<prefix><n-1>`
# names its outermost level, and resolving it takes one `explode` pass a
# level.
# @arg $1 anchor prefix  @arg $2 number of levels
function alias_nest() {
  local -r prefix="$1" depth="$2"
  local level
  printf 'x-%s:\n  l0: &%s0 [x]\n' "${prefix}" "${prefix}"
  for ((level = 1; level < depth; level++)); do
    printf '  l%d: &%s%d [*%s%d]\n' "${level}" "${prefix}" "${level}" "${prefix}" "$((level - 1))"
  done
}

# @description Print the list `alias_nest` anchors, written inline.
# @arg $1 number of levels
function inline_nest() {
  local level
  for ((level = 0; level < $1; level++)); do printf '['; done
  printf 'x'
  for ((level = 0; level < $1; level++)); do printf ']'; done
}

# @description The scenarios whose workflow reads a YAML alias where the
# verify job, a step, a step id, the attribution env or its values sit.
# Each passing twin prints its own counts, so no two passing scenarios
# share a summary line.
function alias_scenarios() {
  local -r head='name: fixture-verify
on:
  workflow_dispatch:
permissions: {}'
  # shellcheck disable=SC2016 # the text is workflow YAML, not shell to expand
  local -r alpha_env='STEP_ALPHA: ${{ steps.step-alpha.outcome }}'
  # shellcheck disable=SC2016 # the text is workflow YAML, not shell to expand
  local -r bravo_env='STEP_BRAVO: ${{ steps.step-bravo.outcome }}'
  # shellcheck disable=SC2016 # the text is workflow YAML, not shell to expand
  local -r alpha_ladder='if [[ ${STEP_ALPHA} == '"'failure'"' ]]; then reason='"'alpha-failed'"'; fi'
  local -r extra_msg='FILE: step id extra-step has no steps.<id>.outcome entry in the attribution env'
  local -r extra_inline="${head}
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: extra-step
        run: echo PAYLOAD_RAN
      - id: attribute
        env:
          ${alpha_env}
        run: |
          ${alpha_ladder}"

  expect_twin 'a step written as an alias is read as its anchored step' 1 '' \
    "${extra_msg}" "${head}
x-anchors:
  extra: &extra
    id: extra-step
    run: echo PAYLOAD_RAN
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - *extra
      - id: attribute
        env:
          ${alpha_env}
        run: |
          ${alpha_ladder}" "${extra_inline}"

  expect_twin 'a step written as a merge key is read as its merged step' 1 '' \
    "${extra_msg}" "${head}
x-anchors:
  extra: &extra
    id: extra-step
    run: echo PAYLOAD_RAN
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - <<: *extra
      - id: attribute
        env:
          ${alpha_env}
        run: |
          ${alpha_ladder}" "${extra_inline}"

  expect_twin 'a step id written as an alias is read as its anchored id' 0 \
    'check-verify-reason-ladder: ok (2 id-carrying steps, 1 env entries, 2 reason tokens)' '' \
    "${head}
x-anchors:
  vpid: &vpid step-alpha
jobs:
  verify:
    steps:
      - id: *vpid
        run: echo PAYLOAD_RAN
      - id: attribute
        env:
          ${alpha_env}
        run: |
          ${alpha_ladder}
          reason='unknown'" "${head}
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: attribute
        env:
          ${alpha_env}
        run: |
          ${alpha_ladder}
          reason='unknown'"

  # shellcheck disable=SC2016 # the text is workflow YAML, not shell to expand
  expect_twin 'an attribution env value written as an alias is read as its anchored text' 0 \
    'check-verify-reason-ladder: ok (2 id-carrying steps, 1 env entries, 3 reason tokens)' '' \
    "${head}
x-anchors:
  vp: &vp \${{ steps.step-alpha.outcome }}
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: attribute
        env:
          STEP_ALPHA: *vp
        run: |
          ${alpha_ladder}
          reason='bravo-failed'
          reason='unknown'" "${head}
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: attribute
        env:
          ${alpha_env}
        run: |
          ${alpha_ladder}
          reason='bravo-failed'
          reason='unknown'"

  # shellcheck disable=SC2016 # the text is workflow YAML, not shell to expand
  local -r both_ladder='if [[ ${STEP_ALPHA} == x || ${STEP_BRAVO} == x ]]; then reason='"'alpha-failed'"'; fi'
  expect_twin 'an attribution env written as a merge key is read as its merged entries' 0 \
    'check-verify-reason-ladder: ok (3 id-carrying steps, 2 env entries, 1 reason tokens)' '' \
    "${head}
x-anchors:
  envbase: &envbase
    ${alpha_env}
    ${bravo_env}
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: step-bravo
        run: echo PAYLOAD_RAN
      - id: attribute
        env:
          <<: *envbase
        run: |
          ${both_ladder}" "${head}
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: step-bravo
        run: echo PAYLOAD_RAN
      - id: attribute
        env:
          ${alpha_env}
          ${bravo_env}
        run: |
          ${both_ladder}"

  # shellcheck disable=SC2016 # the text is workflow YAML, not shell to expand
  local -r all_ladder='if [[ ${STEP_ALPHA} == x || ${STEP_BRAVO} == x || ${STEP_CHARLIE} == x ]]; then reason='"'unknown'"'; fi'
  # shellcheck disable=SC2016 # the text is workflow YAML, not shell to expand
  local -r charlie_env='STEP_CHARLIE: ${{ steps.step-charlie.outcome }}'
  expect_twin 'the attribution step id written as an alias is read as its anchored id' 0 \
    'check-verify-reason-ladder: ok (4 id-carrying steps, 3 env entries, 1 reason tokens)' '' \
    "${head}
x-anchors:
  attrid: &attrid attribute
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: step-bravo
        run: echo PAYLOAD_RAN
      - id: step-charlie
        run: echo PAYLOAD_RAN
      - id: *attrid
        env:
          ${alpha_env}
          ${bravo_env}
          ${charlie_env}
        run: |
          ${all_ladder}" "${head}
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: step-bravo
        run: echo PAYLOAD_RAN
      - id: step-charlie
        run: echo PAYLOAD_RAN
      - id: attribute
        env:
          ${alpha_env}
          ${bravo_env}
          ${charlie_env}
        run: |
          ${all_ladder}"

  # The attribution step, its env and an env value are each an alias, so
  # the value sits three aliases deep.
  expect_twin 'an attribution env value three aliases deep is read as its anchored text' 1 '' \
    'FILE: step id step-bravo has no steps.<id>.outcome entry in the attribution env' \
    "${head}
x-anchors:
  vp: &vp \${{ steps.step-alpha.outcome }}
  envmap: &envmap
    STEP_ALPHA: *vp
  attrstep: &attrstep
    id: attribute
    env: *envmap
    run: |
      ${alpha_ladder}
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: step-bravo
        run: echo PAYLOAD_RAN
      - *attrstep" "${head}
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: step-bravo
        run: echo PAYLOAD_RAN
      - id: attribute
        env:
          ${alpha_env}
        run: |
          ${alpha_ladder}"

  # A step id holding a list is no id GitHub Actions accepts, but it is
  # the one judged value that can nest an alias at any depth: an aliased
  # step whose id is a list nested five aliases deep reads as its inline
  # twin.
  local -r nested_id_inline="${head}
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: $(inline_nest 5)
        run: echo PAYLOAD_RAN
      - id: attribute
        env:
          ${alpha_env}
        run: |
          ${alpha_ladder}"
  expect_twin 'a step id nested five aliases deep is read as its anchored text' 1 '' \
    'FILE: step id \[\[\[\[\[x\]\]\]\]\] has no steps.<id>.outcome entry in the attribution env' \
    "${head}
$(alias_nest nest 5)
  st: &st
    id: *nest4
    run: echo PAYLOAD_RAN
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - *st
      - id: attribute
        env:
          ${alpha_env}
        run: |
          ${alpha_ladder}" "${nested_id_inline}"

  # Past sixteen levels an alias survives every resolving pass, and the
  # lint has no text to judge for that value.
  expect_twin 'a step id nested deeper than sixteen aliases is refused' 2 '' \
    'FILE: jobs.verify.steps[].id still holds a YAML alias after resolving; cannot read it' \
    "${head}
$(alias_nest nest 20)
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: *nest19
        run: echo PAYLOAD_RAN
      - id: attribute
        env:
          ${alpha_env}
        run: |
          ${alpha_ladder}" ''
  expect_twin 'an attribution run: nested deeper than sixteen aliases is refused' 2 '' \
    'FILE: jobs.verify.steps[].run still holds a YAML alias after resolving; cannot read it' \
    "${head}
$(alias_nest nest 20)
jobs:
  verify:
    steps:
      - id: step-alpha
        run: echo PAYLOAD_RAN
      - id: attribute
        env:
          ${alpha_env}
        run: *nest19" ''

  # The lint reads no step's with:, so an alias nested there past every
  # resolving pass leaves the verdict to the values it does read.
  expect_twin 'an alias nested deeper than sixteen where the lint reads nothing is not refused' 0 \
    'check-verify-reason-ladder: ok (2 id-carrying steps, 1 env entries, 4 reason tokens)' '' \
    "${head}
$(alias_nest nest 20)
jobs:
  verify:
    steps:
      - id: step-alpha
        uses: ./fixture-action
        with:
          nested: *nest19
      - id: attribute
        env:
          ${alpha_env}
        run: |
          ${alpha_ladder}
          reason='bravo-failed'
          reason='charlie-failed'
          reason='unknown'" "${head}
jobs:
  verify:
    steps:
      - id: step-alpha
        uses: ./fixture-action
        with:
          nested: $(inline_nest 20)
      - id: attribute
        env:
          ${alpha_env}
        run: |
          ${alpha_ladder}
          reason='bravo-failed'
          reason='charlie-failed'
          reason='unknown'"
}

function main() {
  expect 'good' 'workflow.yml' 0 ''

  expect 'bad-env-key-regex' 'workflow.yml' 1 \
    'attribution env key A\{1 is not a shell identifier; attribution env names must match ^[A-Za-z_][A-Za-z0-9_]*$'

  expect 'bad-missing-env' 'workflow.yml' 1 \
    'step id step-delta has no steps.<id>.outcome entry in the attribution env'

  expect 'bad-unread-env' 'workflow.yml' 1 \
    'is never read by the reason ladder'

  expect 'bad-undocumented-reason' 'workflow.yml' 1 \
    'is not documented in'

  expect 'bad-ladder-order' 'workflow.yml' 1 \
    'ladder tests STEP_CHARLIE before STEP_BRAVO, but the steps run in the opposite order'

  # An attribution run: body written as an alias is read as its anchored
  # text, which is what the runner executes: its ladder is walked like an
  # inline one, so an order drift there is named.
  expect 'alias-ladder-order' 'workflow.yml' 1 \
    'ladder tests STEP_BRAVO before STEP_ALPHA, but the steps run in the opposite order'

  expect 'exempt-step' 'workflow.yml' 0 ''

  expect_unearned_exempt

  expect 'malformed' 'bad-malformed.yml' 2 \
    'bad-malformed.yml: could not evaluate'

  require_locale_gap en_US.UTF-8 || exit 1
  expect_en_us 'non-ASCII letter in an env key is not a shell identifier under en_US.UTF-8' \
    's/^\( *\)STEP_CHARLIE:/\1STEP_CHARLIé:/' 1 \
    'DIR/workflow.yml: attribution env key STEP_CHARLIé is not a shell identifier; attribution env names must match ^[A-Za-z_][A-Za-z0-9_]*$'
  expect_en_us 'non-ASCII letter before an env key is not a shell identifier under en_US.UTF-8' \
    's/^\( *\)STEP_CHARLIE:/\1éSTEP_CHARLIE:/' 1 \
    'DIR/workflow.yml: attribution env key éSTEP_CHARLIE is not a shell identifier; attribution env names must match ^[A-Za-z_][A-Za-z0-9_]*$'
  expect_en_us 'non-ASCII letter in a step id is not read as an outcome reference under en_US.UTF-8' \
    's/step-charlie/step-charlié/g' 1 \
    'DIR/workflow.yml: step id step-charlié has no steps.<id>.outcome entry in the attribution env'
  # The ladder read is a grep whose name boundary is a range, so a
  # non-ASCII letter next to the name is a boundary in every locale. The
  # ladder also defaults to `unknown`, so the passing summary counts four
  # reason tokens and tells this run apart from the good one.
  require_grep_locale_gap en_US.UTF-8 || exit 1
  expect_en_us 'non-ASCII letter after an env name in the ladder is a name boundary under en_US.UTF-8' \
    "s/\\\${STEP_CHARLIE}/\${STEP_CHARLIEé}/; s/reason='ok'/reason='unknown'/" 0 ''
  harness_assert_also '3 env entries, 4 reason tokens)'
  # A root key written as an alias of `jobs` is `jobs:`, as GitHub Actions
  # reads it, for every read of the verify job; one given twice, plain and
  # as an alias, is a workflow the check cannot read.
  expect_rewritten 'a jobs: key written as an alias is read' \
    's/^name: fixture-verify$/name: \&k jobs/; s/^jobs:$/*k :/; /^ *STEP_CHARLIE:/d' 1 \
    'DIR/workflow.yml: step id step-charlie has no steps.<id>.outcome entry in the attribution env'
  expect_rewritten 'a jobs: key given twice is unreadable' \
    's/^name: fixture-verify$/name: \&k jobs\njobs: {}/; s/^jobs:$/*k :/' 2 \
    $'Error: jobs: is given more than once\nDIR/workflow.yml: could not evaluate workflow with yq (malformed?)'
  expect_merge_order 'a merge list in the verify job is read first mapping wins: the step the env misses first is refused' \
    '[*with-bravo, *without-bravo]' 1 \
    'step id step-bravo has no steps.<id>.outcome entry in the attribution env'
  expect_merge_order 'a merge list in the verify job is read first mapping wins: the covered steps first pass' \
    '[*without-bravo, *with-bravo]' 0 ''
  expect_step_merge 'a merge list in the attribution step reads its env first mapping wins: the env missing a step first is refused' \
    env '[*env-alpha, *env-both]' 1 \
    'step id step-bravo has no steps.<id>.outcome entry in the attribution env'
  expect_step_merge 'a merge list in the attribution step reads its env first mapping wins: the env covering every step first passes' \
    env '[*env-both, *env-alpha]' 0 ''
  expect_step_merge 'a merge list in the attribution step reads its run body first mapping wins: the three-token body first reads as three tokens' \
    run '[*run-three, *run-four]' 0 \
    '2 env entries, 3 reason tokens)'
  expect_step_merge 'a merge list in the attribution step reads its run body first mapping wins: the four-token body first reads as four tokens' \
    run '[*run-four, *run-three]' 0 \
    '2 env entries, 4 reason tokens)'
  alias_scenarios
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
