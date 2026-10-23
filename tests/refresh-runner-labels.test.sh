#!/usr/bin/env bash
# tests/refresh-runner-labels.test.sh
#
# Rewrite + drift harness for scripts/refresh-runner-labels.sh. Every
# scenario runs the generator against copies of the live workflow and the
# two docs in its own directory, so the checkout's docs are only read.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# The harness formats generated docs with treefmt from the tree root, so
# it runs in a scratch copy of the tree and leaves this checkout untouched.
# shellcheck source=scripts/lib/scratch-tree.sh
source "${REPO_ROOT}/scripts/lib/scratch-tree.sh"
reexec_in_scratch_tree "$@"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-runner-labels.sh"
readonly LIVE_WORKFLOW="${REPO_ROOT}/.github/workflows/ci.yml"
readonly LIVE_CI_DOC="${REPO_ROOT}/docs/architecture/ci.md"
readonly LIVE_NIX_DOC="${REPO_ROOT}/docs/install/nix.md"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

work=''
function cleanup() {
  if [[ -n ${work} && -d ${work} ]]; then
    rm --recursive --force -- "${work}"
  fi
}
trap cleanup EXIT

# Exit status of the last `run_gen`.
gen_rc=0

# @description Create a scenario directory holding copies of the live
# workflow and the two docs.
# @arg $1 scenario name
# @stdout the scenario directory
function new_case() {
  local -r dir="${work}/$1"
  mkdir -- "${dir}"
  cp -- "${LIVE_WORKFLOW}" "${dir}/ci.yml"
  cp -- "${LIVE_CI_DOC}" "${dir}/ci.md"
  cp -- "${LIVE_NIX_DOC}" "${dir}/nix.md"
  printf '%s' "${dir}"
}

# @description Run the generator on a scenario directory's three files.
# Output lands in <dir>/<tag>.out, .err and .outcome; the status in
# `gen_rc`.
# @arg $1 scenario directory  @arg $2 tag  @arg $@ generator arguments
function run_gen() {
  local -r dir="$1" tag="$2"
  shift 2
  gen_rc=0
  CI_WORKFLOW_OVERRIDE="${dir}/ci.yml" \
    CI_DOC_OVERRIDE="${dir}/ci.md" \
    NIX_DOC_OVERRIDE="${dir}/nix.md" \
    "${SCRIPT}" "$@" >"${dir}/${tag}.out" 2>"${dir}/${tag}.err" || gen_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${gen_rc}" >"${dir}/${tag}.outcome"
}

# @description Print the rows of the table whose header row's first cell
# is the given text, one row per line, each cell trimmed and the cells
# joined by a tab.
# @arg $1 doc  @arg $2 first header cell
function table_rows() {
  awk -v first="$2" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function emit(line,   n, cells, i, out) {
      n = split(line, cells, "|")
      out = ""
      for (i = 2; i < n; i++) out = out (i > 2 ? "\t" : "") trim(cells[i])
      print out
    }
    in_table && /^\|/ { emit($0); next }
    in_table { exit }
    /^\|/ { n = split($0, c, "|"); if (trim(c[2]) == first) { in_table = 1; emit($0) } }
  ' "$1"
}

# @description Require an exit-2 refusal whose stderr holds the given
# text, in --check and in write mode, and that leaves both docs as the
# scenario left them.
# @arg $1 scenario name  @arg $2 scenario dir  @arg $3 expected stderr text
function expect_refusal() {
  local -r name="$1" dir="$2" text="$3"
  cp -- "${dir}/ci.md" "${dir}/ci.md.orig"
  cp -- "${dir}/nix.md" "${dir}/nix.md.orig"
  run_gen "${dir}" run --check
  harness_assert_record "${name}" "${text}" "${dir}/run.outcome" "${dir}/run.out" "${dir}/run.err"
  if [[ ${gen_rc} -eq 2 ]] && grep --fixed-strings --quiet -- "${text}" "${dir}/run.err"; then
    pass "${name}: exits 2 naming ${text}"
  else
    fail "${name}: exit ${gen_rc}, want 2 and stderr holding '${text}'"
    sed 's/^/    /' -- "${dir}/run.err" >&2
  fi
  # The write mode refuses the same input and writes neither doc.
  run_gen "${dir}" write
  if [[ ${gen_rc} -eq 2 ]] && cmp --silent -- "${dir}/ci.md" "${dir}/ci.md.orig" &&
    cmp --silent -- "${dir}/nix.md" "${dir}/nix.md.orig"; then
    pass "${name}: write mode exits 2 and leaves both docs alone"
  else
    fail "${name}: write mode exit ${gen_rc} or a doc changed"
  fi
}

# @description Set one job's runs-on in a scenario's workflow.
# @arg $1 scenario dir  @arg $2 job  @arg $3 yq value expression
function set_runs_on() {
  JOB="$2" yq --inplace ".jobs[strenv(JOB)].runs-on = $3" "$1/ci.yml"
}

function main() {
  work="$(mktemp --directory)"
  local dir
  # The scenarios edit copies of the live files, so every edit is written
  # against the labels the live workflow carries today rather than literal
  # ones: a runner bump must not turn this harness red.
  local arm_label x86_label
  arm_label="$(yq '.jobs.build-linpeas-arm64.runs-on' "${LIVE_WORKFLOW}")"
  x86_label="$(yq '.jobs.build-linpeas.runs-on' "${LIVE_WORKFLOW}")"
  local -r new_arm='ubuntu-98.04-arm' wide_arm='ubuntu-98.04-arm-large'
  if [[ ${arm_label} == "${new_arm}" || ${arm_label} == "${wide_arm}" ]]; then
    fail "the live arm label is ${arm_label}; pick other rewrite labels for this harness"
  fi

  # live-fresh: the committed docs match the committed workflow.
  dir="$(new_case live-fresh)"
  run_gen "${dir}" run --check
  harness_assert_record 'live-fresh' 'are up to date' "${dir}/run.outcome" "${dir}/run.out" "${dir}/run.err"
  if [[ ${gen_rc} -eq 0 ]] && grep --fixed-strings --quiet -- 'are up to date' "${dir}/run.err"; then
    pass 'live-fresh: --check on the live tree exits 0'
  else
    fail "live-fresh: exit ${gen_rc}, want 0"
    sed 's/^/    /' -- "${dir}/run.err" >&2
  fi

  # label-rewrite: a new arm label reaches both docs; --check first
  # reports the drift.
  dir="$(new_case label-rewrite)"
  sed --in-place "s/runs-on: ${arm_label//./\\.}\$/runs-on: ${new_arm}/" "${dir}/ci.yml"
  run_gen "${dir}" check --check
  harness_assert_record 'label-rewrite: --check' 'are stale' "${dir}/check.outcome" "${dir}/check.out" "${dir}/check.err"
  if [[ ${gen_rc} -eq 1 ]] && grep --fixed-strings --quiet -- 'are stale' "${dir}/check.err" &&
    cmp --silent -- "${dir}/ci.md" "${LIVE_CI_DOC}"; then
    pass 'label-rewrite: --check exits 1 and writes nothing'
  else
    fail "label-rewrite: --check exit ${gen_rc}, want 1 with the doc untouched"
    sed 's/^/    /' -- "${dir}/check.err" >&2
  fi
  run_gen "${dir}" write
  harness_assert_record 'label-rewrite: write' 'refreshed runner labels' "${dir}/write.outcome" "${dir}/write.out" "${dir}/write.err"
  # The expected cells are built around a backtick held in a variable:
  # shfmt rewrites a backslash-escaped backtick in double quotes into single
  # quotes, where shellcheck reads it as an unexpanded command substitution.
  local arm_ci_rows arm_nix_row x86_nix_row
  local -r tick=$'\x60'
  arm_ci_rows="$(table_rows "${dir}/ci.md" Job | awk -F'\t' -v want="${new_arm}" '$1 ~ /-arm64`$/ && $2 == "`" want "`"' | wc --lines)"
  arm_nix_row="$(table_rows "${dir}/nix.md" System | awk -F'\t' '$1 == "`aarch64-linux`" { print $3 }')"
  x86_nix_row="$(table_rows "${dir}/nix.md" System | awk -F'\t' '$1 == "`x86_64-linux`" { print $3 }')"
  if [[ ${gen_rc} -eq 0 && ${arm_ci_rows} -eq 3 && ${arm_nix_row} == "yes (${tick}${new_arm}${tick})" &&
    ${x86_nix_row} == "yes (${tick}${x86_label}${tick})" ]]; then
    pass 'label-rewrite: both docs carry the new arm label'
  else
    fail "label-rewrite: exit ${gen_rc}, ${arm_ci_rows} arm ci.md rows on the new label (want 3), nix.md arm cell '${arm_nix_row}', x86 cell '${x86_nix_row}'"
    sed 's/^/    /' -- "${dir}/write.err" >&2
  fi

  # descriptions-unchanged: only the runner cells moved.
  local col
  for col in 1 3; do
    if [[ "$(table_rows "${dir}/ci.md" Job | cut --fields="${col}")" == "$(table_rows "${LIVE_CI_DOC}" Job | cut --fields="${col}")" ]]; then
      pass "descriptions-unchanged: ci.md column ${col} keeps its text"
    else
      fail "descriptions-unchanged: ci.md column ${col} changed"
    fi
  done
  if [[ "$(table_rows "${dir}/nix.md" System | cut --fields=1-2)" == "$(table_rows "${LIVE_NIX_DOC}" System | cut --fields=1-2)" ]]; then
    pass 'descriptions-unchanged: nix.md columns 1-2 keep their text'
  else
    fail 'descriptions-unchanged: nix.md columns 1-2 changed'
  fi
  if [[ $(wc --lines <"${dir}/ci.md") -eq $(wc --lines <"${LIVE_CI_DOC}") &&
  $(wc --lines <"${dir}/nix.md") -eq $(wc --lines <"${LIVE_NIX_DOC}") ]]; then
    pass 'descriptions-unchanged: line counts are unchanged'
  else
    fail 'descriptions-unchanged: a line count changed'
  fi
  if diff <(grep --invert-match '^|' -- "${dir}/ci.md") <(grep --invert-match '^|' -- "${LIVE_CI_DOC}") >/dev/null &&
    diff <(grep --invert-match '^|' -- "${dir}/nix.md") <(grep --invert-match '^|' -- "${LIVE_NIX_DOC}") >/dev/null; then
    pass 'descriptions-unchanged: no line outside a table changed'
  else
    fail 'descriptions-unchanged: a line outside the tables changed'
  fi

  # idempotent: a second run on its own output changes nothing.
  cp -- "${dir}/ci.md" "${dir}/ci.md.first"
  cp -- "${dir}/nix.md" "${dir}/nix.md.first"
  run_gen "${dir}" second
  run_gen "${dir}" recheck --check
  harness_assert_record 'idempotent' 'are up to date' "${dir}/recheck.outcome" "${dir}/recheck.out" "${dir}/recheck.err"
  if [[ ${gen_rc} -eq 0 ]] && cmp --silent -- "${dir}/ci.md" "${dir}/ci.md.first" &&
    cmp --silent -- "${dir}/nix.md" "${dir}/nix.md.first"; then
    pass 'idempotent: second run is a no-op and --check exits 0'
  else
    fail "idempotent: second run changed a doc or --check exit ${gen_rc}"
  fi

  # wider-label-repad: a label wider than every Runner cell re-pads the
  # whole table, and treefmt leaves the result as it is.
  dir="$(new_case wider-label-repad)"
  sed --in-place "s/runs-on: ${arm_label//./\\.}\$/runs-on: ${wide_arm}/" "${dir}/ci.yml"
  run_gen "${dir}" write
  local doc rel formatted
  for doc in ci nix; do
    rel='docs/architecture/ci.md'
    [[ ${doc} == nix ]] && rel='docs/install/nix.md'
    formatted="${dir}/${doc}.formatted.md"
    (cd -- "${REPO_ROOT}" && treefmt --stdin "${rel}") <"${dir}/${doc}.md" >"${formatted}" 2>/dev/null || true
    if [[ ${gen_rc} -eq 0 ]] && grep --fixed-strings --quiet -- "${tick}${wide_arm}${tick}" "${dir}/${doc}.md" &&
      cmp --silent -- "${dir}/${doc}.md" "${formatted}"; then
      pass "wider-label-repad: treefmt is a no-op on the regenerated ${doc}.md"
    else
      fail "wider-label-repad: ${doc}.md (exit ${gen_rc}) differs from its treefmt output"
      diff -- "${dir}/${doc}.md" "${formatted}" | head --lines=20 >&2 || true
    fi
  done

  # unknown-job: a row naming a job the workflow lacks.
  dir="$(new_case unknown-job)"
  # shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
  sed --in-place 's/^| `smoke-test`  *|/| `no-such-job` |/' "${dir}/ci.md"
  expect_refusal 'unknown-job' "${dir}" 'no-such-job'

  # non-scalar-runs-on: a table job whose runs-on is a list.
  dir="$(new_case non-scalar-runs-on)"
  set_runs_on "${dir}" smoke-test-arm64 '["self-hosted", "arm"]'
  expect_refusal 'non-scalar-runs-on' "${dir}" 'job smoke-test-arm64 has a runs-on that is not one plain runner label'

  # An expression is a string, but not a label the docs can name.
  dir="$(new_case expression-runs-on)"
  # shellcheck disable=SC2016 # a GitHub Actions expression, kept literal
  set_runs_on "${dir}" build-linpeas '"${{ matrix.os }}"'
  expect_refusal 'expression-runs-on' "${dir}" 'job build-linpeas has a runs-on that is not one plain runner label'

  # disagreeing-arm-runners: the jobs feeding aarch64-linux disagree.
  dir="$(new_case disagreeing-arm-runners)"
  set_runs_on "${dir}" smoke-test-arm64 "\"${new_arm}\""
  expect_refusal 'disagreeing-arm-runners' "${dir}" 'the jobs feeding aarch64-linux'

  # header-missing / header-twice on ci.md.
  dir="$(new_case header-missing)"
  sed --in-place 's/^\(| Job  *| Runner\) /\1s/' "${dir}/ci.md"
  expect_refusal 'header-missing' "${dir}" 'no table with the header row | Job | Runner | What it tests |'

  dir="$(new_case header-twice)"
  grep --after-context=2 -- '^| Job  *| Runner  *|' "${LIVE_CI_DOC}" >"${dir}/block.md"
  printf '\n' >>"${dir}/ci.md"
  cat -- "${dir}/block.md" >>"${dir}/ci.md"
  expect_refusal 'header-twice' "${dir}" 'appears 2 times'

  # nix.md: the header missing, and a row for a system no job feeds.
  dir="$(new_case nix-header-missing)"
  sed --in-place 's/^| System  *| Flake builds  *| CI tested  *|$/| System | Flake builds | Tested |/' "${dir}/nix.md"
  expect_refusal 'nix-header-missing' "${dir}" 'no table with the header row | System | Flake builds | CI tested |'

  dir="$(new_case nix-unknown-system)"
  # shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
  sed --in-place 's/^| `aarch64-linux` |.*$/&\n| `riscv64-linux` | yes | no |/' "${dir}/nix.md"
  expect_refusal 'nix-unknown-system' "${dir}" 'riscv64-linux'

  dir="$(new_case nix-missing-system)"
  # shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
  sed --in-place '/^| `x86_64-linux`  *|/d' "${dir}/nix.md"
  expect_refusal 'nix-missing-system' "${dir}" 'has no row for x86_64-linux'

  # malformed-row: a body row with a cell more than its header.
  dir="$(new_case malformed-row)"
  # shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
  sed --in-place 's/^\(| `smoke-test`  *|[^|]*|\)/\1 extra |/' "${dir}/ci.md"
  expect_refusal 'malformed-row' "${dir}" 'row has 4 cells; the header has 3'

  # odd-job-key: an empty job key cannot be listed and stops the run.
  dir="$(new_case odd-job-key)"
  printf '  "":\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo PAYLOAD_RAN\n' >>"${dir}/ci.yml"
  expect_refusal 'odd-job-key' "${dir}" 'which GitHub Actions refuses'

  # aliased-job-key: a job key written as an alias reads as the name it
  # stands for, so the docs stay fresh.
  dir="$(new_case aliased-job-key)"
  sed --in-place --expression='s/^  smoke-test-arm64:$/  *arm-smoke:/' \
    --expression='s/^name: \(.*\)$/name: \1\nx-names:\n  - \&arm-smoke smoke-test-arm64/' "${dir}/ci.yml"
  run_gen "${dir}" run --check
  harness_assert_record 'aliased-job-key' 'are up to date' "${dir}/run.outcome" "${dir}/run.out" "${dir}/run.err"
  if [[ ${gen_rc} -eq 0 ]] && grep --fixed-strings --quiet -- 'are up to date' "${dir}/run.err" &&
    grep --quiet -- '^  \*arm-smoke:$' "${dir}/ci.yml"; then
    pass 'aliased-job-key: an alias job key reads as its name'
  else
    fail "aliased-job-key: exit ${gen_rc}, want 0"
    sed 's/^/    /' -- "${dir}/run.err" >&2
  fi

  # unparsable-workflow and absent inputs are could-not-run, not drift.
  dir="$(new_case unparsable-workflow)"
  printf 'jobs: [\n' >"${dir}/ci.yml"
  expect_refusal 'unparsable-workflow' "${dir}" 'could not read the runners from'

  dir="$(new_case missing-doc)"
  rm --force -- "${work}/missing-doc/nix.md"
  run_gen "${dir}" run --check
  harness_assert_record 'missing-doc' 'nix.md not found' "${dir}/run.outcome" "${dir}/run.out" "${dir}/run.err"
  if [[ ${gen_rc} -eq 2 ]] && grep --fixed-strings --quiet -- 'nix.md not found' "${dir}/run.err"; then
    pass 'missing-doc: exits 2'
  else
    fail "missing-doc: exit ${gen_rc}, want 2"
  fi

  dir="$(new_case unknown-arg)"
  run_gen "${dir}" run --bogus
  harness_assert_record 'unknown-arg' 'unknown arg: --bogus' "${dir}/run.outcome" "${dir}/run.out" "${dir}/run.err"
  if [[ ${gen_rc} -eq 2 ]] && grep --fixed-strings --quiet -- 'unknown arg: --bogus' "${dir}/run.err"; then
    pass 'unknown-arg: exits 2'
  else
    fail "unknown-arg: exit ${gen_rc}, want 2"
  fi

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
