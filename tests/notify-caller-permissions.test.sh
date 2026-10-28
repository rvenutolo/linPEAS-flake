#!/usr/bin/env bash
# tests/notify-caller-permissions.test.sh
# @subject .github/actions/notify-workflow-result/action.yml
#
# Asserts that every job calling the notify-workflow-result composite
# by its local path (`./.github/actions/notify-workflow-result`) grants
# `actions` and `checks` at read or write. A slug reference, which
# `uses-no-self-reference` refuses, is not read as a call. The composite
# fetches its own run's jobs and their check-run annotations to decide
# whether to hold an issue off; without either scope the fetch fails,
# the composite files on every transient failure the CI watchdog is
# about to retry, and nothing else notices. A job's own `permissions:` wins over
# the workflow's, as GitHub reads them; `read-all` and `write-all` grant
# both.
#
# The live tree is checked first, then must-fail scenarios, each on a
# copy of the workflows, or on a workflow written for the scenario, in a
# temporary directory: pages.yml's caller without `checks` and without
# `actions`, a caller granting `checks: none`, a caller inheriting a
# workflow-level block without them, and a caller granting
# `actions: none`. Controls with the same shapes that do grant them must
# pass, so a check that stopped reading `uses:` or `permissions:` could
# not stay green. A directory whose only reference to the composite is
# by slug has no caller, as one with no reference at all has none.
#
# Exits 0 when every scenario behaves, 1 otherwise, and 2 when `yq` is
# missing.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly LIVE_DIR="${REPO_ROOT}/.github/workflows"
# shellcheck source=scripts/lib/enumerate.sh
source "${REPO_ROOT}/scripts/lib/enumerate.sh"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"

if ! command -v yq >/dev/null 2>&1; then
  printf 'notify-caller-permissions: yq not found on PATH\n' >&2
  exit 2
fi

# A `uses:` that reaches the composite: the local path. The same
# expression ci-watchdog.yml's workflowCallsNotify uses. Exported for
# yq's strenv().
declare -rx NOTIFY_USES_RE='^[.]/[.]github/actions/notify-workflow-result$'

# Prints `<job>\t<source>\t<actions>\t<checks>` for every job that
# calls the composite, from the job's own permissions (`job`) or else the
# workflow's (`workflow`).
# shellcheck disable=SC2016 # yq program literal; $-prefixed names are yq variables, not shell
readonly CALLERS_PROGRAM='
  (.permissions // "unset") as $wp
  | .jobs // {} | to_entries[]
  | select([.value.steps[]? | select((.uses // "") | test(strenv(NOTIFY_USES_RE)))] | length > 0)
  | (if .value.permissions == null then "workflow" else "job" end) as $src
  | (.value.permissions // $wp) as $p
  | .key + "\t" + $src + "\t" + (
      ($p | tag) as $t
      | if $t == "!!map" then ($p.actions // "unset") + "\t" + ($p.checks // "unset")
        elif $t == "!!str" then $p + "\t" + $p
        else "unset\tunset" end)'

# @description Whether one permission value grants read.
# @arg $1 the value (`read`, `write`, `read-all`, `write-all`, `none`, `unset`)
function grants_read() {
  case "$1" in
  read | write | read-all | write-all) return 0 ;;
  *) return 1 ;;
  esac
}

# @description Check every composite caller in one workflows directory.
# Prints one line per caller, `ok` or one FAIL per missing scope, then a
# summary.
# @arg $1 workflows directory
# @exitcode 0 every caller grants both scopes
# @exitcode 1 a caller lacks one
# @exitcode 2 no workflow, no caller at all, or yq cannot read a file
function check_callers() {
  local -r dir="$1"
  local failed=0 callers=0 f out job src actions checks job_failed
  local -a workflows=()
  glob_into workflows 'workflows' "${dir}/*.yml" "${dir}/*.yaml"
  if ((${#workflows[@]} == 0)); then
    printf 'notify-caller-permissions: no workflow under %s\n' "${dir}"
    return 2
  fi
  for f in "${workflows[@]}"; do
    if ! out="$(yq "${CALLERS_PROGRAM}" "${f}")"; then
      printf 'notify-caller-permissions: yq could not read %s\n' "${f}"
      return 2
    fi
    [[ -n ${out} ]] || continue
    while IFS=$'\t' read -r job src actions checks; do
      callers=$((callers + 1))
      job_failed=0
      if ! grants_read "${actions}"; then
        printf 'FAIL %s job %s calls notify-workflow-result without actions: read (has %s)\n' \
          "${f##*/}" "${job}" "${actions}"
        job_failed=1
      fi
      if ! grants_read "${checks}"; then
        printf 'FAIL %s job %s calls notify-workflow-result without checks: read (has %s)\n' \
          "${f##*/}" "${job}" "${checks}"
        job_failed=1
      fi
      if ((job_failed == 0)); then
        printf 'ok   %s job %s: actions %s, checks %s, from %s permissions\n' \
          "${f##*/}" "${job}" "${actions}" "${checks}" "${src}"
      else
        failed=1
      fi
    done <<<"${out}"
  done
  # A directory with no caller at all means the matcher stopped matching,
  # not that every caller is fine.
  if ((callers == 0)); then
    printf 'notify-caller-permissions: no job under %s calls notify-workflow-result\n' "${dir}"
    return 2
  fi
  if ((failed == 0)); then
    printf 'permissions ok: %d notify-workflow-result callers grant actions and checks read\n' "${callers}"
  fi
  return "${failed}"
}

TMP_DIR="$(mktemp --directory)"
readonly TMP_DIR
trap 'rm --recursive --force -- "${TMP_DIR}"' EXIT

failures=0

# @description Run check_callers on one directory and assert its exit
# code and one substring of its output.
# @arg $1 scenario name  @arg $2 directory  @arg $3 expected exit code
# @arg $4 expected substring
function scenario() {
  local -r name="$1" dir="$2" want_rc="$3" want="$4"
  local -r out="${TMP_DIR}/${name}.out"
  local rc=0
  (check_callers "${dir}") >"${out}" 2>&1 || rc=$?
  harness_assert_record "${name}" "${want}" "${out}"
  if [[ ${rc} -ne ${want_rc} ]]; then
    printf 'FAIL %s: exit %d, want %d\n' "${name}" "${rc}" "${want_rc}" >&2
    sed 's/^/  /' "${out}" >&2
    failures=1
    return
  fi
  if ! grep --quiet --fixed-strings -- "${want}" "${out}"; then
    printf 'FAIL %s: output does not contain %q\n' "${name}" "${want}" >&2
    sed 's/^/  /' "${out}" >&2
    failures=1
    return
  fi
  printf 'OK   %s (exit %d)\n' "${name}" "${rc}"
}

# @description Copy the live workflows into a fresh scenario directory
# and apply one yq edit to one copied workflow.
# @arg $1 scenario directory name  @arg $2 workflow file name
# @arg $3 yq expression
function mutated_copy() {
  local -r dir="${TMP_DIR}/$1"
  mkdir -- "${dir}"
  cp -- "${LIVE_DIR}"/*.yml "${dir}/"
  yq --inplace "$3" "${dir}/$2"
  printf '%s' "${dir}"
}

# @description Write one workflow into a fresh scenario directory.
# @arg $1 scenario directory name  @arg $2 workflow-level permissions
#   (YAML flow)  @arg $3 job-level permissions (YAML flow, '' for none)
# @arg $4 the notify step's `uses:`
function generated() {
  local -r dir="${TMP_DIR}/$1"
  mkdir -- "${dir}"
  {
    printf 'name: generated\non: push\npermissions: %s\njobs:\n  notify:\n    runs-on: ubuntu-latest\n' "$2"
    if [[ -n $3 ]]; then
      printf '    permissions: %s\n' "$3"
    fi
    printf '    steps:\n      - uses: actions/checkout@0000000000000000000000000000000000000000\n'
    printf '      - uses: %s\n' "$4"
    printf '  other:\n    runs-on: ubuntu-latest\n    permissions: {}\n    steps:\n      - run: echo PAYLOAD_RAN\n'
  } >"${dir}/generated.yml"
  printf '%s' "${dir}"
}

readonly LOCAL_USES='./.github/actions/notify-workflow-result'
readonly SLUG_USES='rvenutolo/linPEAS-flake/.github/actions/notify-workflow-result@0000000000000000000000000000000000000000'

# pages.yml's notify job grants its scopes at job level, so the live
# scenario asserts that a job-level grant was read.
scenario live "${LIVE_DIR}" 0 'ok   pages.yml job notify: actions read, checks read, from job permissions'

scenario pages-without-checks "$(mutated_copy pages-checks pages.yml 'del(.jobs.notify.permissions.checks)')" 1 \
  'FAIL pages.yml job notify calls notify-workflow-result without checks: read (has unset)'
scenario pages-without-actions "$(mutated_copy pages-actions pages.yml 'del(.jobs.notify.permissions.actions)')" 1 \
  'FAIL pages.yml job notify calls notify-workflow-result without actions: read (has unset)'
scenario local-without-checks "$(generated local-checks '{}' '{actions: read, checks: none, issues: write}' "${LOCAL_USES}")" 1 \
  'FAIL generated.yml job notify calls notify-workflow-result without checks: read (has none)'
scenario inherited-without-scopes "$(generated inherited '{issues: write}' '' "${LOCAL_USES}")" 1 \
  'FAIL generated.yml job notify calls notify-workflow-result without actions: read (has unset)'
scenario job-grants-none "$(generated none '{}' '{actions: none, checks: read, issues: write}' "${LOCAL_USES}")" 1 \
  'FAIL generated.yml job notify calls notify-workflow-result without actions: read (has none)'

scenario control-job-grants "$(generated job-grants '{}' '{actions: read, checks: write, issues: write}' "${LOCAL_USES}")" 0 \
  'ok   generated.yml job notify: actions read, checks write, from job permissions'
scenario control-inherited "$(generated inherit-grants '{actions: read, checks: read}' '' "${LOCAL_USES}")" 0 \
  'ok   generated.yml job notify: actions read, checks read, from workflow permissions'
scenario control-read-all "$(generated read-all 'read-all' '' "${LOCAL_USES}")" 0 \
  'ok   generated.yml job notify: actions read-all, checks read-all, from workflow permissions'
scenario no-caller "$(generated no-caller '{}' '{}' 'actions/checkout@0000000000000000000000000000000000000000')" 2 \
  'no job under'
scenario slug-not-caller "$(generated slug '{}' '{}' "${SLUG_USES}")" 2 \
  'no job under'

harness_assert_verify || failures=1

if ((failures != 0)); then
  printf '\nnotify-caller-permissions: FAILURES\n' >&2
  exit 1
fi
printf '\nnotify-caller-permissions: all passed\n'
