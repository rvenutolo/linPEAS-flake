#!/usr/bin/env bash
# scripts/check-pre-commit-hooks-sha-parity.sh
#
# @description Lint: the SHA embedded in `flake.nix`'s
# `pre-commit-hooks` input URL matches `flake.lock`'s pinned
# `pre-commit-hooks.locked.rev`.

# Lint: assert the SHA embedded in `flake.nix`'s `pre-commit-hooks`
# input URL matches `flake.lock`'s pinned `pre-commit-hooks.locked.rev`.
#
# Why: the `pre-commit-hooks` input is unusual — it carries a SHA in
# the `inputs.url` literal (Renovate's `cachix/git-hooks.nix` custom
# manager bumps that SHA), separate from `flake.lock`'s `locked.rev`
# which only updates when `nix flake update --update-input
# pre-commit-hooks` runs. The `renovate-flake-lock-refresh` workflow
# auto-completes that lock refresh on Renovate PRs, but the same
# divergence can appear from any other source — a manual `flake.nix`
# edit without a corresponding `nix flake update`, a force-pushed
# branch, etc.
#
# This lint catches the divergence at PR time so the per-author
# convention "URL SHA == lock rev" is enforced explicitly.
#
# Exits 0 on match, 1 on drift. Fixture overrides honored for the
# test harness.
#
# Env overrides (test-only):
#   FLAKE_NIX_OVERRIDE  — path to flake.nix to read
#   FLAKE_LOCK_OVERRIDE — path to flake.lock to read

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
readonly REPO_ROOT
readonly FLAKE_NIX="${FLAKE_NIX_OVERRIDE:-${REPO_ROOT}/flake.nix}"
readonly FLAKE_LOCK="${FLAKE_LOCK_OVERRIDE:-${REPO_ROOT}/flake.lock}"

if [[ ! -f ${FLAKE_NIX} ]]; then
  printf 'flake.nix not found: %s\n' "${FLAKE_NIX}" >&2
  exit 1
fi
if [[ ! -f ${FLAKE_LOCK} ]]; then
  printf 'flake.lock not found: %s\n' "${FLAKE_LOCK}" >&2
  exit 1
fi

# Extract the SHA from the pre-commit-hooks input URL in flake.nix.
# Expected shape:
#   pre-commit-hooks = {
#     url = "github:cachix/git-hooks.nix/<40-hex>";
#     ...
#   };
url_sha="$({ grep --extended-regexp --only-matching \
  'github:cachix/git-hooks\.nix/[0-9a-f]{7,40}' "${FLAKE_NIX}" || true; } |
  head -n 1 |
  sed -E 's|^github:cachix/git-hooks\.nix/||')"

if [[ -z ${url_sha} ]]; then
  printf 'no github:cachix/git-hooks.nix/<sha> URL found in %s\n' "${FLAKE_NIX}" >&2
  exit 1
fi
if [[ ! ${url_sha} =~ ^[0-9a-f]{7,40}$ ]]; then
  printf 'extracted URL SHA has unexpected shape: %q\n' "${url_sha}" >&2
  exit 1
fi

# Extract the locked rev for pre-commit-hooks from flake.lock.
lock_rev="$(jq --raw-output \
  '.nodes["pre-commit-hooks"].locked.rev // empty' "${FLAKE_LOCK}")"

if [[ -z ${lock_rev} ]]; then
  printf 'no nodes["pre-commit-hooks"].locked.rev in %s\n' "${FLAKE_LOCK}" >&2
  exit 1
fi
if [[ ! ${lock_rev} =~ ^[0-9a-f]{40}$ ]]; then
  printf 'lock rev has unexpected shape: %q\n' "${lock_rev}" >&2
  exit 1
fi

# Compare as prefix-or-equal: the URL SHA may be a short prefix of the
# 40-hex lock rev (`github:owner/repo/<short>` is valid). Mismatch is
# always a drift, regardless of length.
if [[ ${lock_rev} != "${url_sha}"* ]]; then
  printf 'SHA drift between flake.nix and flake.lock for pre-commit-hooks:\n' >&2
  printf '  flake.nix URL SHA: %s\n' "${url_sha}" >&2
  printf '  flake.lock rev:    %s\n' "${lock_rev}" >&2
  # shellcheck disable=SC2016 # literal backtick prose for human reader
  printf 'Run `nix flake update --update-input pre-commit-hooks` to refresh the lock.\n' >&2
  exit 1
fi

printf 'pre-commit-hooks SHA parity ok (URL=%s, lock=%s)\n' \
  "${url_sha}" "${lock_rev}"
