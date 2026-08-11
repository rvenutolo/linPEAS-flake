#!/usr/bin/env bash
# scripts/check-ratchet-pin-audit.sh
#
# @description Lint: the ratchet-pin-audit workflow keeps its
# hardened shape — empty top-level permissions, harden-runner first,
# typed reason tokens in the notify body, ratchet in the
# nix/devshell.nix devShell — so future edits cannot silently weaken it.

# Lint: assert ratchet-pin-audit.yml retains the structural
# invariants documented in the design spec
# (.claude/specs/2026-05-25-ratchet-pin-audit-design.md). See the
# 10-item "Hardening invariants" list in that doc.
#
# WORKFLOW_PATH_OVERRIDE points at an alternate workflow file
# (used by tests/check-ratchet-pin-audit.test.sh fixtures).
# Exits 0 on full coverage, 1 on any drift, 2 when the check cannot run
# — yq absent from PATH, or the workflow file itself missing. With no
# workflow to parse there is no invariant to score, and counting that as
# a failed invariant would report drift in a file the check never read.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
readonly REPO_ROOT
readonly DEFAULT_WORKFLOW="${REPO_ROOT}/.github/workflows/ratchet-pin-audit.yml"
readonly WORKFLOW="${WORKFLOW_PATH_OVERRIDE:-${DEFAULT_WORKFLOW}}"
readonly DEVSHELL="${REPO_ROOT}/nix/devshell.nix"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

failed=0
fail() {
  printf '%s\n' "$*" >&2
  failed=$((failed + 1))
}

# 1. File exists. Absent input, not a failed invariant — every check
# below reads this file, so there is nothing to score.
if [[ ! -f ${WORKFLOW} ]]; then
  printf 'workflow not found at %s\n' "${WORKFLOW}" >&2
  exit 2
fi

# 2. Top-level permissions is exactly the empty map.
perms_tag="$(yq eval '.permissions | tag' "${WORKFLOW}")"
perms_len="$(yq eval '.permissions | length' "${WORKFLOW}")"
if [[ ${perms_tag} != "!!map" || ${perms_len} != "0" ]]; then
  fail "top-level permissions must be {} (got tag=${perms_tag} length=${perms_len})"
fi

# 3. Both jobs declare timeout-minutes.
for job in check notify; do
  t="$(yq eval ".jobs.\"${job}\".\"timeout-minutes\" // \"\"" "${WORKFLOW}")"
  if [[ -z ${t} ]]; then
    fail "job ${job}: timeout-minutes missing"
  fi
done

# 4. harden-runner is the first step of every job.
for job in check notify; do
  first="$(yq eval ".jobs.\"${job}\".steps[0].uses // \"\"" "${WORKFLOW}")"
  if [[ ${first} != step-security/harden-runner@* ]]; then
    fail "job ${job}: first step must be step-security/harden-runner (got: ${first})"
  fi
done

# 5. Every actions/checkout step sets persist-credentials: false.
checkout_count="$(yq eval '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@"))] | length' "${WORKFLOW}")"
safe_count="$(yq eval '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | select(.with."persist-credentials" == false)] | length' "${WORKFLOW}")"
if [[ ${checkout_count} != "${safe_count}" ]]; then
  fail "actions/checkout: ${checkout_count} steps total, only ${safe_count} set persist-credentials: false"
fi

# 6. on: includes schedule AND workflow_dispatch.
sched="$(yq eval '.on.schedule | tag' "${WORKFLOW}")"
disp="$(yq eval '.on | has("workflow_dispatch")' "${WORKFLOW}")"
if [[ ${sched} != "!!seq" ]]; then
  fail "on: must include a schedule sequence"
fi
if [[ ${disp} != "true" ]]; then
  fail "on: must include workflow_dispatch"
fi

# 7. concurrency.group is exactly ratchet-pin-audit.
group="$(yq eval '.concurrency.group // ""' "${WORKFLOW}")"
if [[ ${group} != "ratchet-pin-audit" ]]; then
  fail "concurrency.group must be \"ratchet-pin-audit\" (got: \"${group}\")"
fi

# 8. Notify body contains all four reason tokens.
body="$(yq eval '.jobs.notify.steps[] | select(.uses == "./.github/actions/notify-workflow-result") | .with.body // ""' "${WORKFLOW}")"
for token in drift-detected upstream-api-failure ratchet-tool-failure unknown; do
  if ! grep -qE "\`${token}\`" <<<"${body}"; then
    fail "notify body missing reason token: ${token}"
  fi
done

# 9. nix/devshell.nix lists `ratchet` in the devShell buildInputs.
# Skip this check when running against a fixture (override set) — the devShell
# is global, not per-fixture. Production runs (no override) enforce it.
if [[ -z ${WORKFLOW_PATH_OVERRIDE:-} ]]; then
  if ! grep -Eq '^\s+ratchet\s*$' "${DEVSHELL}"; then
    # shellcheck disable=SC2016  # backticks are literal markdown, not command substitution
    fail 'nix/devshell.nix devShell buildInputs must list `ratchet`'
  fi
fi

# 10. Per-job permissions are exactly what's expected.
check_perms="$(yq eval '.jobs.check.permissions | to_entries | map(.key + ":" + (.value | tostring)) | sort | join(",")' "${WORKFLOW}")"
if [[ ${check_perms} != "contents:read" ]]; then
  fail "job check: permissions must be exactly { contents: read } (got: ${check_perms})"
fi
notify_perms="$(yq eval '.jobs.notify.permissions | to_entries | map(.key + ":" + (.value | tostring)) | sort | join(",")' "${WORKFLOW}")"
if [[ ${notify_perms} != "issues:write" ]]; then
  fail "job notify: permissions must be exactly { issues: write } (got: ${notify_perms})"
fi

if ((failed > 0)); then
  printf '%d invariant(s) failed\n' "${failed}" >&2
  exit 1
fi
exit 0
