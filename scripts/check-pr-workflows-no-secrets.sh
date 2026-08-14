#!/usr/bin/env bash
# scripts/check-pr-workflows-no-secrets.sh
#
# @description Lint: no workflow triggered by `pull_request` /
# `pull_request_target` references any `secrets.*` other than
# `secrets.GITHUB_TOKEN`.

# Verify that no workflow triggered by `pull_request` or
# `pull_request_target` references any `secrets.*` other than
# `secrets.GITHUB_TOKEN`. PR-authored code executes in the runner with
# whatever secrets are exposed via env; restricting to GITHUB_TOKEN
# (read-only on fork PRs by default) prevents accidental secret exposure
# if a future maintainer wires a non-GITHUB_TOKEN secret into a
# PR-triggered workflow's env.
#
# Honors WORKFLOWS_DIR_OVERRIDE (defaults to .github/workflows) so the
# test harness can point at a temp dir with a single fixture.
#
# Exits 0 if every PR-triggered workflow is clean, 1 on a secrets
# violation, 2 on a tooling error (workflows dir missing, yq missing, or
# a workflow yq cannot parse).
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"
# shellcheck source=scripts/lib/temp.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/temp.sh"

readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-.github/workflows}"

if [[ ! -d ${WORKFLOWS_DIR} ]]; then
  printf 'pr-workflows-no-secrets lint: workflows dir %s missing\n' "${WORKFLOWS_DIR}" >&2
  exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

# @description Return 0 if the workflow file is triggered by pull_request
# or pull_request_target; 1 otherwise. Handles every `on:` shape yq can
# parse: scalar, flow/block sequence, and flow/block map (quoted or
# comment-trailing keys included). Exits 2 on a workflow yq cannot
# parse — fail closed, never skip-scan.
# @arg $1 path to workflow YAML
function is_pr_triggered() {
  local -r file="$1"
  local triggers
  # Capture yq's output (and exit status) into a variable rather than
  # feeding a loop or pipe from a process substitution: a procsub's exit
  # status is not propagated under set -Eeuo pipefail, so a yq parse
  # failure would silently exempt the file from scanning.
  #
  # mikefarah/yq does not lex `if $t == ... then ... else ... end`
  # (tested empirically: bare `if true then 1 else 2 end` fails with a
  # lexer error), so trigger-shape branching is done via three
  # tag-filtered alternatives unioned by the comma operator instead of a
  # single conditional.
  if ! triggers="$(yq eval '(.on | select(tag == "!!str")), (.on | select(tag == "!!seq") | .[]), (.on | select(tag == "!!map") | keys | .[])' "${file}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${file}" >&2
    exit 2
  fi
  grep --extended-regexp --line-regexp --quiet 'pull_request|pull_request_target' <<<"${triggers}"
}

# @description Scan a PR-triggered workflow for disallowed secrets refs.
# Increments the global failed counter and prints violations to stderr.
# @arg $1 path to workflow YAML
function scan_secrets() {
  local -r file="$1"
  local tmp
  tmp="$(make_temp)"
  grep --extended-regexp --line-number \
    '\$\{\{[[:space:]]*secrets\.[A-Za-z0-9_]+[[:space:]]*\}\}' \
    "${file}" >"${tmp}" || true

  local line
  while IFS= read -r line; do
    [[ -z ${line} ]] && continue
    local lineno="${line%%:*}"
    local rest="${line#*:}"
    local tokens_file
    tokens_file="$(make_temp)"
    grep --extended-regexp --only-matching \
      'secrets\.[A-Za-z0-9_]+' >"${tokens_file}" <<<"${rest}" || true
    local token
    while IFS= read -r token; do
      [[ -z ${token} ]] && continue
      if [[ ${token} == 'secrets.GITHUB_TOKEN' ]]; then
        allowed=$((allowed + 1))
        continue
      fi
      printf '%s:%s: %s not allowed in PR-triggered workflow\n' \
        "${file}" "${lineno}" "${token}" >&2
      failed=$((failed + 1))
    done <"${tokens_file}"
    rm --force -- "${tokens_file}"
  done <"${tmp}"
  rm --force -- "${tmp}"
}

failed=0
# Scope tallies behind the clean-path summary. Most of this directory is
# out of scope by design, so a pass has to say how much of it the rule
# was actually applied to.
examined=0
scanned=0
skipped=0
allowed=0
shopt -s nullglob
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' \
  "${WORKFLOWS_DIR}/*.yml" "${WORKFLOWS_DIR}/*.yaml"
for wf in "${workflow_files[@]}"; do
  examined=$((examined + 1))
  if is_pr_triggered "${wf}"; then
    scanned=$((scanned + 1))
    scan_secrets "${wf}"
  else
    skipped=$((skipped + 1))
  fi
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d violation(s) found\n' "${failed}" >&2
  exit 1
fi

# A workflow that was read and carried no disallowed secret and a
# workflow that was never read because no PR trigger put it in scope both
# leave this lint silent. Say which happened: an operator reading a green
# run needs to know whether the rule was applied or the file was out of
# scope, and a trigger change that quietly moves a workflow out of scope
# shows up here as a scanned count that dropped.
printf '%s: examined %d workflow(s): %d scanned as PR-triggered, %d skipped as not PR-triggered; %d secrets.GITHUB_TOKEN reference(s) allowed\n' \
  'pr-workflows-no-secrets' "${examined}" "${scanned}" "${skipped}" "${allowed}"
exit 0
