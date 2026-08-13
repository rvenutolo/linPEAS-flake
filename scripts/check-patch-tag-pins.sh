#!/usr/bin/env bash
# scripts/check-patch-tag-pins.sh
#
# @description Lint: every SHA-pinned `uses:` in workflow / composite
# action files carries an exact patch-tag comment — present, and shaped
# as `# v<major>.<minor>[.<patch>]` with at least two numeric components
# (e.g. `# v1.2.3`). A missing comment, a comment naming no version
# (e.g. `# main`), and a floating major-tag comment (e.g. `# v1`) are
# all violations. The only escape is an inline
# `# patch-tag-exception: <reason>` marker on the same line.

# A SHA pin records the commit but not the tag it was resolved from; the
# trailing comment is the sole record of the intended tag, and the
# runtime ratchet-pin-audit reads it to detect tag-vs-SHA drift. A pin
# whose comment is absent or imprecise makes that drift undetectable, so
# this lint is a belt-and-braces backstop to that runtime check.
# Defaults scan `.github/workflows/*.yml`|`*.yaml` +
# `.github/actions/**/action.yml` (or `action.yaml`).
# Honors LINT_PATHS_OVERRIDE (newline-separated file list) for fixtures,
# and LINT_ALLOW_EMPTY_SCAN=1 to accept an empty scan set.
# Exits 0 on clean; exits 1 with per-violation `file:line:` summary; exits 2
# when the scan set could not be enumerated or came back empty.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"

paths=()
if [[ -n ${LINT_PATHS_OVERRIDE:-} ]]; then
  while IFS= read -r p; do
    [[ -n ${p} ]] && paths+=("${p}")
  done <<<"${LINT_PATHS_OVERRIDE}"
else
  # Each root is scanned only when it is there, because a repo may carry
  # workflows and no composite actions (or the reverse), so one root being
  # absent is not itself a fault. What is a fault is BOTH roots yielding
  # nothing: a cwd with no `.github` at all would otherwise read exactly
  # like a tree whose every pin already carries an exact patch tag — every
  # pin in the repo then goes unread behind an exit 0. The breadth
  # assertion below is what separates those two, so LINT_ALLOW_EMPTY_SCAN is
  # forced on each per-root call: a producer failure still aborts the run,
  # but a present-and-empty root no longer does on its own.
  if [[ -d .github/workflows ]]; then
    workflow_paths=()
    LINT_ALLOW_EMPTY_SCAN=1 enumerate_into workflow_paths 'find .github/workflows' \
      find .github/workflows -maxdepth 1 -type f \
      \( -name '*.yml' -o -name '*.yaml' \) -print0
    paths+=(${workflow_paths+"${workflow_paths[@]}"})
  fi
  if [[ -d .github/actions ]]; then
    action_paths=()
    LINT_ALLOW_EMPTY_SCAN=1 enumerate_into action_paths 'find .github/actions' \
      find .github/actions -type f \
      \( -name 'action.yml' -o -name 'action.yaml' \) -print0
    paths+=(${action_paths+"${action_paths[@]}"})
  fi
  if ((${#paths[@]} == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf '%s: enumerated 0 workflow / composite-action file(s) under .github — a tree with pins to check cannot have an empty scan set; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate\n' \
      "${0##*/}" >&2
    exit 2
  fi
fi

# Every `uses: <ref>@<40-hex>` line is in scope, comment or not.
readonly PIN_RE='uses:[[:space:]]*[^@[:space:]]+@[0-9a-fA-F]{40}'
# Two or more dot-separated numeric components, so `# v1` and `# v23` do
# not qualify while `# v1.2.3` and `# v0.24.0` do.
readonly PATCH_TAG_RE='#[[:space:]]*v[0-9]+(\.[0-9]+)+'
# The reason must be non-empty: a bare `patch-tag-exception:` explains
# nothing and does not waive the rule.
readonly EXCEPTION_RE='patch-tag-exception:[[:space:]]*[^[:space:]]'
# Used only to pick the message for a line already known to violate.
readonly VERSION_TOKEN_RE='#.*v[0-9]'

violations=0
for file in "${paths[@]}"; do
  [[ -f ${file} ]] || continue
  ln=0
  while IFS= read -r line; do
    ln=$((ln + 1))
    [[ ${line} =~ ${PIN_RE} ]] || continue
    if [[ ${line} =~ ${PATCH_TAG_RE} ]] || [[ ${line} =~ ${EXCEPTION_RE} ]]; then
      continue
    fi
    if [[ ${line} != *'#'* ]]; then
      msg='pin carries no version comment'
    elif [[ ! ${line} =~ ${VERSION_TOKEN_RE} ]]; then
      msg='pin comment names no version'
    else
      msg='pin comment names a major tag, not an exact patch tag'
    fi
    printf '%s:%d: %s:%s\n' "${file}" "${ln}" "${msg}" "${line}" >&2
    violations=$((violations + 1))
  done <"${file}"
done

if ((violations > 0)); then
  printf '%d violation(s) found\n' "${violations}" >&2
  exit 1
fi
exit 0
