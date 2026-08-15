#!/usr/bin/env bash
# scripts/check-cosign-identity-pinned.sh
#
# @description Lint: every `cosign verify*` invocation (`verify`,
# `verify-blob`, `verify-attestation`, `verify-blob-attestation`) pins
# both `--certificate-identity` (or `-regexp`) and
# `--certificate-oidc-issuer` so verification is bound to a specific
# signer.

# Lint: every cosign verify subcommand — `verify`, `verify-blob`,
# `verify-attestation`, `verify-blob-attestation`, including the
# `nix run nixpkgs#cosign -- verify` shape — across workflows, scripts,
# and shell-fenced markdown blocks pins BOTH:
#   --certificate-identity (or --certificate-identity-regexp)
#   --certificate-oidc-issuer
#
# Without identity pinning, cosign accepts any keyless Sigstore
# signature for the artifact digest — including one minted by a
# different workflow, branch, or OIDC issuer. The two flags bind the
# verification to a specific signer.
#
# Detection joins backslash-continued shell invocations; ignores prose
# in backticks and command names quoted inside message strings; for
# markdown, only considers fenced blocks tagged
# sh/bash/shell/console/text (or unlabeled). Skips this script.
#
# See docs/security/verification.md.
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

# Matches every cosign verify subcommand — `verify`, `verify-blob`,
# `verify-attestation`, `verify-blob-attestation` — in both the plain
# and the `nix shell .#cosign --command cosign -- verify` shapes. The
# generic `-suffix` form fails closed: a future verify subcommand is
# caught by default, so exempting one is a deliberate reviewed edit
# rather than a silent hole.
readonly CMD_REGEX='cosign([[:space:]]+--)?[[:space:]]+verify(-[a-z]+(-[a-z]+)*)?([[:space:]]|$)'

paths=()
if [[ -n ${PATHS_OVERRIDE:-} ]]; then
  while IFS= read -r p; do
    [[ -z ${p} ]] && continue
    paths+=("${p}")
  done <<<"${PATHS_OVERRIDE}"
else
  enumerate_into paths 'git ls-files' git ls-files -z -- \
    '.github/workflows/*.yml' '.github/workflows/*.yaml' \
    'scripts/*.sh' \
    'docs/**/*.md' \
    'docs/*.md' \
    'README.md' 'SECURITY.md'
fi

extract_invocations() {
  local -r file="$1"
  local mode="other"
  case "${file}" in
  *.md) mode="md" ;;
  esac
  awk -v mode="${mode}" -v rx="${CMD_REGEX}" -v sq="'" '
    BEGIN { in_fence = 0; fence_lang = "" }
    {
      line = $0
      if (mode == "md") {
        if (line ~ /^[[:space:]]*```/) {
          if (in_fence) {
            in_fence = 0
            fence_lang = ""
          } else {
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
      # Skip yaml step-name lines that happen to mention the command.
      if (mode != "md" && line ~ /^[[:space:]]*-?[[:space:]]*(name|description):/) next
      # A match inside backticks or inside a shell string literal is
      # data, not a command: markdown prose in the first case, a printf
      # or echo message that merely names the command in the second.
      # Only a match that survives stripping both is an invocation.
      if (line ~ rx) {
        stripped = line
        gsub(/`[^`]*`/, "", stripped)
        gsub(sq "[^" sq "]*" sq, "", stripped)
        gsub(/"[^"]*"/, "", stripped)
        if (stripped !~ rx) next
      }
      lines[++count] = line
    }
    END {
      for (i = 1; i <= count; i++) {
        if (lines[i] !~ rx) continue
        joined = lines[i]
        j = i
        while (j <= count && lines[j] ~ /\\[[:space:]]*$/) {
          j++
          if (j <= count) {
            line = lines[j]
            sub(/\\[[:space:]]*$/, "", joined)
            joined = joined " " line
          }
        }
        sub(/^[[:space:]]+/, "", joined)
        print joined
      }
    }
  ' "$(awk_path "${file}")"
}

failed=0
for f in "${paths[@]}"; do
  [[ -f ${f} ]] || continue
  case "${f}" in
  */scripts/check-cosign-identity-pinned.sh | scripts/check-cosign-identity-pinned.sh)
    continue
    ;;
  esac
  # Capture before consuming so an awk failure fails the lint loudly
  # instead of scoring the file clean. No input reaching here can
  # actually trip it: the `-f` guard above admits only regular files,
  # so the directory-for-a-file shape that makes awk exit non-zero is
  # filtered out before extraction. The guard stays because the
  # enumeration and the extractor are free to change independently.
  if ! invocations="$(extract_invocations "${f}")"; then
    printf 'cosign-identity-pinned: extract_invocations failed for %s\n' "${f}" >&2
    exit 2
  fi
  while IFS= read -r invocation; do
    [[ -z ${invocation} ]] && continue
    has_identity=0
    has_issuer=0
    if [[ ${invocation} == *"--certificate-identity"* ]]; then
      has_identity=1
    fi
    if [[ ${invocation} == *"--certificate-oidc-issuer"* ]]; then
      has_issuer=1
    fi
    if ((has_identity == 1 && has_issuer == 1)); then
      continue
    fi
    missing=()
    ((has_identity == 0)) && missing+=("--certificate-identity[-regexp]")
    ((has_issuer == 0)) && missing+=("--certificate-oidc-issuer")
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: `cosign verify*` missing: %s; got: %s\n' \
      "${f}" "${missing[*]}" "${invocation}" >&2
    failed=$((failed + 1))
  done <<<"${invocations}"
done

if ((failed > 0)); then
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf '%d `cosign verify*` invocation(s) missing identity/issuer pin\n' "${failed}" >&2
  exit 1
fi
exit 0
