#!/usr/bin/env bash
# scripts/check-verify-reason-ladder.sh
#
# @description Lint: the `attribute failure reason` step of
# `verify-latest-release.yml` covers every id-carrying step of the
# `verify` job, reads every env var it declares, documents every reason
# token it emits, and walks the ladder in step-execution order.

# The notify job turns the `reason` token into triage wording. A
# verification step whose `id:` never reaches the attribution ladder
# makes a real failure surface as `reason=unknown`, which the notify
# body documents as "a bug in the attribution logic itself" — so a
# genuine tamper signal is filed as a self-diagnosed tooling bug and the
# maintainer's first reflex is to go fix the lint instead of the
# incident. The reason list in the verification doc is a third copy of
# the same mapping and drifts the same way.
#
# Four assertions:
#
#   1. Coverage — every step of the `verify` job carrying an `id:`,
#      except the attribution step itself, is referenced by a
#      `${{ steps.<id>.outcome }}` expression among the attribution
#      step's `env:` values.
#   2. Ladder use — every env var NAME the attribution step declares is
#      named somewhere in that step's `run:` body. An env entry no
#      branch reads is a step whose failure the ladder cannot attribute.
#   3. Docs parity — every `reason='<token>'` the ladder assigns, other
#      than the initial `reason='ok'`, appears literally in the
#      verification doc.
#   4. Order — the order in which env var names are first tested in the
#      ladder matches the execution order of the steps they map to. The
#      ladder's contract is "the first failed step wins", which holds
#      only while it walks in execution order: a step that fails leaves
#      every later step `skipped`, so testing a later step first
#      attributes nothing, but testing an EARLIER step later means an
#      earlier failure is shadowed by whichever branch is reached first.
#
# Escape hatch: a step whose `id:` line also carries a
# `# reason-ladder-exempt: <reason>` comment is excluded from assertion
# 1. The marker must sit on the SAME LINE as the `id:` key — detection
# is a raw-text scan of that line, so a marker on its own line, on the
# `name:` line, or anywhere else in the step is not seen. The rationale
# after the colon must be non-empty.
#
# See docs/security/verification.md.
#
# Env overrides (test-only):
#   VERIFY_WORKFLOW_OVERRIDE  — alternate workflow path
#   VERIFICATION_DOC_OVERRIDE — alternate verification doc path
#
# Exit codes:
#   0  all four assertions hold
#   1  drift detected (details printed to stderr)
#   2  missing yq / missing input file / unparsable workflow

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT

readonly WORKFLOW="${VERIFY_WORKFLOW_OVERRIDE:-${REPO_ROOT}/.github/workflows/verify-latest-release.yml}"
readonly DOC="${VERIFICATION_DOC_OVERRIDE:-${REPO_ROOT}/docs/security/verification.md}"

# The step whose `id:` names the attribution ladder. Excluded from the
# coverage assertion — it is the attributor, never an attributed step.
readonly ATTRIBUTE_ID='attribute'

# Same-line escape-hatch marker.
readonly EXEMPT_MARKER='reason-ladder-exempt:'

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

[[ -f ${WORKFLOW} ]] || {
  printf 'missing workflow %s\n' "${WORKFLOW}" >&2
  exit 2
}
[[ -f ${DOC} ]] || {
  printf 'missing verification doc %s\n' "${DOC}" >&2
  exit 2
}

# --- workflow extraction ---------------------------------------------
# Capture yq's output (and exit status) into a variable rather than
# feeding a loop from `< <(yq ...)`: a process substitution's exit
# status is not propagated under `set -Eeuo pipefail`, so an unparsable
# workflow would yield empty input and every assertion below would pass
# over nothing.
if ! step_ids="$(yq eval '.jobs.verify.steps[] | select(has("id")) | .id' "${WORKFLOW}")"; then
  printf '%s: could not evaluate workflow with yq (malformed?)\n' "${WORKFLOW}" >&2
  exit 2
fi
if [[ -z ${step_ids} ]]; then
  printf '%s: could not evaluate any id-carrying step in the verify job\n' "${WORKFLOW}" >&2
  exit 2
fi

if ! env_rows="$(yq eval \
  ".jobs.verify.steps[] | select(.id == \"${ATTRIBUTE_ID}\") | .env | to_entries[] | .key + \"\t\" + .value" \
  "${WORKFLOW}")"; then
  printf '%s: could not evaluate the attribution step env block with yq\n' "${WORKFLOW}" >&2
  exit 2
fi
if [[ -z ${env_rows} ]]; then
  printf '%s: could not evaluate an env block on the %q step\n' \
    "${WORKFLOW}" "${ATTRIBUTE_ID}" >&2
  exit 2
fi

if ! ladder_body="$(yq eval \
  ".jobs.verify.steps[] | select(.id == \"${ATTRIBUTE_ID}\") | .run" \
  "${WORKFLOW}")"; then
  printf '%s: could not evaluate the attribution step run body with yq\n' "${WORKFLOW}" >&2
  exit 2
fi
if [[ -z ${ladder_body} || ${ladder_body} == 'null' ]]; then
  printf '%s: could not evaluate a run body on the %q step\n' \
    "${WORKFLOW}" "${ATTRIBUTE_ID}" >&2
  exit 2
fi

drift=0

# --- step order ------------------------------------------------------
# yq emits sequence entries in document order, so the position of an id
# in this list is its execution order within the job.
declare -A STEP_INDEX=()
steps=()
while IFS= read -r id; do
  [[ -z ${id} ]] && continue
  STEP_INDEX["${id}"]="${#steps[@]}"
  steps+=("${id}")
done <<<"${step_ids}"

# --- escape hatch ----------------------------------------------------
# Raw-text scan: the marker is a YAML comment, so it is gone by the time
# yq has parsed the document. Only a marker on the `id:` line itself
# counts, which keeps the exemption visually attached to the step it
# exempts.
declare -A EXEMPT=()
declare -A EXEMPT_LINE=()
# The scan is captured so awk's exit status reaches this shell: a process
# substitution runs in its own subshell, so a dead awk would hand the loop
# an empty stream and every exemption marker in the file would go unread.
if ! exempt_rows="$(awk -v marker="${EXEMPT_MARKER}" '
  $0 ~ ("^[[:space:]]*id:[[:space:]]*[^[:space:]#]+[[:space:]]*#.*" marker) {
    line = $0
    sub(/^[[:space:]]*id:[[:space:]]*/, "", line)
    id = line
    sub(/[[:space:]]*#.*$/, "", id)
    rationale = line
    sub(("^.*" marker "[[:space:]]*"), "", rationale)
    sub(/[[:space:]]+$/, "", rationale)
    printf "%s\t%s\t%d\n", id, rationale, FNR
  }
' "$(awk_path "${WORKFLOW}")")"; then
  printf '%s: awk failed scanning for reason-ladder-exempt markers\n' \
    "${WORKFLOW}" >&2
  exit 2
fi
while IFS=$'\t' read -r id rationale marker_line; do
  [[ -z ${id} ]] && continue
  if [[ -z ${rationale} ]]; then
    printf '%s: reason-ladder-exempt marker on step id %q carries no rationale\n' \
      "${WORKFLOW}" "${id}" >&2
    drift=1
    continue
  fi
  EXEMPT["${id}"]=1
  EXEMPT_LINE["${id}"]="${marker_line}"
done <<<"${exempt_rows}"

# --- attribution env block -------------------------------------------
# env var NAME -> the step id its `${{ steps.<id>.outcome }}` value
# names. A value naming no step outcome maps to the empty string; it is
# still subject to assertion 2.
declare -A ENV_STEP=()
env_names=()
declare -A REFERENCED=()
bad_env_name=0
while IFS=$'\t' read -r name value; do
  [[ -z ${name} ]] && continue
  # Both remaining assertions interpolate this name verbatim into a
  # regex — an ERE in assertion 2, a gawk dynamic regex in assertion 4 —
  # so a name carrying a regex metacharacter is matched as a pattern
  # rather than as the literal it is meant to be. The two engines
  # disagree about malformed patterns: a name such as `A{1` is lenient
  # in GNU grep but fatal in gawk, which kills the producer feeding
  # assertion 4 and leaves that assertion checking nothing at all while
  # the lint still prints its affirmative banner. Requiring a shell
  # identifier makes both interpolations literal by construction. A
  # GitHub Actions env key is a shell identifier in any workflow that
  # can read it, so a non-conforming key is drift, not a tooling fault.
  if [[ ! ${name} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    printf '%s: attribution env key %q is not a shell identifier; attribution env names must match ^[A-Za-z_][A-Za-z0-9_]*$\n' \
      "${WORKFLOW}" "${name}" >&2
    bad_env_name=1
    continue
  fi
  env_names+=("${name}")
  ref=''
  if [[ ${value} =~ steps\.([A-Za-z0-9_-]+)\.outcome ]]; then
    ref="${BASH_REMATCH[1]}"
    REFERENCED["${ref}"]=1
  fi
  ENV_STEP["${name}"]="${ref}"
done <<<"${env_rows}"

# Stop here rather than folding this into `drift`: every assertion below
# would be interpolating the rejected name into a regex.
if ((bad_env_name)); then
  exit 1
fi

# A marker on a step the attribution env already references excuses
# nothing: assertion 1 would have passed that step regardless. Unlike its
# sibling lints, this marker always names a real step, so the finding is
# an unearned exemption rather than one attached to no site — the same
# drift in a different shape, and the same reason to report it.
for id in "${!EXEMPT[@]}"; do
  if [[ ${id} == "${ATTRIBUTE_ID}" ]] || [[ -n ${REFERENCED[${id}]:-} ]]; then
    printf '%s:%s: reason-ladder-exempt marker on step id %q excuses nothing; the attribution env already reads this step, so the exemption asserts a decision the lint no longer honors — delete it\n' \
      "${WORKFLOW}" "${EXEMPT_LINE[${id}]}" "${id}" >&2
    drift=1
  fi
done

# --- assertion 1: coverage -------------------------------------------
for id in "${steps[@]}"; do
  [[ ${id} == "${ATTRIBUTE_ID}" ]] && continue
  [[ -n ${EXEMPT[${id}]:-} ]] && continue
  if [[ -z ${REFERENCED[${id}]:-} ]]; then
    printf '%s: step id %q has no steps.<id>.outcome entry in the attribution env\n' \
      "${WORKFLOW}" "${id}" >&2
    drift=1
  fi
done

# --- assertion 2: ladder use -----------------------------------------
# Boundary-aware so `READ_TAG` is not satisfied by a `READ_TAG_EXTRA`
# occurrence. The name is safe to interpolate into the ERE because the
# identifier check above already rejected every name that could carry a
# regex metacharacter.
#
# grep's status is read three ways rather than as a boolean: exit 2 means
# grep itself could not run the search, and scoring that as "no match"
# reports a step the ladder does read as unread — a tooling fault filed
# as workflow drift.
for name in "${env_names[@]}"; do
  read_status=0
  grep --extended-regexp --quiet -- \
    "(^|[^A-Za-z0-9_])${name}([^A-Za-z0-9_]|$)" <<<"${ladder_body}" ||
    read_status=$?
  case "${read_status}" in
  0) ;;
  1)
    printf '%s: attribution env var %q is never read by the reason ladder\n' \
      "${WORKFLOW}" "${name}" >&2
    drift=1
    ;;
  *)
    printf '%s: grep failed searching the ladder body for env var %q\n' \
      "${WORKFLOW}" "${name}" >&2
    exit 2
    ;;
  esac
done

# --- assertion 3: docs parity ----------------------------------------
# `reason='ok'` is the no-failure initializer, not an attributed
# outcome, so the doc is not expected to carry it.
reason_tokens=()
# grep's status is read three ways here for the same reason it is above:
# no assignment in the body (1) is data, but a grep that could not run
# (2) fed through a process substitution would empty this list and the
# parity assertion would pass having compared nothing.
reason_status=0
reason_matches="$(grep --only-matching --extended-regexp -- \
  "reason='[^']*'" <<<"${ladder_body}")" || reason_status=$?
if ((reason_status > 1)); then
  printf '%s: grep failed extracting reason tokens from the ladder body\n' \
    "${WORKFLOW}" >&2
  exit 2
fi
while IFS= read -r assignment; do
  [[ -z ${assignment} ]] && continue
  token="${assignment#reason=\'}"
  token="${token%\'}"
  reason_tokens+=("${token}")
done <<<"${reason_matches}"

if ((${#reason_tokens[@]} > 0)) && [[ ${reason_tokens[0]} == 'ok' ]]; then
  reason_tokens=("${reason_tokens[@]:1}")
fi

for token in ${reason_tokens+"${reason_tokens[@]}"}; do
  if ! grep --fixed-strings --quiet -- "${token}" "${DOC}"; then
    printf '%s: reason token %q is not documented in %s\n' \
      "${WORKFLOW}" "${token}" "${DOC}" >&2
    drift=1
  fi
done

# --- assertion 4: ladder order ---------------------------------------
# First textual occurrence of each env var name in the run body, in
# reading order, is where the ladder tests it.
names_file="$(make_temp)"
body_file="$(make_temp)"
# awk reads an operand whose first path component is an identifier
# followed by `=` as a variable assignment, not as a file: it then finds
# no file operand at all, reads stdin, and exits 0 having emitted
# nothing. `make_temp` honors TMPDIR, so a relative TMPDIR is enough to put
# a `=` in the leading component. An absolute path always starts with
# `/`, which no assignment can, so the operand can only be read as a
# file.
[[ ${names_file} == /* ]] || names_file="${PWD}/${names_file}"
[[ ${body_file} == /* ]] || body_file="${PWD}/${body_file}"
# shellcheck disable=SC2064 # expand the paths now, while they are in scope
trap "rm --force -- '${names_file}' '${body_file}'" EXIT
printf '%s\n' "${env_names[@]}" >"${names_file}"
printf '%s\n' "${ladder_body}" >"${body_file}"

# Capture the pipeline rather than feeding the loop from `< <(...)`, for
# the same reason the yq reads above are captured: a substitution's exit
# status never reaches the consumer, so a dead awk hands the loop an
# empty stream and this assertion silently checks nothing.
if ! ladder_order_rows="$(awk '
  NR == FNR { name[++n] = $0; next }
  {
    for (i = 1; i <= n; i++) {
      if (i in seen) continue
      if (match($0, "(^|[^A-Za-z0-9_])" name[i] "([^A-Za-z0-9_]|$)")) {
        seen[i] = 1
        printf "%d\t%d\t%s\n", FNR, RSTART, name[i]
      }
    }
  }
' "$(awk_path "${names_file}")" "$(awk_path "${body_file}")" | sort --key=1,1n --key=2,2n | cut --fields=3)"; then
  printf '%s: awk failed scanning the ladder body for env var first use\n' \
    "${WORKFLOW}" >&2
  exit 2
fi

ladder_order=()
while IFS= read -r name; do
  [[ -z ${name} ]] && continue
  ladder_order+=("${name}")
done <<<"${ladder_order_rows}"

prev_name=''
prev_index=-1
for name in ${ladder_order+"${ladder_order[@]}"}; do
  ref="${ENV_STEP[${name}]}"
  # An env value naming no step, or naming one the verify job does not
  # define, carries no execution position to order against. Say so
  # rather than skipping silently: an unresolvable reference is drift in
  # its own right.
  if [[ -z ${ref} ]]; then
    continue
  fi
  if [[ -z ${STEP_INDEX[${ref}]:-} ]]; then
    printf '%s: attribution env var %q references step id %q, which the verify job does not define\n' \
      "${WORKFLOW}" "${name}" "${ref}" >&2
    drift=1
    continue
  fi
  index="${STEP_INDEX[${ref}]}"
  if ((prev_index >= 0 && index < prev_index)); then
    printf '%s: ladder tests %q before %q, but the steps run in the opposite order\n' \
      "${WORKFLOW}" "${prev_name}" "${name}" >&2
    drift=1
  fi
  prev_name="${name}"
  prev_index="${index}"
done

if ((drift)); then
  exit 1
fi
printf 'check-verify-reason-ladder: ok (%d id-carrying steps, %d env entries, %d reason tokens)\n' \
  "${#steps[@]}" "${#env_names[@]}" "${#reason_tokens[@]}"
exit 0
