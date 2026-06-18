#!/usr/bin/env bash
# Test harness for collect-ground-truth.sh sweeps. Run from anywhere.
set -Eeuo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTOR="${HERE}/collect-ground-truth.sh"
# shellcheck disable=SC2034  # used by Tasks 2 and 3 fixture checks
REAL_REPO="$(git -C "${HERE}" rev-parse --show-toplevel)"
fails=0
check() { # $1=label $2=condition-already-evaluated(0/1)
  if [[ $2 -eq 0 ]]; then printf 'PASS: %s\n' "$1"; else
    printf 'FAIL: %s\n' "$1"
    fails=$((fails + 1))
  fi
}

# --- sourcing must not auto-run main ---
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
src_out="$(
  source "${COLLECTOR}" 2>&1
  printf '__SOURCED__'
)"
case "${src_out}" in
*"===== FLAKE OUTPUTS"*) check "sourcing does not auto-run main" 1 ;;
*) check "sourcing does not auto-run main" 0 ;;
esac

# (further fixture-based checks added in Tasks 2 and 3)

# --- ephemeral-token fixture ---
fx="$(mktemp -d)"
(
  cd "${fx}"
  git init -q && git config user.email t@t && git config user.name t
  mkdir -p docs
  cp "${REAL_REPO}/lychee.toml" .
  printf '# Doc\n\nPhase 3 work remains.\nTracking #388 here.\nclassDef x fill:#c8e6c9,stroke:#2e7d32\nEntity &#123; literal.\nsee [toc](#1-delete-the-thing).\nEvery call passes X-GitHub-Api-Version: 2022-11-28 header.\nUses SHA-256 digest.\n' >docs/eph.md
  printf '# Changelog\n\n- #999 shipped 2024-01-01\n- Phase 9 cleanup\n' >CHANGELOG.md
  mkdir -p .claude
  printf 'Phase 8 work\n' >.claude/x.md
  git add -A && git commit -qm init
)
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
eph="$(cd "${fx}" && source "${COLLECTOR}" && sweep_ephemeral_tokens)"
case "${eph}" in *"(planning-label)"*"Phase 3"*) check "flags Phase 3" 0 ;; *) check "flags Phase 3" 1 ;; esac
case "${eph}" in *"(pr-ref)"*"#388"*) check "flags #388" 0 ;; *) check "flags #388" 1 ;; esac
case "${eph}" in *"c8e6c9"*) check "suppresses hex color" 1 ;; *) check "suppresses hex color" 0 ;; esac
case "${eph}" in *"&#123"*) check "suppresses HTML entity" 1 ;; *) check "suppresses HTML entity" 0 ;; esac
case "${eph}" in *"#1-delete"*) check "suppresses anchor target" 1 ;; *) check "suppresses anchor target" 0 ;; esac
case "${eph}" in *"X-GitHub-Api-Version"*) check "suppresses api-version literal" 1 ;; *) check "suppresses api-version literal" 0 ;; esac
case "${eph}" in *"SHA-256"*) check "suppresses SHA-256" 1 ;; *) check "suppresses SHA-256" 0 ;; esac
case "${eph}" in *"#999"*) check "exempts CHANGELOG pr-ref" 1 ;; *) check "exempts CHANGELOG pr-ref" 0 ;; esac
case "${eph}" in *"2024-01-01"*) check "exempts CHANGELOG date" 1 ;; *) check "exempts CHANGELOG date" 0 ;; esac
case "${eph}" in *"Phase 9"*) check "fully exempts CHANGELOG planning-label" 1 ;; *) check "fully exempts CHANGELOG planning-label" 0 ;; esac
case "${eph}" in *"Phase 8"*) check "excludes .claude/ from sweep" 1 ;; *) check "excludes .claude/ from sweep" 0 ;; esac
rm -rf "${fx}"

if [[ ${fails} -ne 0 ]]; then
  printf '\n%d FAILED\n' "${fails}"
  exit 1
fi
printf '\nALL PASSED\n'
