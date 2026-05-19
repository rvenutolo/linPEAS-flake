#!/usr/bin/env bash
# scripts/check-pr-workflows-no-secrets.sh
#
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
# Exits 0 if every PR-triggered workflow is clean, 1 otherwise.
set -Eeuo pipefail
IFS=$'\n\t'

readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-.github/workflows}"

if [[ ! -d ${WORKFLOWS_DIR} ]]; then
  printf 'pr-workflows-no-secrets lint: workflows dir %s missing\n' "${WORKFLOWS_DIR}" >&2
  exit 1
fi

# @description Return 0 if the workflow file is triggered by pull_request
# or pull_request_target (flow or block form); 1 otherwise.
# @arg $1 path to workflow YAML
function is_pr_triggered() {
  local -r file="$1"
  # POSIX-awk state machine — no gawk extensions:
  #   - flow form `on: pull_request` / `on: pull_request_target` → match
  #   - flow-sequence `on: [a, b]` → match if list contains either name
  #   - block form `on:` followed by indented `pull_request:` /
  #     `pull_request_target:` keys, or `- pull_request` list entries
  #   - column-0 non-blank/non-comment line exits the on: block
  awk '
    BEGIN { in_on = 0 }
    { sub(/\r$/, "") }

    /^on:[[:space:]]*$/ {
      in_on = 1
      next
    }
    /^on:[[:space:]]*(pull_request|pull_request_target)([[:space:]]|$)/ {
      print "match"; exit 0
    }
    /^on:[[:space:]]*\[.*\]/ {
      line = $0
      sub(/^[^[]*\[/, "", line)
      sub(/\].*$/, "", line)
      gsub(/[[:space:]]/, "", line)
      n = split(line, arr, ",")
      for (i = 1; i <= n; i++) {
        if (arr[i] == "pull_request" || arr[i] == "pull_request_target") {
          print "match"; exit 0
        }
      }
      next
    }

    !in_on { next }

    {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]*#/) next

      # Column-0 non-blank/non-comment line ends the on: block.
      if ($0 !~ /^[[:space:]]/) {
        in_on = 0
        next
      }

      if ($0 ~ /^[[:space:]]+(pull_request|pull_request_target)[[:space:]]*:/) {
        print "match"; exit 0
      }
      if ($0 ~ /^[[:space:]]+-[[:space:]]+(pull_request|pull_request_target)[[:space:]]*$/) {
        print "match"; exit 0
      }
    }
  ' "${file}" | grep --quiet '^match$'
}

# @description Scan a PR-triggered workflow for disallowed secrets refs.
# Increments the global failed counter and prints violations to stderr.
# @arg $1 path to workflow YAML
function scan_secrets() {
  local -r file="$1"
  local tmp
  tmp="$(mktemp)"
  grep --extended-regexp --line-number \
    '\$\{\{[[:space:]]*secrets\.[A-Za-z0-9_]+[[:space:]]*\}\}' \
    "${file}" >"${tmp}" || true

  local line
  while IFS= read -r line; do
    [[ -z ${line} ]] && continue
    local lineno="${line%%:*}"
    local rest="${line#*:}"
    local tokens_file
    tokens_file="$(mktemp)"
    grep --extended-regexp --only-matching \
      'secrets\.[A-Za-z0-9_]+' >"${tokens_file}" <<<"${rest}" || true
    local token
    while IFS= read -r token; do
      [[ -z ${token} ]] && continue
      if [[ ${token} == 'secrets.GITHUB_TOKEN' ]]; then
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
shopt -s nullglob
for wf in "${WORKFLOWS_DIR}"/*.yml; do
  if is_pr_triggered "${wf}"; then
    scan_secrets "${wf}"
  fi
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d violation(s) found\n' "${failed}" >&2
  exit 1
fi
exit 0
