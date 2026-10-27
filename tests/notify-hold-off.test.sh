#!/usr/bin/env bash
# tests/notify-hold-off.test.sh
# @subject .github/actions/notify-workflow-result/action.yml
#
# Runs the composite's `classify the run for a transient hold-off` step
# body, extracted with yq, against stub fetch and classify scripts that
# always answer `retry`, and asserts the verdict it writes for each
# `result` and `hold-off` input. With `hold-off` exactly `true` a failed
# or cancelled result is classified and can be held off; any other value
# reports without fetching the run, so a caller whose run can conclude
# `success` with a failed job still gets its issue. A `success` result
# classifies nothing whatever `hold-off` says. The input's default and
# the one caller that opts out are asserted too, since a flipped default
# or a dropped `hold-off: 'false'` would pass every step scenario.
#
# Exits 0 when every scenario behaves, 1 otherwise, and 2 when `yq` is
# missing or the step cannot be read.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly COMPOSITE="${REPO_ROOT}/.github/actions/notify-workflow-result/action.yml"
readonly CALLER="${REPO_ROOT}/.github/workflows/reproducibility-check.yml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

if ! step_body="$(yq eval '.runs.steps[] | select(.id == "classify") | .run' "${COMPOSITE}")" ||
  [[ -z ${step_body} || ${step_body} == 'null' ]]; then
  printf '%s: cannot read the classify step body\n' "${COMPOSITE}" >&2
  exit 2
fi

failures=0
WORK="$(mktemp --directory)"
readonly WORK
trap 'rm --recursive --force -- "${WORK}"' EXIT
mkdir --parents -- "${WORK}/workspace/scripts"
printf '%s\n' "${step_body}" >"${WORK}/step.sh"
# The stubs stand in for the checkout's scripts: the fetch leaves a
# marker so a scenario can tell whether the run was fetched at all, and
# the classifier answers `retry`, the one verdict that holds off.
cat >"${WORK}/workspace/scripts/fetch-ci-run.sh" <<EOF
#!/usr/bin/env bash
touch '${WORK}/fetched'
printf '{}\n'
EOF
cat >"${WORK}/workspace/scripts/classify-ci-run.sh" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --print-max-attempts ]]; then
  printf '3\n'
  exit 0
fi
printf 'retry\nbuild\ttransient\tsetup-step:checkout\n'
EOF
chmod +x "${WORK}/workspace/scripts/fetch-ci-run.sh" "${WORK}/workspace/scripts/classify-ci-run.sh"

# @description Run the step body with one `result` and `hold-off`, then
# assert the verdict it wrote and whether it fetched the run.
# @arg $1 scenario name  @arg $2 result  @arg $3 hold-off
# @arg $4 expected verdict  @arg $5 expected `fetched` (yes or no)
function expect_step() {
  local -r name="$1" result="$2" hold_off="$3" want_verdict="$4" want_fetched="$5"
  local out="${WORK}/${name}.out" err="${WORK}/${name}.err"
  local outcome="${WORK}/${name}.outcome" github_output="${WORK}/${name}.github-output"
  rm --force -- "${WORK}/fetched"
  : >"${github_output}"
  local status=0
  RESULT="${result}" HOLD_OFF="${hold_off}" GITHUB_OUTPUT="${github_output}" \
    GITHUB_WORKSPACE="${WORK}/workspace" GITHUB_RUN_ID=1 \
    bash "${WORK}/step.sh" >"${out}" 2>"${err}" || status=$?
  local verdict='' fetched=no
  verdict="$(sed --quiet 's/^verdict=//p' -- "${github_output}")"
  if [[ -e "${WORK}/fetched" ]]; then fetched=yes; fi
  printf 'harness-assert-outcome: exit=%d result=%s hold-off=%s verdict=%s fetched=%s\n' \
    "${status}" "${result}" "${hold_off}" "${verdict}" "${fetched}" >"${outcome}"
  if ((status != 0)) || [[ ${verdict} != "${want_verdict}" || ${fetched} != "${want_fetched}" ]]; then
    printf 'FAIL: %s — expected verdict %q, fetched %s; got exit %d, verdict %q, fetched %s\n' \
      "${name}" "${want_verdict}" "${want_fetched}" "${status}" "${verdict}" "${fetched}" >&2
    cat -- "${err}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "${name}"
  fi
  harness_assert_record "${name}" "verdict=${want_verdict} fetched=${want_fetched}" \
    "${outcome}" "${out}" "${err}"
}

# @description Assert one value read from a workflow or action file.
# @arg $1 scenario name  @arg $2 file  @arg $3 yq expression
# @arg $4 expected value
function expect_value() {
  local -r name="$1" file="$2" expr="$3" want="$4"
  local outcome="${WORK}/${name}.outcome" got
  if ! got="$(yq eval "${expr}" "${file}")"; then
    printf 'FAIL: %s — yq could not read %s\n' "${name}" "${file}" >&2
    failures=$((failures + 1))
    got='<unreadable>'
  elif [[ ${got} != "${want}" ]]; then
    printf 'FAIL: %s — expected %q, got %q\n' "${name}" "${want}" "${got}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "${name}"
  fi
  printf 'harness-assert-outcome: %s=%s\n' "${name}" "${got}" >"${outcome}"
  harness_assert_record "${name}" "${name}=${want}" "${outcome}"
}

expect_step 'failure-held-off-by-default' failure true retry yes
expect_step 'cancelled-held-off-by-default' cancelled true retry yes
expect_step 'failure-opted-out-reports' failure false report no
expect_step 'cancelled-opted-out-reports' cancelled false report no
expect_step 'empty-hold-off-reports' failure '' report no
expect_step 'upper-case-true-reports' failure TRUE report no
expect_step 'success-opted-out-classifies-nothing' success false '' no
expect_step 'success-classifies-nothing' success true '' no

expect_value 'hold-off-default' "${COMPOSITE}" '.inputs.hold-off.default' 'true'
expect_value 'reproducibility-opts-out' "${CALLER}" \
  '[.jobs.notify.steps[] | select(.uses == "./.github/actions/notify-workflow-result") | .with.hold-off][0]' 'false'

harness_assert_verify || failures=$((failures + 1))

if ((failures > 0)); then
  printf '\n%d scenario(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nnotify-hold-off: all passed\n'
