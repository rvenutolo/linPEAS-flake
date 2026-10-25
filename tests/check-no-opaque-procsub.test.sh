#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-no-opaque-procsub.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/no-opaque-procsub"
# The clean workflow and composite-action trees every shell-script
# scenario pairs with, so those scenarios read no live YAML.
readonly GOOD_WORKFLOWS="${FIXTURES}/good-workflow/.github/workflows"
readonly GOOD_ACTIONS="${FIXTURES}/good-workflow/.github/actions"

failures=0
scratch="$(make_temp --directory)"
readonly scratch
# shellcheck disable=SC2064 # expanded now on purpose: the path is fixed once created
trap "rm --recursive --force -- '${scratch}'" EXIT

# @description Run the lint over one set of scan roots (or the real tree
# when all three are empty) and assert the exit code plus every expected
# substring of its combined output. The first substring is the
# scenario's recorded assertion for the discrimination gate; the rest are
# attached to it.
# @arg $1 scenario label  @arg $2 SCRIPTS_DIR_OVERRIDE value
# @arg $3 WORKFLOWS_DIR_OVERRIDE value  @arg $4 ACTIONS_DIR_OVERRIDE value
# @arg $5 wanted exit code  @arg $@ wanted output substrings
function expect() {
  local -r label="$1" scripts_dir="$2" workflows_dir="$3" actions_dir="$4" want_exit="$5"
  shift 5
  local out_file got_exit=0
  out_file="$(make_temp)"
  if [[ -n ${scripts_dir}${workflows_dir}${actions_dir} ]]; then
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" WORKFLOWS_DIR_OVERRIDE="${workflows_dir}" \
      ACTIONS_DIR_OVERRIDE="${actions_dir}" "${SCRIPT}" >"${out_file}" 2>&1 || got_exit=$?
  else
    (cd -- "${REPO_ROOT}" && "${SCRIPT}") >"${out_file}" 2>&1 || got_exit=$?
  fi
  local got
  got="$(<"${out_file}")"
  local ok=1 want_msg
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  output: %s\n' "${label}" "${got_exit}" "${want_exit}" "${got}" >&2
    ok=0
  else
    for want_msg in "$@"; do
      if [[ ${got} != *"${want_msg}"* ]]; then
        printf 'FAIL %s: output missing %q\n  got: %s\n' "${label}" "${want_msg}" "${got}" >&2
        ok=0
      fi
    done
  fi
  if ((ok == 1)); then
    printf 'OK   %s\n' "${label}"
  else
    failures=$((failures + 1))
  fi
  harness_assert_record "${label}" "${1:-}" "${out_file}"
  if (($# > 1)); then
    shift
    for want_msg in "$@"; do
      harness_assert_also "${want_msg}"
    done
  fi
  rm --force -- "${out_file}"
}

readonly HIT_DIAG='process substitution feeds a redirection (producer exit status lost to its subshell)'

# One banned shell scenario is enough: the ban is on the shape, so a
# fixture per producer kind would restate the same outcome. This one uses
# a producer that is neither a parser nor a function the file defines,
# which is the part of the rule a shape-specific ban would miss.
expect banned-procsub "${FIXTURES}/bad" "${GOOD_WORKFLOWS}" "${GOOD_ACTIONS}" 1 \
  "bad/uses-procsub.sh: ${HIT_DIAG}: 9:done < <(find"
# The capture idiom, alongside a comment that spells the banned form out:
# only live code is a hit. The paired YAML holds the same three shapes in
# run: bodies — a captured producer under a comment naming the banned
# form, a `diff` of two substitutions, and a clean composite step.
expect good "${FIXTURES}/good" "${GOOD_WORKFLOWS}" "${GOOD_ACTIONS}" 0 \
  'no-opaque-procsub: ok — scanned 2 shell script(s) and 3 run: block(s)'
# `diff` takes both substitutions as file arguments and its own status is
# what the caller acts on, so a pair fed to it is not a hit.
expect good-diff "${FIXTURES}/good-diff" "${GOOD_WORKFLOWS}" "${GOOD_ACTIONS}" 0 \
  'no-opaque-procsub: ok — scanned 1 shell script(s) and 3 run: block(s)'
# The banned shape sits in a sourced library beside a clean top-level
# script: the scan has to descend to find it, and the clean sibling is
# what makes a root-only scan report success rather than nothing at all.
expect banned-procsub-under-lib "${FIXTURES}/bad-lib" "${GOOD_WORKFLOWS}" "${GOOD_ACTIONS}" 1 \
  "bad-lib/lib/reads.sh: ${HIT_DIAG}"
# A workflow run: body feeds a loop from a substitution in its second
# step, behind a clean first step: the hit names the job, the step and
# the line within the body.
expect workflow-run-body "${FIXTURES}/good" "${FIXTURES}/bad-workflow/.github/workflows" "${GOOD_ACTIONS}" 1 \
  "bad-workflow/.github/workflows/w.yml: job audit step[1] run: line 4: ${HIT_DIAG}: done < <(grep"
# The same shape in a composite action's step, here feeding `mapfile`.
expect composite-run-body "${FIXTURES}/good" "${GOOD_WORKFLOWS}" "${FIXTURES}/bad-action/.github/actions" 1 \
  "bad-action/.github/actions/a/action.yml: composite step[0] run: line 2: ${HIT_DIAG}: mapfile -t names < <(find"

# Generated here rather than committed: YAML that does not parse fails
# the formatter.
mkdir --parents -- "${scratch}/malformed"
printf 'jobs: [unclosed\n' >"${scratch}/malformed/w.yml"
expect malformed-yaml "${FIXTURES}/good" "${scratch}/malformed" "${GOOD_ACTIONS}" 2 \
  'malformed/w.yml: could not evaluate workflow or action with yq (malformed?)'

# The tracked tree itself: every script and run: body this lint guards is
# clean. The counts drift with the tree, so only the exit code is
# asserted.
expect live-tree "" "" "" 0

harness_assert_verify || failures=$((failures + 1))
if ((failures > 0)); then
  printf '%d scenario(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'all tests passed\n'
