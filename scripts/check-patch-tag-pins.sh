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
# Honors LINT_PATHS_OVERRIDE (newline-separated file list) for fixtures.
# Exits 0 on clean; exits 1 with per-violation `file:line:` summary.

set -Eeuo pipefail
IFS=$'\n\t'

paths=()
if [[ -n ${LINT_PATHS_OVERRIDE:-} ]]; then
  while IFS= read -r p; do
    [[ -n ${p} ]] && paths+=("${p}")
  done <<<"${LINT_PATHS_OVERRIDE}"
else
  while IFS= read -r p; do
    paths+=("${p}")
  done < <(
    find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null || true
    find .github/actions -type f \( -name 'action.yml' -o -name 'action.yaml' \) 2>/dev/null || true
  )
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
