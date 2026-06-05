#!/usr/bin/env bash
# scripts/check-patch-tag-pins.sh
#
# @description Lint: every SHA-pinned `uses:` in workflow / composite
# action files carries an exact patch-tag comment (e.g. `# v1.2.3`)
# rather than a floating major-tag comment (e.g. `# v1`), UNLESS the
# same line also carries an inline `# patch-tag-exception: <reason>`
# marker.

# Belt-and-braces backstop to the runtime ratchet-pin-audit check.
# Defaults scan `.github/workflows/*.yml` + `.github/actions/**/action.yml`.
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
    find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null
    find .github/actions -type f -name 'action.yml' 2>/dev/null
  )
fi

# uses: <ref>@<40-hex> # v<N>  where the char after v<N> is space, EOL, or `#`
# (so `# v3.36.0` is correctly skipped — the `.` after v3 disqualifies).
readonly RE='uses:[[:space:]]*[^@[:space:]]+@[0-9a-fA-F]{40}[[:space:]]*#[[:space:]]*v[0-9]+([[:space:]]|#|$)'

violations=0
for file in "${paths[@]}"; do
  [[ -f ${file} ]] || continue
  ln=0
  while IFS= read -r line; do
    ln=$((ln + 1))
    [[ ${line} =~ ${RE} ]] || continue
    # Allow if a non-empty patch-tag-exception marker is on the same line.
    if [[ ${line} =~ patch-tag-exception:[[:space:]]*[^[:space:]] ]]; then
      continue
    fi
    printf '%s:%d: major-tag comment without patch-tag-exception:%s\n' \
      "${file}" "${ln}" "${line}" >&2
    violations=$((violations + 1))
  done <"${file}"
done

if ((violations > 0)); then
  printf '%d violation(s) found\n' "${violations}" >&2
  exit 1
fi
exit 0
