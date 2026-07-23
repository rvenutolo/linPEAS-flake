#!/usr/bin/env bash
# tests/linpeas-pin-assert.test.sh
#
# Verifies the pin-shape assertions in nix/linpeas.nix. A pin whose version is
# not the tag path-segment embedded in its url must fail eval, so a hand-edited
# or corrupted pin cannot declare one version while fetching another release's
# artifact. Forces `.pin.version` only (not the derivation), so a dummy `pkgs`
# suffices and no build/network is needed.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly LINPEAS_NIX="${REPO_ROOT}/nix/linpeas.nix"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Eval (import linpeas.nix { pkgs = {}; pinFile = $1 }).pin.version.
# Returns the eval exit code; output is discarded.
# @arg $1 pin json path
function eval_pin() {
  local -r pinfile="$1"
  nix eval --impure --expr \
    "(import ${LINPEAS_NIX} { pkgs = {}; pinFile = ${pinfile}; }).pin.version" \
    >/dev/null 2>&1
}

function main() {
  local dir good bad
  dir="$(mktemp --directory)"
  good="${dir}/good.json"
  bad="${dir}/bad.json"
  # Version is the tag path-segment in url -> passes all three asserts.
  printf '%s\n' \
    '{"version":"20260715-81d3c7f8","url":"https://github.com/peass-ng/PEASS-ng/releases/download/20260715-81d3c7f8/linpeas.sh","hash":"sha256-0000000000000000000000000000000000000000000="}' \
    >"${good}"
  # Version is well-formed and url has the right prefix, but version is not the
  # tag in url -> must trip the version-in-url assertion.
  printf '%s\n' \
    '{"version":"19990101-deadbee","url":"https://github.com/peass-ng/PEASS-ng/releases/download/20260715-81d3c7f8/linpeas.sh","hash":"sha256-0000000000000000000000000000000000000000000="}' \
    >"${bad}"

  if eval_pin "${good}"; then
    pass 'coherent pin (version == tag in url) evaluates'
  else
    fail 'coherent pin unexpectedly failed to evaluate'
  fi

  if eval_pin "${bad}"; then
    fail 'mismatched pin (version not in url) evaluated but must fail'
  else
    pass 'mismatched pin rejected by the version-in-url assertion'
  fi

  rm --recursive --force -- "${dir}"

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
