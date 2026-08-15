#!/usr/bin/env bash
# scripts/check-commitlint-config-explicit.sh
#
# @description Lint: every `wagoid/commitlint-github-action` step pins a
# non-empty `configFile:` that resolves to a file on disk, and the merge
# ruleset differs from the strict one only by the two zeroed length rules.

# Lint: the commitlint action never runs against an implicit config, and
# the two commitlint rulesets stay in lockstep.
#
# The action's `configFile` input defaults to `./commitlint.config.mjs`.
# That file does not exist in this repo, and the action then falls back
# to a bundled `@commitlint/config-conventional` instead of failing. An
# unset `configFile` therefore makes this repo's own commitlint config a
# no-op in CI with no visible symptom — the job still passes, just
# against somebody else's rules. This lint pins that shut.
#
# Assertions:
#   1. Every step whose `uses:` starts with
#      `wagoid/commitlint-github-action` has a `with:` block carrying a
#      non-empty `configFile:`.
#   2. Every config path named by such a `configFile` exists on disk.
#      The value may be a literal path or a GitHub Actions ternary
#      expression `${{ <cond> && 'A' || 'B' }}`, in which case both `A`
#      and `B` must exist: CI picks one per event, so a missing arm is
#      only discovered on the event that selects it.
#   3. `.commitlintrc.merge.yml` zeroes exactly `body-max-line-length`
#      and `footer-max-line-length` and declares no other rule. The
#      merge config exists to accommodate GitHub-composed merge-commit
#      text, not to be a general escape hatch.
#   4. `.commitlintrc.yml` and `.commitlintrc.merge.yml` declare
#      identical `extends:` lists. The merge config names the base
#      preset directly rather than extending the base file by relative
#      path, because it is exercised only on `push` to `main` where a
#      resolution failure lands after the merge. This assertion is what
#      keeps that duplicate honest.
#
# See docs/development/git.md.
#
# Honors PATHS_OVERRIDE (newline-separated file list) for fixtures. The
# two config files are read from the repo root by default; under
# PATHS_OVERRIDE they are read from the directory of the first overridden
# path, so a fixture directory supplies its own workflow AND its own pair
# of configs. Referenced `configFile` paths resolve against that same
# base directory. Skips this script if it appears in the scan set.
# LINT_ALLOW_EMPTY_SCAN=1 accepts an empty scan set.
#
# Exits 0 on full coverage, 1 on any drift, 2 when yq is absent or the
# scan set could not be enumerated.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly ACTION_PREFIX="wagoid/commitlint-github-action"
readonly BASE_CONFIG=".commitlintrc.yml"
readonly MERGE_CONFIG=".commitlintrc.merge.yml"
readonly SELF="scripts/check-commitlint-config-explicit.sh"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

paths=()
if [[ -n ${PATHS_OVERRIDE:-} ]]; then
  while IFS= read -r p; do
    [[ -z ${p} ]] && continue
    paths+=("${p}")
  done <<<"${PATHS_OVERRIDE}"
else
  enumerate_into paths 'git ls-files' git ls-files -z -- \
    '.github/workflows/*.yml' '.github/workflows/*.yaml'
fi

# Base directory the two config files and every referenced configFile
# path resolve against: the repo root normally, the first overridden
# path's directory under PATHS_OVERRIDE.
if [[ -n ${PATHS_OVERRIDE:-} && ${#paths[@]} -gt 0 ]]; then
  base_dir="$(dirname "${paths[0]}")"
else
  base_dir="."
fi
readonly base_dir

failed=0

fail() {
  printf '%s\n' "$*" >&2
  failed=$((failed + 1))
}

# --- Assertions 1 and 2: every action step pins an existing config. ---
for f in "${paths[@]}"; do
  [[ -f ${f} ]] || continue
  case "${f}" in
  "${SELF}" | */"${SELF}") continue ;;
  esac

  # Capture yq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(yq ...)`: a process substitution's exit
  # status is not propagated under set -Eeuo pipefail, so a yq failure
  # (unparsable workflow, or a query that errors on a valid-but-odd
  # shape) would yield empty input and the check would pass silently.
  # shellcheck disable=SC2016 # yq expression + literal `${{` needle: no shell expansion wanted
  if ! rows="$(yq eval '
    .jobs // {} | to_entries[] as $j
    | $j.value.steps // [] | to_entries[]
    | select(.value.uses // "" | test("^'"${ACTION_PREFIX}"'"))
    | $j.key
      + "|" + (.key | tostring)
      + "|" + (.value.with | tag)
      + "|" + (.value.with.configFile | tag)
      + "|" + (.value.with.configFile // "" | tostring)
  ' "${f}")"; then
    fail "$(printf '%s: could not evaluate workflow with yq (malformed?)' "${f}")"
    continue
  fi
  [[ -n ${rows} ]] || continue
  # shellcheck disable=SC2016 # literal `${{` needle below: no shell expansion wanted
  while IFS='|' read -r job idx with_tag cfg_tag cfg_val; do
    [[ -z ${job} ]] && continue
    # A missing key yields an empty tag; an explicit `with:` with a null
    # body yields `!!null`. Both mean "no usable `with:` block".
    if [[ -z ${with_tag} || ${with_tag} == '!!null' ]]; then
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      fail "$(printf '%s: job %q step[%s] %s has no `with:` block; add `with.configFile: <path>` (an unset configFile silently falls back to a bundled preset)' \
        "${f}" "${job}" "${idx}" "${ACTION_PREFIX}")"
      continue
    fi
    if [[ -z ${cfg_tag} || ${cfg_tag} == '!!null' || -z ${cfg_val} ]]; then
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      fail "$(printf '%s: job %q step[%s] %s has no non-empty `with.configFile:`; add one (an unset configFile silently falls back to a bundled preset)' \
        "${f}" "${job}" "${idx}" "${ACTION_PREFIX}")"
      continue
    fi

    refs=()
    if [[ ${cfg_val} == *'${{'* ]]; then
      # Ternary shape `${{ <cond> && 'A' || 'B' }}`: both arms are live,
      # each on a different event, so both must resolve. The arms are the
      # operands of `&&` / `||`; quoted strings inside <cond> (event
      # names, ref names) are not paths and must not be treated as such.
      if [[ ${cfg_val} =~ \&\&[[:space:]]*\'([^\']*)\'[[:space:]]*\|\|[[:space:]]*\'([^\']*)\' ]]; then
        refs+=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
      else
        # Captured rather than fed through a process substitution, whose
        # subshell would hide a broken pipeline behind an empty ref list
        # and turn a tooling fault into the "names no quoted config path"
        # verdict below. No quoted string is a real answer (status 1);
        # only a higher status is a could-not-run.
        quoted_status=0
        quoted_refs="$(grep -o "'[^']*'" <<<"${cfg_val}" |
          sed "s/^'//;s/'\$//")" || quoted_status=$?
        if ((quoted_status > 1)); then
          printf '%s: could not extract quoted config paths from %q\n' \
            "${f}" "${cfg_val}" >&2
          exit 2
        fi
        while IFS= read -r q; do
          [[ -z ${q} ]] && continue
          refs+=("${q}")
        done <<<"${quoted_refs}"
      fi
      if ((${#refs[@]} == 0)); then
        # shellcheck disable=SC2016 # literal backticks in human-readable prose
        fail "$(printf '%s: job %q step[%s] `configFile: %s` is an expression naming no quoted config path' \
          "${f}" "${job}" "${idx}" "${cfg_val}")"
        continue
      fi
    else
      refs+=("${cfg_val}")
    fi

    for ref in "${refs[@]}"; do
      if [[ ! -f ${base_dir}/${ref} ]]; then
        # shellcheck disable=SC2016 # literal backticks in human-readable prose
        fail "$(printf '%s: job %q step[%s] `configFile` names %q, which does not exist at %q' \
          "${f}" "${job}" "${idx}" "${ref}" "${base_dir}/${ref}")"
      fi
    done
  done <<<"${rows}"
done

# --- Assertions 3 and 4: the two rulesets stay in lockstep. ---
readonly base_path="${base_dir}/${BASE_CONFIG}"
readonly merge_path="${base_dir}/${MERGE_CONFIG}"

for p in "${base_path}" "${merge_path}"; do
  if [[ ! -f ${p} ]]; then
    fail "$(printf '%s: commitlint config missing; both %s and %s must exist' \
      "${p}" "${BASE_CONFIG}" "${MERGE_CONFIG}")"
  fi
done

if [[ -f ${merge_path} ]]; then
  merge_rules="$(yq eval '.rules // {} | to_entries | map(.key + "=" + (.value | tostring)) | sort | join(",")' "${merge_path}")"
  readonly want_rules='body-max-line-length=[0],footer-max-line-length=[0]'
  if [[ ${merge_rules} != "${want_rules}" ]]; then
    fail "$(printf '%s: rules must be exactly %q; got %q. The merge ruleset relaxes only the two GitHub-composed line-length rules' \
      "${merge_path}" "${want_rules}" "${merge_rules}")"
  fi
fi

if [[ -f ${base_path} && -f ${merge_path} ]]; then
  base_extends="$(yq eval '[.extends // []] | flatten | join(",")' "${base_path}")"
  merge_extends="$(yq eval '[.extends // []] | flatten | join(",")' "${merge_path}")"
  if [[ ${base_extends} != "${merge_extends}" ]]; then
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    fail "$(printf '%s and %s declare different `extends:` lists (%q vs %q); the merge config duplicates the base preset list and must track it' \
      "${base_path}" "${merge_path}" "${base_extends}" "${merge_extends}")"
  fi
fi

if ((failed > 0)); then
  printf '%d commitlint config drift(s) found\n' "${failed}" >&2
  exit 1
fi
exit 0
