#!/usr/bin/env bash
# scripts/check-actionlint-runner-labels-needed.sh
#
# @description Canary: assert every runner label allowlisted in
# `.github/actionlint.yaml` is still one actionlint rejects on its own.
# Lints a generated one-job workflow per label with an empty config, so
# the repo allowlist is out of play; a label actionlint no longer flags
# as unknown is a dead allowlist entry, and the canary names it for
# removal.
#
# If this script fails, actionlint has learned a hosted runner label
# this repo allowlists. Remove that label from `.github/actionlint.yaml`
# (and the file once it lists none, together with this canary). See
# docs/development/linting.md#runner-label-allowlist.
#
# A label written as an alias is read as its anchored text, as
# actionlint reads it; a label that still holds an alias after sixteen
# resolving passes is refused with exit 2.
#
# Env overrides (test-only):
#   ACTIONLINT_CONFIG_OVERRIDE — alternate config path
#
# Exits 0 when every allowlisted label is still needed, 1 when the
# canary fires (actionlint accepts an allowlisted label unaided), 2 when
# the canary could not run at all: actionlint or yq is absent from PATH,
# the config is missing, unparsable or lists no label, a label still
# holds an alias after resolving, or actionlint itself failed. A canary
# that never ran says nothing about the allowlist, so it must not borrow
# the failure code.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
# shellcheck source=scripts/lib/repo.sh
source "${_lib_dir}/lib/repo.sh"
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
install_err_trap

require_tool actionlint
require_tool yq

repo_root="$(repo_toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly DEFAULT_CONFIG="${REPO_ROOT}/.github/actionlint.yaml"
readonly CONFIG="${ACTIONLINT_CONFIG_OVERRIDE:-${DEFAULT_CONFIG}}"
readonly RUNBOOK="docs/development/linting.md#runner-label-allowlist"

if [[ ! -f ${CONFIG} ]]; then
  printf 'ERROR: config not found: %s\n' "${CONFIG}" >&2
  exit 2
fi

# actionlint reads a label written as an alias as its anchored text, so
# each label is read through its alias; `.[]` already follows a list
# written as one. One `explode` pass resolves one level of an alias
# chain. A scalar label resolves in one, since an anchor cannot sit on an
# alias, but a label that is itself a collection can nest an alias inside
# the text an alias stands for, so each goes through sixteen passes, as
# `ON_NODE` in scripts/check-workflow-on-branches.sh resolves `on:`. A
# label still holding an alias after them has no text to probe.
# shellcheck disable=SC2016 # yq program literal; its $ names are yq variables
readonly LABELS='.self-hosted-runner.labels // [] | .[] | (. as $n | [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16][] as $i ireduce ($n; explode(.)))'
label_aliases=""
if ! label_aliases="$(yq "[${LABELS} | ... | select(kind == \"alias\")] | length" "${CONFIG}")"; then
  printf 'ERROR: cannot read self-hosted-runner.labels from %s\n' "${CONFIG}" >&2
  exit 2
fi
if [[ ${label_aliases} != 0 ]]; then
  printf 'ERROR: %s: self-hosted-runner.labels still holds a YAML alias after resolving; cannot read it\n' "${CONFIG}" >&2
  exit 2
fi
labels_raw=""
if ! labels_raw="$(yq "${LABELS}" "${CONFIG}")"; then
  printf 'ERROR: cannot read self-hosted-runner.labels from %s\n' "${CONFIG}" >&2
  exit 2
fi
labels=()
while IFS= read -r label; do
  [[ -n ${label} ]] && labels+=("${label}")
done <<<"${labels_raw}"

# An allowlist with no label leaves nothing to probe. Exiting 0 there
# would let the canary pass forever over an empty file, so the empty
# file and this canary are removed together instead.
if [[ ${#labels[@]} -eq 0 ]]; then
  printf 'ERROR: %s lists no self-hosted-runner label; remove it and this canary\n' \
    "${CONFIG}" >&2
  exit 2
fi

empty_config="$(make_temp)"
workflow="$(make_temp)"
output_file="$(make_temp)"
trap 'rm -f -- "${empty_config}" "${workflow}" "${output_file}"' EXIT

stale=()
for label in "${labels[@]}"; do
  printf 'on: push\npermissions: {}\njobs:\n  probe:\n    runs-on: %s\n    steps:\n      - run: "true"\n' \
    "${label}" >"${workflow}"
  rc=0
  actionlint -config-file "${empty_config}" "${workflow}" >"${output_file}" 2>&1 || rc=$?
  # actionlint exits 0 with no problem, 1 with problems, and 2 or 3 when
  # it could not lint at all.
  case "${rc}" in
  0) stale+=("${label}") ;;
  1)
    if ! grep --quiet --fixed-strings -- "label \"${label}\" is unknown" "${output_file}"; then
      printf 'ERROR: actionlint reported problems but not an unknown label "%s"\n' "${label}" >&2
      cat -- "${output_file}" >&2
      exit 2
    fi
    ;;
  *)
    printf 'ERROR: actionlint could not lint the probe for "%s" (exit %d)\n' "${label}" "${rc}" >&2
    cat -- "${output_file}" >&2
    exit 2
    ;;
  esac
done

if [[ ${#stale[@]} -eq 0 ]]; then
  exit 0
fi

for label in "${stale[@]}"; do
  printf 'FAIL: actionlint now accepts runner label "%s" without the allowlist\n' "${label}" >&2
done
printf 'Remove those labels from %s. See %s.\n' "${CONFIG}" "${RUNBOOK}" >&2
exit 1
