#!/usr/bin/env bash
# scripts/measure-devshell-entry.sh
#
# @description THROWAWAY measurement harness. Splits the `nix develop`
# devShell entry cost into eval / realize / shellHook+activation buckets
# on a real CI runner, appending a markdown table to $GITHUB_STEP_SUMMARY.
# Not for merge — exists only on the measurement branch.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SHELL_ATTR=".#devShells.x86_64-linux.default"

# Milliseconds elapsed while running "$@" (stderr of the command passes through).
function time_ms() {
  local start end
  start="$(date +%s%N)"
  "$@" >/dev/null 2>&1 || true
  end="$(date +%s%N)"
  printf '%s' "$(((end - start) / 1000000))"
}

function main() {
  # 1. Cold eval-cache: pure evaluation, no realize, no shellHook.
  local t_eval
  t_eval="$(time_ms nix eval --raw "${SHELL_ATTR}.drvPath")"

  # 2. Cold store: full entry (eval now cached) + realize + hook + activation.
  local t_cold_total
  t_cold_total="$(time_ms nix develop --command true)"

  # 3. Warm store, no shellHook executed: eval(cached) + activation.
  local t_warm_printenv
  t_warm_printenv="$(time_ms nix print-dev-env "${SHELL_ATTR}")"

  # 4. Warm store, full develop: eval(cached) + hook + activation (realize ~0).
  local t_warm_develop
  t_warm_develop="$(time_ms nix develop --command true)"

  # Derived buckets (ms).
  local realize hook activation
  realize=$((t_cold_total - t_warm_develop))
  hook=$((t_warm_develop - t_warm_printenv))
  activation=$((t_warm_printenv - t_eval))

  {
    printf '| bucket | ms |\n'
    printf '| --- | --- |\n'
    printf '| eval (cold) | %s |\n' "${t_eval}"
    printf '| realize | %s |\n' "${realize}"
    printf '| shellHook | %s |\n' "${hook}"
    printf '| activation | %s |\n' "${activation}"
    printf '| cold-total (sanity) | %s |\n' "${t_cold_total}"
  } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
}

main "$@"
