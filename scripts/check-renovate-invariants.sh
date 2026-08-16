#!/usr/bin/env bash
# scripts/check-renovate-invariants.sh
#
# @description Lint: renovate.json carries the security-critical
# invariants — pinGitHubActionDigests, minimumReleaseAge, no top-level
# automerge, per-manager pinDigests for github-actions.

# Assert renovate.json carries the security-critical
# invariants:
#   1. extends includes "helpers:pinGitHubActionDigests"
#   2. minimumReleaseAge is set (any non-empty string)
#   3. automerge is NOT at top level (must be per-manager in packageRules)
#   4. github-actions packageRule sets pinDigests: true
#
# Honors RENOVATE_JSON_OVERRIDE for fixture testing.
# Exits 0 on intact invariants, 1 on drift, 2 when the config cannot be
# read at all — absent, unreadable, or not a regular file — or the
# payload read fails shape validation. No invariant was read in any of
# those cases, so reporting one as dropped would send a maintainer after
# a setting nobody touched.

set -Eeuo pipefail
IFS=$'\n\t'

_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/payload.sh
source "${_lib_dir}/lib/payload.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
readonly REPO_ROOT
readonly DEFAULT_PATH="${REPO_ROOT}/renovate.json"
readonly path="${RENOVATE_JSON_OVERRIDE:-${DEFAULT_PATH}}"

payload_source_into payload_source RENOVATE_JSON_OVERRIDE 'renovate.json'
readonly payload_source

# read_json_payload_into fills a nameref, so it must run in this shell —
# never inside `$(...)`, where its `exit 2` would be trapped in a
# subshell and this script would carry on with an empty renovate_payload.
read_json_payload_into renovate_payload "${path}" "${payload_source}" \
  'renovate invariants'
readonly renovate_payload

# One shape gate in front of every read. Each check below is written
# `if ! jq -e … 2>/dev/null`, so without this gate a jq parse error is
# inverted into the first check's drift branch and reported as a dropped
# invariant with jq's own diagnostic discarded.
#
# The program asserts types only, never presence. An absent `extends`,
# `minimumReleaseAge` or `packageRules` means the invariant genuinely is
# not set, which is the posture verdict this lint exists to render (exit
# 1). A wrong-typed one means the lint cannot judge the posture at all
# (exit 2); `renovate-config-validator` renders the verdict on a
# schema-invalid config in its own job. An explicit `null` is treated as
# absent so it keeps reaching the drift checks below.
#
# The subject is passed because the source kind alone does not identify this
# payload: a sibling lint reads the same renovate.json through the same
# override variable and the same repo-relative name to check a different set
# of invariants.
require_json_payload "${payload_source}" "${renovate_payload}" '
  if type != "object" then "payload is \(type), want object"
  elif (.extends != null) and ((.extends | type) != "array") then ".extends is \(.extends | type), want array"
  elif (.minimumReleaseAge != null) and ((.minimumReleaseAge | type) != "string") then ".minimumReleaseAge is \(.minimumReleaseAge | type), want string"
  elif (.packageRules != null) and ((.packageRules | type) != "array") then ".packageRules is \(.packageRules | type), want array"
  elif (.packageRules != null) and (any(.packageRules[]; type != "object")) then "a packageRules entry is not an object"
  else empty
  end' 'renovate invariants'

# 1. extends includes helpers:pinGitHubActionDigests
if ! jq -e '.extends | type == "array" and any(. == "helpers:pinGitHubActionDigests")' "${path}" >/dev/null 2>&1; then
  printf 'extends does not include helpers:pinGitHubActionDigests\n' >&2
  exit 1
fi

# 2. minimumReleaseAge set (non-empty string)
if ! jq -e '.minimumReleaseAge | type == "string" and length > 0' "${path}" >/dev/null 2>&1; then
  printf 'minimumReleaseAge not set (expected e.g. "7 days")\n' >&2
  exit 1
fi

# 3. no top-level automerge
if jq -e 'has("automerge")' "${path}" >/dev/null 2>&1; then
  printf 'top-level automerge present - move to per-manager packageRules\n' >&2
  exit 1
fi

# 4. github-actions packageRule sets pinDigests
if ! jq -e '
  .packageRules // [] |
  any(
    ((.matchManagers // []) | any(. == "github-actions"))
    and
    (.pinDigests == true)
  )
' "${path}" >/dev/null 2>&1; then
  printf 'github-actions packageRule missing pinDigests: true\n' >&2
  exit 1
fi

exit 0
