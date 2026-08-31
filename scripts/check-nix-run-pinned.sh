#!/usr/bin/env bash
# scripts/check-nix-run-pinned.sh
#
# @description Lint: ban any `nix` invocation against the bare
# `nixpkgs` registry ref across workflows, composite actions, scripts,
# and shell-fenced markdown. Allowed alternatives use the repo's own
# flake or an explicit commit pin.

# Lint: ban any `nix` invocation against the bare `nixpkgs` registry
# ref.
#
# At runtime, the bare `nixpkgs` flake reference resolves through the
# user's (or runner's) flake registry — NOT this repo's `flake.lock`.
# That means a step that runs `nix run nixpkgs#cosign` pulls whatever
# nixpkgs commit the runner's registry happens to point at, bypassing
# the repo's Renovate-pinned nixpkgs commit. A malicious or
# compromised nixpkgs revision could ship a backdoored tool. The
# registry lookup is what makes the ref unpinned, so the hazard is the
# same for every subcommand — `run`, `shell`, `develop`, `build`.
#
# Allowed alternatives:
#   - `nix shell .#<pkg> --command <pkg> <args>` — uses the repo's
#     own flake outputs (resolved via flake.lock).
#   - `nix run .#<pkg> -- <args>` — same.
#   - `nix run nixpkgs/<rev>#<pkg>` — explicit commit pin.
#
# Detection scans workflows, composite actions under .github/actions/,
# scripts, and shell-fenced markdown
# blocks. The check matches a `nix` command word followed by a bare
# `nixpkgs#` ref, with any subcommand and any flags in between.
# A `/<rev>` between `nixpkgs` and `#` passes.
#
# See docs/security/workflow-hardening.md.
#
# Honors PATHS_OVERRIDE (newline-separated file list) for fixtures, and
# LINT_ALLOW_EMPTY_SCAN=1 to accept an empty scan set.
# Exits 0 on full coverage, 1 on any drift, 2 when the scan set could not
# be enumerated.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"

# The bad pattern: a `nix` command word, then anything, then a bare
# `nixpkgs#` ref standing on its own token boundary. The leading
# alternation keeps `nix` a whole word (so `linux nixpkgs#…` or
# `foo-nix …` do not match). Requiring whitespace or line start before
# `nixpkgs#` is what exempts a pinned-rev reference: in
# `nixpkgs/<rev>#<pkg>` the `#` follows the revision, so the literal
# `nixpkgs#` never appears. The middle is unconstrained so a ref that
# trails an earlier flake ref — `nix shell .#jq nixpkgs#cosign` — is
# still seen.
readonly BAD_REGEX='(^|[^[:alnum:]_.-])nix[[:space:]].*(^|[[:space:]])nixpkgs#'

paths=()
if [[ -n ${PATHS_OVERRIDE:-} ]]; then
  while IFS= read -r p; do
    [[ -z ${p} ]] && continue
    paths+=("${p}")
  done <<<"${PATHS_OVERRIDE}"
else
  enumerate_into paths 'git ls-files' git ls-files -z -- \
    '.github/workflows/*.yml' '.github/workflows/*.yaml' \
    '.github/actions/**/*.yml' '.github/actions/**/*.yaml' \
    'scripts/*.sh' \
    'docs/**/*.md' \
    'docs/*.md' \
    'README.md' 'SECURITY.md'
fi

failed=0
for f in "${paths[@]}"; do
  [[ -f ${f} ]] || continue
  # Skip self: this script contains the literal bad-pattern string in
  # its detection regex.
  case "${f}" in
  */scripts/check-nix-run-pinned.sh | scripts/check-nix-run-pinned.sh)
    continue
    ;;
  esac

  mode="other"
  case "${f}" in
  *.md) mode="md" ;;
  esac

  # Walk lines via awk, capture hits, then attribute to file with $f.
  # The capture is what makes awk's exit status reach this shell: fed
  # through a process substitution instead, a dead awk would hand the
  # loop an empty stream and the file would score as clean.
  if ! hits="$(awk -v mode="${mode}" -v rx="${BAD_REGEX}" '
    BEGIN { in_fence = 0; fence_lang = "" }
    {
      line = $0
      if (mode == "md") {
        if (line ~ /^[[:space:]]*```/) {
          if (in_fence) { in_fence = 0; fence_lang = "" }
          else {
            in_fence = 1
            tmp = line
            sub(/^[[:space:]]*```/, "", tmp)
            sub(/[[:space:]].*$/, "", tmp)
            fence_lang = tmp
          }
          next
        }
        if (!in_fence) next
        if (fence_lang != "" \
            && fence_lang != "sh" \
            && fence_lang != "bash" \
            && fence_lang != "shell" \
            && fence_lang != "console" \
            && fence_lang != "text") next
      }
      if (mode != "md" && line ~ /^[[:space:]]*#/) next
      if (mode != "md" && line ~ /^[[:space:]]*-?[[:space:]]*(name|description):/) next
      if (line ~ rx) {
        stripped = line
        gsub(/`[^`]*`/, "", stripped)
        if (stripped ~ rx) {
          sub(/^[[:space:]]+/, "", line)
          print line
        }
      }
    }
  ' "$(awk_path "${f}")")"; then
    printf '%s: awk failed scanning %s for flake refs\n' "${0##*/}" "${f}" >&2
    exit 2
  fi
  while IFS= read -r hit; do
    [[ -z ${hit} ]] && continue
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: unpinned bare `nixpkgs#<pkg>` flake ref; got: %s\n' \
      "${f}" "${hit}" >&2
    failed=$((failed + 1))
  done <<<"${hits}"
done

if ((failed > 0)); then
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf '%d unpinned bare `nixpkgs#<pkg>` flake ref(s)\n' "${failed}" >&2
  exit 1
fi
exit 0
