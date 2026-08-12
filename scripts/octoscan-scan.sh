#!/usr/bin/env bash
# scripts/octoscan-scan.sh
#
# @description Run synacktiv/octoscan against `.github/workflows`
# via the pinned ghcr container image. Single source of truth for
# the image digest, the version label tracked by Renovate, the
# noise-suppression flags, and the exit-code mapping shared by the
# CI workflow and the pre-commit hook.
#
# Usage:
#   scripts/octoscan-scan.sh                 # text output to stdout
#   scripts/octoscan-scan.sh --sarif <path>  # SARIF output to <path>
#
# Exit codes:
#   0 — scan clean
#   1 — findings present, OR the scanner ran and errored (image pull
#       failure, scanner internal error). The caller must distinguish
#       via the `has-finding` line printed to stdout
#       (`has-finding=true|false`) — same contract the CI workflow
#       already exposes via `$GITHUB_OUTPUT`.
#   2 — the scan could not start: a tool it needs is absent, so no
#       workflow file was read. Still fails the hook and the job; only
#       the diagnosis differs, and it now matches the `infra-failure`
#       classification this script already prints for the case.
#
# Per-file iteration: octoscan v0.1.7 directory-target mode silently
# returns exit 0 with empty SARIF even when a single-file invocation
# against the same workflow flags a finding. Loop over each workflow
# yaml, tracking "any file errored" separately from "any file has a
# finding" (an error must not be masked by another file's finding), and
# merge per-file SARIF `runs[0].results` into a single SARIF document for
# upload only when no file errored.
#
# Suppressions (CLI flags — `--config-file` is documented but
# `paths.<glob>.ignore` is a no-op in v0.1.7):
#   --disable-rules local-action  : repo intentionally uses
#       `./.github/actions/*` composite actions (e.g.
#       notify-workflow-result, setup-nix); every reference is a
#       false positive.
#   --disable-rules dangerous-write : every `>> "$GITHUB_OUTPUT"`
#       and `>> "$GITHUB_ENV"` is flagged regardless of input
#       trust; the rule has no notion of which writes carry
#       attacker-controlled data, so it is unworkably noisy here.
#   --ignore '(needs|steps)\.\*\*\.outputs\.\*\*' : `expression-injection`
#       fires on every workflow-internal `${{ needs.X.outputs.Y }}`
#       / `${{ steps.X.outputs.Y }}` reference; those carry data
#       set by other jobs/steps in the same workflow, not external
#       input.
#   --ignore "actions/checkout' with a custom ref" : same regex
#       covers the renovate-flake-lock-refresh workflow's
#       `actions/checkout` with `ref:` set to a bot-controlled
#       branch — the ref source is internal, not attacker-supplied.
#
# Renovate manages OCTOSCAN_DIGEST + OCTOSCAN_VERSION in lockstep
# (renovate.json customManager scoped to this file).

set -Eeuo pipefail
IFS=$'\n\t'

OCTOSCAN_DIGEST="sha256:3368f42651f9ca0d7a7cd08de3b734476046d17ffa0b2b0c6c55acef556300db"
OCTOSCAN_VERSION="v0.1.7"
# shellcheck disable=SC2034 # Renovate reads OCTOSCAN_VERSION to track the version label in lockstep with OCTOSCAN_DIGEST.
readonly OCTOSCAN_DIGEST OCTOSCAN_VERSION

readonly DISABLE_RULES="local-action,dangerous-write"
readonly IGNORE_PATTERN='(needs|steps)\.\*\*\.outputs\.\*\*|actions/checkout. with a custom ref'

sarif_out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --sarif)
    [[ $# -ge 2 ]] || {
      printf 'error: --sarif requires a path argument\n' >&2
      exit 1
    }
    sarif_out="$2"
    shift 2
    ;;
  --help | -h)
    sed -n '2,/^$/p' "$0" | sed 's|^# \{0,1\}||'
    exit 0
    ;;
  *)
    printf 'error: unknown argument: %s\n' "$1" >&2
    exit 1
    ;;
  esac
done

# @description Print the diagnostic line that names why the run ended as it
# did, and how much of the workflow directory was actually analyzed.
# `has-finding=false` plus a non-zero exit is printed by every failure mode
# — docker absent, jq absent, a scanner error with no finding, a scanner
# error alongside findings — so `has-finding=` alone tells an operator only
# that the run is not a finding, never which branch produced it. The
# classification names that branch; the scope states how many workflow files
# reached the scanner, which is what says whether a "no findings" verdict
# covered the directory or covered nothing.
# @arg $1 scope sentence
# @arg $2 classification
function print_summary() {
  printf 'octoscan-scan: %s; classification=%s\n' "$1" "$2"
}

if ! command -v docker >/dev/null 2>&1; then
  printf 'octoscan pre-commit hook requires docker.\n' >&2
  printf 'Install docker, or skip the hook for one commit with:\n' >&2
  printf '  SKIP=octoscan git commit ...\n' >&2
  printf 'has-finding=false\n'
  print_summary 'no workflow file scanned' 'infra-failure (docker unavailable)'
  exit 2
fi

if [[ -n ${sarif_out} ]] && ! command -v jq >/dev/null 2>&1; then
  printf 'octoscan-scan.sh requires jq for --sarif aggregation.\n' >&2
  printf 'has-finding=false\n'
  print_summary 'no workflow file scanned' \
    'infra-failure (jq unavailable for --sarif aggregation)'
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")"
workflows_dir="${repo_root}/.github/workflows"

shopt -s nullglob
workflows=("${workflows_dir}"/*.yml "${workflows_dir}"/*.yaml)
shopt -u nullglob

if [[ ${#workflows[@]} -eq 0 ]]; then
  printf 'has-finding=false\n'
  print_summary 'no workflow file under .github/workflows' 'nothing-to-scan'
  exit 0
fi

per_file_sarifs=()
# shellcheck disable=SC2329 # Invoked via `trap ... EXIT`.
cleanup() {
  if ((${#per_file_sarifs[@]} > 0)); then
    rm -f -- "${per_file_sarifs[@]}"
  fi
}
trap cleanup EXIT

n_clean=0
n_finding=0
n_error=0
for wf in "${workflows[@]}"; do
  rel="${wf#"${repo_root}/"}"
  file_rc=0
  if [[ -n ${sarif_out} ]]; then
    tmp_sarif="$(mktemp)"
    per_file_sarifs+=("${tmp_sarif}")
    docker run --rm \
      -v "${repo_root}:/src:ro" \
      "ghcr.io/synacktiv/octoscan@${OCTOSCAN_DIGEST}" \
      scan "/src/${rel}" \
      --disable-rules "${DISABLE_RULES}" \
      --ignore "${IGNORE_PATTERN}" \
      --format sarif \
      >"${tmp_sarif}" 2>/dev/null || file_rc=$?
  else
    docker run --rm \
      -v "${repo_root}:/src:ro" \
      "ghcr.io/synacktiv/octoscan@${OCTOSCAN_DIGEST}" \
      scan "/src/${rel}" \
      --disable-rules "${DISABLE_RULES}" \
      --ignore "${IGNORE_PATTERN}" || file_rc=$?
  fi
  # octoscan per-file exit codes: 0 clean, 2 finding, anything else (1, …) a
  # scanner error — the file was never analyzed. Tally each outcome
  # separately: a max-of-codes reduction would let a finding (2) outrank an
  # error (1) and misclassify a mixed run as a clean finding, silently
  # dropping the errored file. The per-outcome counts are also what the
  # summary line reports, so an operator reading "no findings" can see how
  # many files that verdict actually covered.
  case "${file_rc}" in
  0) n_clean=$((n_clean + 1)) ;;
  2) n_finding=$((n_finding + 1)) ;;
  *) n_error=$((n_error + 1)) ;;
  esac
done

if [[ -n ${sarif_out} && ${n_error} -eq 0 ]]; then
  # Aggregate only when no file errored, so a file that never analyzed cannot
  # be silently absent from the merged SARIF and reported clean. The first
  # SARIF carries the driver + rules manifest (identical across invocations of
  # the same image); concatenate `runs[0].results` from every per-file SARIF.
  jq -s '
    [.[].runs[0].results // []] as $all
    | .[0]
    | .runs[0].results = ($all | add)
  ' "${per_file_sarifs[@]}" >"${sarif_out}"
fi

printf -v scanned 'scanned %d workflow file(s): %d clean, %d with findings, %d errored' \
  "${#workflows[@]}" "${n_clean}" "${n_finding}" "${n_error}"

# Error outranks finding: a file that never analyzed is an infra failure even
# when another file produced a finding, so it routes to the infra-failure path
# (has-finding=false, exit 1) and is re-examined rather than reported clean.
if ((n_error > 0)); then
  # Truncated/partial SARIF is worse than missing SARIF; drop it so downstream
  # consumers (CI upload-sarif) skip cleanly instead of uploading garbage.
  [[ -n ${sarif_out} ]] && rm -f -- "${sarif_out}"
  printf 'has-finding=false\n'
  # Whether findings were also recorded changes what an operator does next: a
  # re-scan of an all-errored run starts from nothing, while a mixed run has
  # real findings to triage plus files still unexamined.
  if ((n_finding > 0)); then
    print_summary "${scanned}" 'infra-failure (findings recorded but incomplete)'
  else
    print_summary "${scanned}" 'infra-failure (no findings recorded)'
  fi
  exit 1
elif ((n_finding > 0)); then
  printf 'has-finding=true\n'
  print_summary "${scanned}" 'findings'
  exit 1
else
  printf 'has-finding=false\n'
  print_summary "${scanned}" 'clean'
  exit 0
fi
