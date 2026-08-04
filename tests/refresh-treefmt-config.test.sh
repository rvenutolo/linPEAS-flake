#!/usr/bin/env bash
# tests/refresh-treefmt-config.test.sh
#
# Round-trip + drift harness for scripts/refresh-treefmt-config.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-treefmt-config.sh"
readonly DOC="${REPO_ROOT}/docs/reference/treefmt-config.md"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Declared at top-level so the EXIT trap can reference it across function
# boundaries (mirrors tests/refresh-precommit-table.test.sh).
backup=''

# The treefmt-config-fresh hook guards a generated doc. Its pre-commit
# `files` filter must match every nix module the generator evaluates, or
# a commit touching only such a module leaves the doc stale with the
# guard silent on the per-changed-file path. Derived from the tree, not
# hardcoded: this fails if the config moves to a module outside the
# filter's `nix/.*\.nix` coverage; a move within `nix/` stays covered.
function scenario_hook_watches_eval_modules() {
  local -r freshness="${REPO_ROOT}/nix/hooks/freshness.nix"

  # The attribute the generator evaluates, read out of the generator.
  local attr
  attr="$(grep --only-matching --extended-regexp \
    'devTooling\.\$\{sys\}\.[A-Za-z0-9_]+' "${SCRIPT}" |
    head --lines=1 | sed 's/.*\.//')"
  if [[ -z ${attr} ]]; then
    fail 'no devTooling eval attribute found in the generator'
    return
  fi

  # Every tracked nix file naming that attribute, plus one level of the
  # relative imports those files pull in.
  local -A modules=()
  local f
  while IFS= read -r f; do
    [[ -z ${f} ]] && continue
    modules["${f}"]=1
  done < <(git -C "${REPO_ROOT}" grep --files-with-matches \
    --fixed-strings -- "${attr}" -- '*.nix')

  local m dir imp rel
  for m in "${!modules[@]}"; do
    dir="$(dirname -- "${m}")"
    while IFS= read -r imp; do
      [[ -z ${imp} ]] && continue
      rel="$(realpath --relative-to="${REPO_ROOT}" --canonicalize-missing \
        -- "${REPO_ROOT}/${dir}/${imp}")"
      if [[ -f ${REPO_ROOT}/${rel} ]]; then
        modules["${rel}"]=1
      fi
    done < <(grep --only-matching --extended-regexp \
      '\.\.?/[A-Za-z0-9._/-]+\.nix' "${REPO_ROOT}/${m}" || true)
  done

  # Guard-the-guard: an empty set means the attribute was renamed or the
  # grep broke. Fail loud rather than vacuously pass.
  if [[ ${#modules[@]} -eq 0 ]]; then
    fail "no nix module defines devTooling.${attr} — derivation broke"
    return
  fi

  local files_re
  files_re="$(awk '
    /^  treefmt-config-fresh = \{/ { in_block = 1; next }
    in_block && /^  \};/ { exit }
    in_block && match($0, /files = "[^"]*"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^files = "/, "", s)
      sub(/"$/, "", s)
      print s
      exit
    }
  ' "${freshness}")"
  if [[ -z ${files_re} ]]; then
    fail 'could not extract files filter for treefmt-config-fresh'
    return
  fi

  # Nix string literal: "\\." in source is the ERE "\.".
  local ere
  ere="$(printf '%s' "${files_re}" | sed 's/\\\\/\\/g')"

  local p uncovered=0
  while IFS= read -r p; do
    if ! printf '%s\n' "${p}" |
      grep --quiet --extended-regexp -- "${ere}"; then
      printf '  uncovered module: %s\n' "${p}" >&2
      uncovered=1
    fi
  done < <(printf '%s\n' "${!modules[@]}" | sort)

  if ((uncovered)); then
    fail 'treefmt-config-fresh files filter does not cover every evaluated nix module'
  else
    pass 'treefmt-config-fresh files filter covers every evaluated nix module'
  fi
}

function main() {
  scenario_hook_watches_eval_modules

  "${SCRIPT}"
  if "${SCRIPT}" --check; then
    pass '--check passes on freshly generated table'
  else
    fail '--check failed right after generate'
  fi

  if grep --quiet 'nixfmt' "${DOC}" &&
    grep --quiet 'shfmt' "${DOC}"; then
    pass 'formatter table includes nixfmt/shfmt'
  else
    fail 'formatter table missing nixfmt/shfmt'
  fi

  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  trap '[[ -n "${backup:-}" && -f "${backup}" ]] && { cp -- "${backup}" "${DOC}" 2>/dev/null || true; rm --force -- "${backup}"; }' EXIT
  # Inject drift INSIDE the managed block (a bogus table row right after the
  # BEGIN marker). The generator regenerates the block without it, so --check
  # must detect the mismatch. Drift outside the markers is intentionally NOT
  # the generator's concern.
  local drifted
  drifted="$(mktemp)"
  awk '
    { print }
    /^<!-- BEGIN treefmt-config -->$/ { print "| `drift-formatter` | injected | injected |" }
  ' "${DOC}" >"${drifted}"
  cp -- "${drifted}" "${DOC}"
  rm --force -- "${drifted}"
  local rc=0
  "${SCRIPT}" --check || rc=$?
  cp -- "${backup}" "${DOC}"
  rm --force -- "${backup}"
  backup=''
  if [[ ${rc} -ne 0 ]]; then
    pass '--check fails on in-block drift'
  else
    fail '--check passed despite in-block drift'
  fi

  # A stray .refresh-treefmt-config-*.md left by an interrupted earlier run
  # must be swept by the generator's EXIT-trap cleanup, not left to litter the
  # tree (and risk being staged or tripping markdown lints on itself).
  local stray="${REPO_ROOT}/.refresh-treefmt-config-LEAKTEST.md"
  : >"${stray}"
  "${SCRIPT}" >/dev/null
  if [[ -e ${stray} ]]; then
    rm --force -- "${stray}"
    fail 'generator left a stray .refresh-treefmt-config-*.md temp behind'
  else
    pass 'generator sweeps stray in-repo temps on exit'
  fi

  # Markers the anchored awk splice cannot match (trailing whitespace on both
  # markers) must be rejected by the guard, not silently emitted unchanged.
  # An unanchored guard grep false-greens here; the anchored guard fails
  # closed with a marker-missing message.
  local ws_backup ws_err ws_rc=0
  ws_backup="$(mktemp)"
  ws_err="$(mktemp)"
  cp -- "${DOC}" "${ws_backup}"
  sed -e 's/^<!-- BEGIN treefmt-config -->$/<!-- BEGIN treefmt-config --> /' \
    -e 's/^<!-- END treefmt-config -->$/<!-- END treefmt-config --> /' \
    "${ws_backup}" >"${DOC}"
  "${SCRIPT}" --check >/dev/null 2>"${ws_err}" || ws_rc=$?
  cp -- "${ws_backup}" "${DOC}"
  if [[ ${ws_rc} -eq 1 ]] &&
    grep --fixed-strings --quiet -- 'marker missing' "${ws_err}"; then
    pass 'whitespace-perturbed markers rejected (fail-closed, not false-green)'
  else
    fail "whitespace marker guard: expected exit 1 + 'marker missing', got exit ${ws_rc}"
    cat -- "${ws_err}" >&2
  fi
  rm --force -- "${ws_backup}" "${ws_err}"

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
