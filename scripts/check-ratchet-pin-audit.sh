#!/usr/bin/env bash
# scripts/check-ratchet-pin-audit.sh
#
# @description Lint: the ratchet-pin-audit workflow keeps its
# hardened shape — empty top-level permissions, harden-runner first,
# typed reason tokens in the notify body, ratchet in the
# nix/devshell.nix devShell, and a documented ratchet version matching
# the one the devShell ships — so future edits cannot silently weaken it.

# Lint: assert ratchet-pin-audit.yml retains the eleven structural
# hardening invariants this script enforces — each one is asserted
# below and named in its own diagnostic, so the assertions are the
# specification.
#
# The version assertion exists because `ratchet` comes from nixpkgs as a
# bare devShell entry with no pin in the tree, so its version floats with
# the nixpkgs input while the workflow and the runbook assert a specific
# number. Those statements are load-bearing: they explain why the workflow
# does its own upstream drift detection instead of trusting `ratchet lint`,
# which is a claim about one version's behaviour. A nixpkgs bump that
# staleifies them now fails a check rather than passing unnoticed.
#
# WORKFLOW_PATH_OVERRIDE points at an alternate workflow file
# (used by tests/check-ratchet-pin-audit.test.sh fixtures).
# RATCHET_DOC_OVERRIDE and RATCHET_VERSION_OVERRIDE are the fixture hooks
# for the version assertion: the second stands in for the installed tool,
# so the mismatch case is exercisable offline.
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
readonly DEFAULT_VERSION_DOC="${REPO_ROOT}/docs/runbooks/ratchet-pin-audit.md"
readonly VERSION_DOC="${RATCHET_DOC_OVERRIDE:-${DEFAULT_VERSION_DOC}}"
# Every site states the version as `ratchet <X.Y.Z>`; one spelling is what
# makes the set of sites enumerable rather than guessed at.
readonly VERSION_RE='ratchet[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+'

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

# 11. Every documented `ratchet <X.Y.Z>` literal names the version the
# devShell actually ships. Skipped under WORKFLOW_PATH_OVERRIDE for the same
# reason as 9 — the devShell is global, not per-fixture — unless the fixture
# also supplies RATCHET_VERSION_OVERRIDE, which is what lets the harness
# drive the mismatch case without a second ratchet installed.
if [[ -z ${WORKFLOW_PATH_OVERRIDE:-} || -n ${RATCHET_VERSION_OVERRIDE:-} ]]; then
  ratchet_version="${RATCHET_VERSION_OVERRIDE:-}"
  if [[ -z ${ratchet_version} ]]; then
    if ! command -v ratchet >/dev/null 2>&1; then
      printf 'ratchet not found on PATH\n' >&2
      exit 2
    fi
    # `ratchet --version` prints `ratchet X.Y.Z (<sha>, <os>/<arch>)`.
    ratchet_version="$(ratchet --version 2>&1 | awk 'NR == 1 { print $2 }')"
  fi
  if [[ ! ${ratchet_version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'could not read a version from ratchet --version (got %q)\n' \
      "${ratchet_version}" >&2
    exit 2
  fi

  # grep separates "no site states a version" (1) from "a file could not be
  # read" (2). Only the first is a finding about content.
  version_rc=0
  version_hits="$(grep --no-filename --only-matching --extended-regexp \
    -- "${VERSION_RE}" "${WORKFLOW}" "${VERSION_DOC}")" || version_rc=$?
  if ((version_rc > 1)); then
    printf 'could not read a version site (%s, %s)\n' \
      "${WORKFLOW}" "${VERSION_DOC}" >&2
    exit 2
  fi

  documented=0
  while IFS= read -r hit; do
    [[ -z ${hit} ]] && continue
    documented=$((documented + 1))
    stated="${hit##*[[:space:]]}"
    if [[ ${stated} != "${ratchet_version}" ]]; then
      fail "documented ratchet version ${stated} does not match the devShell's ratchet ${ratchet_version}; re-read the behavioural claim before bumping the literal"
    fi
  done <<<"${version_hits}"

  # Breadth, not just cleanliness: a reword that drops every literal would
  # leave nothing to compare and pass silently. Removing the version claim
  # is a decision, so it has to be made against this diagnostic.
  if ((documented == 0)); then
    fail "no 'ratchet <X.Y.Z>' version site found in ${WORKFLOW} or ${VERSION_DOC}; the version claim cannot be checked"
  fi
fi

if ((failed > 0)); then
  printf '%d invariant(s) failed\n' "${failed}" >&2
  exit 1
fi
exit 0
