#!/usr/bin/env bash
# scripts/classify-pin-ref.sh
#
# @description Classify one SHA-pinned action ref for
# ratchet-pin-audit: given the pinned SHA and the tag's resolved git
# objects, print `current`, `drift`, or `skip-floating-major`. Pure
# and side-effect free so the drift decision — including the
# attack-detection branch — is unit-testable without contacting the
# GitHub API.

# A pin is `current` when it equals the tag-object SHA OR the commit
# the tag dereferences to; a genuine tag force-move changes both, so a
# pin matching neither is `drift`. Floating-major tags (`vN`) retarget
# by design and cannot be judged by a tag-vs-pin comparison, so they
# are `skip-floating-major` — their integrity rests on the immutable
# digest pin plus Renovate and the PR-time digest-provenance gate
# (scripts/check-pin-digest-provenance.sh). See
# docs/architecture/pin-convention.md.
#
# Exit codes:
#   0  classified: `current`, `drift`, or `skip-floating-major` on
#      stdout. Drift is a verdict rather than a failure, so it exits 0
#      like the other two and the caller decides what it means.
#   2  it could not classify: the argument count is not five

set -Eeuo pipefail
IFS=$'\n\t'

if [[ $# -ne 5 ]]; then
  printf 'usage: %s <tag> <pinned> <ref_object_sha> <ref_object_type> <deref_commit_sha>\n' \
    "${0##*/}" >&2
  exit 2
fi

readonly tag="$1" pinned="$2" ref_object_sha="$3" ref_object_type="$4" deref_commit_sha="$5"

# Floating-major tags retarget on every release; the audit cannot
# distinguish a benign move from an attack. Mirror of the early skip
# in .github/workflows/ratchet-pin-audit.yml.
if [[ ${tag} =~ ^v[0-9]+$ ]]; then
  printf 'skip-floating-major\n'
  exit 0
fi

if [[ ${pinned} == "${ref_object_sha}" ]]; then
  printf 'current\n'
  exit 0
fi

if [[ ${ref_object_type} == tag && ${pinned} == "${deref_commit_sha}" ]]; then
  printf 'current\n'
  exit 0
fi

printf 'drift\n'
exit 0
