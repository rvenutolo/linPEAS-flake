#!/usr/bin/env bash
# scripts/gitleaks-merge-diffs.sh
#
# @description Scan the diffs of merge commits for secrets with gitleaks.
# `gitleaks-action` scans push and pull-request ranges with
# `--no-merges --first-parent`, and `git log -p` shows a merge with an
# empty patch, so a change made only in a merge commit (a hand-resolved
# conflict) reaches no other scan. This pass selects the merge commits in
# the event's range and diffs each against its first parent. That diff
# also repeats what the merged side carried, which other scans already
# cover; the redundancy is accepted, because a normal patch is the format
# gitleaks parses and the narrower combined-diff formats are not.
#
# Range by event (`EVENT_NAME`, with `BASE_SHA` and `HEAD_SHA`):
#   pull_request — BASE_SHA..HEAD_SHA; a base absent from the clone is a
#                  setup failure.
#   push         — BASE_SHA..HEAD_SHA; an all-zero, empty or absent base
#                  scans the full history of HEAD_SHA, so a push is
#                  never scanned as empty.
#   schedule, workflow_dispatch — the full history of HEAD, the
#                  checked-out commit (not every fetched ref).
#
# Usage:
#   scripts/gitleaks-merge-diffs.sh [--source <dir>]
#   --source <dir>  repository to scan (default: this repo's top level)
#
# Exits 0 when no merge diff in range holds a finding, 1 when gitleaks
# reports a finding, 2 when the scan cannot run (missing tool, unknown
# argument or event, missing or unresolvable SHA, or gitleaks failing
# without a finding).

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
# shellcheck source=scripts/lib/repo.sh
source "${_lib_dir}/lib/repo.sh"
install_err_trap

require_tool git
require_tool gitleaks
require_tool jq

readonly ZERO_SHA='0000000000000000000000000000000000000000'

# @description True when the SHA names a commit in the source repo.
# @arg $1 source dir  @arg $2 sha
function has_commit() {
  git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null
}

# @description Print the git revision range to scan for the event.
# Setup failures exit 2.
# @arg $1 source dir
function resolve_range() {
  local -r source="$1"
  local -r event="${EVENT_NAME:-}" base="${BASE_SHA:-}" head="${HEAD_SHA:-}"
  case "${event}" in
  '')
    log_err 'EVENT_NAME is required'
    exit 2
    ;;
  schedule | workflow_dispatch)
    printf 'HEAD'
    ;;
  pull_request | push)
    if [[ -z ${head} ]]; then
      log_err "HEAD_SHA is required for a ${event} event"
      exit 2
    fi
    if ! has_commit "${source}" "${head}"; then
      log_err "head SHA not in this clone: ${head}"
      exit 2
    fi
    if [[ ${event} == push && ${base} == "${ZERO_SHA}" ]]; then
      log_info 'scanning full history: before SHA is all zeros'
      printf '%s' "${head}"
    elif [[ ${event} == push && -z ${base} ]]; then
      log_info 'scanning full history: before SHA is empty'
      printf '%s' "${head}"
    elif [[ -n ${base} ]] && has_commit "${source}" "${base}"; then
      printf '%s..%s' "${base}" "${head}"
    elif [[ ${event} == push ]]; then
      log_info "scanning full history: before SHA not in this clone: ${base}"
      printf '%s' "${head}"
    else
      log_err "base SHA not in this clone: ${base}"
      exit 2
    fi
    ;;
  *)
    log_err "unsupported EVENT_NAME: ${event}"
    exit 2
    ;;
  esac
}

function main() {
  local source=""
  while (($# > 0)); do
    case "$1" in
    --source)
      if (($# < 2)); then
        log_err '--source requires a directory'
        exit 2
      fi
      source="$2"
      shift 2
      ;;
    *)
      log_err "unknown argument: $1"
      exit 2
      ;;
    esac
  done
  if [[ -z ${source} ]]; then source="$(repo_toplevel)"; fi

  local range merges
  range="$(resolve_range "${source}")"
  merges="$(git -C "${source}" rev-list --merges --count "${range}")"
  printf 'gitleaks-merge-diffs: event=%s range=%s merges=%s\n' \
    "${EVENT_NAME}" "${range}" "${merges}"
  if ((merges == 0)); then
    printf 'gitleaks-merge-diffs: no merge commits in range\n'
    exit 0
  fi

  local report
  report="$(make_temp)"
  local rc=0
  gitleaks git --no-banner --redact \
    --report-format json --report-path "${report}" \
    --log-opts="--merges --diff-merges=first-parent ${range}" \
    "${source}" || rc=$?
  local findings=0
  if [[ -s ${report} ]]; then
    findings="$(jq 'length' "${report}")"
  fi
  rm --force -- "${report}"

  if ((findings > 0)); then
    log_err "gitleaks found ${findings} secret(s) in merge commit diffs (event=${EVENT_NAME} range=${range})"
    exit 1
  fi
  if ((rc != 0)); then
    log_err "gitleaks exited ${rc} without a finding: the scan did not complete"
    exit 2
  fi
  printf 'gitleaks-merge-diffs: no leaks in merge diffs\n'
}

main "$@"
