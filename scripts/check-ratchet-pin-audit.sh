#!/usr/bin/env bash
# scripts/check-ratchet-pin-audit.sh
#
# @description Lint: the ratchet-pin-audit workflow keeps its
# hardened shape — empty top-level permissions, harden-runner first,
# per-job permissions and timeouts, typed reason tokens in the notify
# body, ratchet in the nix/devshell.nix devShell, and a documented
# ratchet version matching the one the devShell ships, among others — so
# future edits cannot silently weaken it.

# Lint: assert ratchet-pin-audit.yml retains the structural hardening
# invariants this script enforces — each one is asserted below and named
# in its own diagnostic, so the assertions are the specification.
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
# — `yq` or `ratchet` absent from PATH, the workflow file itself missing,
# a workflow expression yq cannot evaluate, an unreadable version site, or
# a `ratchet --version` string carrying no X.Y.Z. The `on:` reads stop the
# run on the workflow's own content too: a root giving `on` twice, an
# `on:` holding an alias nested too deep to resolve, or a merge key in
# `on:` that `yq` cannot resolve (see ON_NODE). A file `yq` reads as
# several YAML documents, or whose root is not a map, is one finding. With no workflow to
# parse there is no invariant to score, and counting that as a failed
# invariant would report drift in a file the check never read.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/repo.sh
source "${_lib_dir}/lib/repo.sh"

REPO_ROOT="$(repo_toplevel)"
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

# @description Print one expression's value from the workflow under
# audit. Returns non-zero, naming the expression, when `yq` cannot
# evaluate it. `yq` is on PATH — an absent one is reported by the guard
# above — so a failure here is a workflow that does not parse or an
# expression its shape does not support. Either way no invariant was
# scored, which is the answer an absent workflow already gives; an
# unchecked read would instead leave the run carrying yq's own exit 1,
# read by the caller as hardening drift in a file nothing was read from.
# @arg $1 yq expression
# @arg $2 what the expression reads, named in place of it (optional)
# @exitcode 1 yq could not evaluate the expression
function read_workflow() {
  local -r expr="$1" what="${2:-$1}"
  local value
  if ! value="$(yq eval "${expr}" "${WORKFLOW}")"; then
    printf 'cannot read %s from %s\n' "${what}" "${WORKFLOW}" >&2
    return 1
  fi
  printf '%s' "${value}"
}

# The `on:` node every `on:` read starts from, with its aliases resolved.
# It is the one root key that is `on` or an alias of `on`: a root holding
# more than one makes `yq` fail ("on: is given more than once"). With no
# such key it is `.on`, which is how an `on:` a root merge key brings in
# is read, since the merged keys are not the root's own.
# `explode`, handed that node alone, resolves one level of aliases per
# pass: the aliases a node holds, not those inside what they stand for.
# So the node goes through sixteen passes, and one that still holds an
# alias after them is refused by `yq` with an error rather than read. A
# file `yq` reads through this is never passed with an alias left in it.
# Both refusals, and a merge key in `on:` that `explode` cannot resolve
# (one bringing in a list), stop the run like any read `yq` cannot
# evaluate (exit 2).
# Its memory cost is a stated limit: docs/development/linting.md, section
# "YAML aliases in workflow reads".
# shellcheck disable=SC2016 # yq program literal; its $ names are yq variables
readonly ON_NODE='.on as $plain | [to_entries[] | select((.key | explode(.)) == "on") | .value] as $all | with(select($all | length > 1); error("on: is given more than once")) | ($all + [$plain] | .[0]) as $n | [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16][] as $i ireduce ($n; explode(.)) | with(select([... | select(kind == "alias")] | length > 0); error("on: holds an alias nested too deep to resolve"))'

# The top-level `permissions:` node, read through an alias: `explode`
# handed only that node resolves it in one pass, since an anchor cannot
# sit on an alias. The node is collected into a list first, so an absent
# key reads as null rather than as nothing at all.
# shellcheck disable=SC2016 # yq program literal
readonly PERMS_NODE='[(.permissions | select(kind == "alias") | explode(.)), (.permissions | select(kind != "alias"))] | .[0]'

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

# A file `yq` reads as several YAML documents has no one workflow to
# score (GitHub Actions refuses such a file), and every read below would
# print one answer per document, so it is one finding, read no further.
# A trailing `---` starts a second document.
if ! doc_kinds="$(read_workflow 'kind')"; then
  exit 2
fi
if [[ ${doc_kinds} == *$'\n'* ]]; then
  fail "workflow holds several YAML documents, which GitHub Actions refuses; it is read no further"
  printf '%d invariant(s) failed\n' "${failed}" >&2
  exit 1
fi
# A root that is not a map holds none of the keys below, and the `on:`
# reads would fail on it, so it too is one finding, read no further.
if [[ ${doc_kinds} != 'map' ]]; then
  fail "workflow root is not a map (kind=${doc_kinds}); it is read no further"
  printf '%d invariant(s) failed\n' "${failed}" >&2
  exit 1
fi

# 2. Top-level permissions is exactly the empty map. The node is read by
# its kind, so a map carrying a tag of its own is still a map, and an
# empty scalar carrying the map tag is not one.
if ! perms_shape="$(read_workflow "${PERMS_NODE}"' | kind + " " + (length | tostring) + " " + tag' 'the top-level permissions')"; then
  exit 2
fi
# The tag is free text (a verbatim tag decodes %20 to a space), so it is
# the last field.
IFS=' ' read -r perms_kind perms_len perms_tag <<<"${perms_shape}"
if [[ ${perms_kind} != "map" || ${perms_len} != "0" ]]; then
  fail "top-level permissions must be {} (got kind=${perms_kind} tag=${perms_tag} length=${perms_len})"
fi

# 3. Both jobs declare timeout-minutes.
for job in check notify; do
  if ! t="$(read_workflow ".jobs.\"${job}\".\"timeout-minutes\" // \"\"")"; then
    exit 2
  fi

  if [[ -z ${t} ]]; then
    fail "job ${job}: timeout-minutes missing"
  fi
done

# 4. harden-runner is the first step of every job.
for job in check notify; do
  if ! first="$(read_workflow ".jobs.\"${job}\".steps[0].uses // \"\"")"; then
    exit 2
  fi

  if [[ ${first} != step-security/harden-runner@* ]]; then
    fail "job ${job}: first step must be step-security/harden-runner (got: ${first})"
  fi
done

# 5. Every actions/checkout step sets persist-credentials: false.
if ! checkout_count="$(read_workflow '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@"))] | length')"; then
  exit 2
fi
if ! safe_count="$(read_workflow '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | select(.with."persist-credentials" == false)] | length')"; then
  exit 2
fi

if [[ ${checkout_count} != "${safe_count}" ]]; then
  fail "actions/checkout: ${checkout_count} steps total, only ${safe_count} set persist-credentials: false"
fi

# 6. on: includes a non-empty schedule list AND workflow_dispatch. Both
# are read from ON_NODE by kind: a list or a map carrying a tag of its
# own is still read, and an `on:` that is not a map holds neither.
if ! sched="$(read_workflow "[${ON_NODE}"' | select(kind == "map") | .schedule | kind + " " + (length | tostring) + " " + tag] + ["absent 0 -"] | .[0]' 'the on: schedule')"; then
  exit 2
fi
if ! disp="$(read_workflow "[${ON_NODE}"' | select(kind == "map") | has("workflow_dispatch")] + [false] | .[0]' 'the on: workflow_dispatch')"; then
  exit 2
fi

IFS=' ' read -r sched_kind sched_len sched_tag <<<"${sched}"
if [[ ${sched_kind} != "seq" || ${sched_len} == "0" ]]; then
  fail "on: must include a schedule sequence (got kind=${sched_kind} tag=${sched_tag} length=${sched_len})"
fi
if [[ ${disp} != "true" ]]; then
  fail "on: must include workflow_dispatch"
fi

# 7. concurrency.group is exactly ratchet-pin-audit.
if ! group="$(read_workflow '.concurrency.group // ""')"; then
  exit 2
fi

if [[ ${group} != "ratchet-pin-audit" ]]; then
  fail "concurrency.group must be \"ratchet-pin-audit\" (got: \"${group}\")"
fi

# 8. Notify body contains all four reason tokens.
if ! body="$(read_workflow '.jobs.notify.steps[] | select(.uses == "./.github/actions/notify-workflow-result") | .with.body // ""')"; then
  exit 2
fi

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
if ! check_perms="$(read_workflow '.jobs.check.permissions | to_entries | map(.key + ":" + (.value | tostring)) | sort | join(",")')"; then
  exit 2
fi

if [[ ${check_perms} != "contents:read" ]]; then
  fail "job check: permissions must be exactly { contents: read } (got: ${check_perms})"
fi
if ! notify_perms="$(read_workflow '.jobs.notify.permissions | to_entries | map(.key + ":" + (.value | tostring)) | sort | join(",")')"; then
  exit 2
fi

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
