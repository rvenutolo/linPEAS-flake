#!/usr/bin/env bash
# scripts/check-nix-run-pinned.sh
#
# Lint: ban unpinned `nix run nixpkgs#<pkg>` invocations.
#
# At runtime, the bare `nixpkgs` flake reference resolves through the
# user's (or runner's) flake registry — NOT this repo's `flake.lock`.
# That means a step that runs `nix run nixpkgs#cosign` pulls whatever
# nixpkgs commit the runner's registry happens to point at, bypassing
# the repo's Renovate-pinned nixpkgs commit. A malicious or
# compromised nixpkgs revision could ship a backdoored tool.
#
# Allowed alternatives:
#   - `nix shell .#<pkg> --command <pkg> <args>` — uses the repo's
#     own flake outputs (resolved via flake.lock).
#   - `nix run .#<pkg> -- <args>` — same.
#   - `nix run nixpkgs/<rev>#<pkg>` — explicit commit pin.
#
# Detection scans workflows, scripts, and shell-fenced markdown
# blocks. The check matches the literal token `nix run nixpkgs#`
# (no rev separator). `nix run nixpkgs/<rev>#` passes.
#
# See docs/security/workflow-hardening.md.
#
# Honors PATHS_OVERRIDE (newline-separated file list) for fixtures.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'

# The bad pattern: "nix run nixpkgs#" with no `/<rev>` between
# `nixpkgs` and `#`. We deliberately do NOT match `nix run nixpkgs/...`
# (a pinned-rev reference is fine).
readonly BAD_REGEX='nix run nixpkgs#'

paths=()
if [[ -n ${PATHS_OVERRIDE:-} ]]; then
  while IFS= read -r p; do
    [[ -z ${p} ]] && continue
    paths+=("${p}")
  done <<<"${PATHS_OVERRIDE}"
else
  while IFS= read -r p; do
    paths+=("${p}")
  done < <(git ls-files \
    '.github/workflows/*.yml' '.github/workflows/*.yaml' \
    'scripts/*.sh' \
    'docs/**/*.md' \
    'docs/*.md' \
    'README.md' 'SECURITY.md' 2>/dev/null || true)
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
  # Use process substitution so the read loop runs in the parent shell
  # and the failed counter survives.
  while IFS= read -r hit; do
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: unpinned `nix run nixpkgs#<pkg>` invocation; got: %s\n' \
      "${f}" "${hit}" >&2
    failed=$((failed + 1))
  done < <(awk -v mode="${mode}" -v rx="${BAD_REGEX}" '
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
  ' "${f}")
done

if ((failed > 0)); then
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf '%d unpinned `nix run nixpkgs#<pkg>` invocation(s)\n' "${failed}" >&2
  exit 1
fi
exit 0
