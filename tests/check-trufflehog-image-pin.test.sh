#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-trufflehog-image-pin.sh"
readonly SHA='0123456789abcdef0123456789abcdef01234567'
readonly DIGEST='sha256:00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'
readonly OTHER_DIGEST='sha256:ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100'

# @description Scan one file written to a temp dir at run time and
# compare the whole of stderr, so no workflow-shaped fixture is a tracked
# file a formatter or workflow linter reads.
# @arg $1 file name, which is also the scenario's label
# @arg $2 file body  @arg $3 expected exit status
# @arg $4 expected stderr, with DIR standing for the temp dir
function expect_body() {
  local -r name="$1" body="$2" want_exit="$3"
  local dir got_exit=0 got_stderr want
  dir="$(mktemp --directory)"
  printf '%s' "${body}" >"${dir}/${name}"
  want="${4//DIR/${dir}}"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s, and stderr %q\n  got: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}

# @description A workflow body with one TruffleHog step.
# @arg $1 the step's `uses:` line value (after `uses: `)
# @arg $2 the `with:` block lines, already indented, or empty
function one_step() {
  printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: %s\n%s' "$1" "$2"
}

# @description The stderr one mismatch finding produces.
# @arg $1 file name  @arg $2 pinned version  @arg $3 the version input as printed (%q)
function mismatch() {
  printf 'DIR/%s: trufflesecurity/trufflehog pinned at v%s runs image version %s; want %s@sha256:<digest>\n1 trufflehog image pin finding(s)' "$1" "$2" "$3" "$2"
}

readonly PIN="trufflesecurity/trufflehog@${SHA} # v3.99.4"
readonly GOOD_WITH="        with:
          version: 3.99.4@${DIGEST}
"

# The pinned form passes: the image tag equals the pin comment's
# version and carries a digest.
expect_body matching.yml "$(one_step "${PIN}" "${GOOD_WITH}")" 0 ''

# A workflow with no TruffleHog step has nothing to check.
expect_body no-trufflehog.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@'"${SHA}"' # v7.0.1\n' 0 ''

# Each way the image can drift from the action pin is a finding.
expect_body tag-mismatch.yml "$(one_step "${PIN}" "        with:
          version: 3.99.3@${DIGEST}
")" 1 "$(mismatch tag-mismatch.yml 3.99.4 "3.99.3@${DIGEST}")"
expect_body version-missing.yml "$(one_step "${PIN}" '')" 1 \
  "$(mismatch version-missing.yml 3.99.4 "''")"
expect_body version-latest.yml "$(one_step "${PIN}" '        with:
          version: latest
')" 1 "$(mismatch version-latest.yml 3.99.4 latest)"
expect_body tag-without-digest.yml "$(one_step "${PIN}" '        with:
          version: 3.99.4
')" 1 "$(mismatch tag-without-digest.yml 3.99.4 3.99.4)"
expect_body digest-without-tag.yml "$(one_step "${PIN}" "        with:
          version: ${DIGEST}
")" 1 "$(mismatch digest-without-tag.yml 3.99.4 "${DIGEST}")"
expect_body short-digest.yml "$(one_step "${PIN}" "        with:
          version: 3.99.4@${DIGEST:0:20}
")" 1 "$(mismatch short-digest.yml 3.99.4 "3.99.4@${DIGEST:0:20}")"

# The action's owner and repository resolve in any letter case, so a
# re-cased reference is still checked.
expect_body recased.yml "$(one_step "TruffleSecurity/TruffleHog@${SHA} # v3.99.4" '')" 1 \
  "$(mismatch recased.yml 3.99.4 "''")"

# Without a `# vX.Y.Z` comment there is no version to compare against.
expect_body comment-missing.yml "$(one_step "trufflesecurity/trufflehog@${SHA}" "${GOOD_WITH}")" 1 \
  $'DIR/comment-missing.yml: trufflesecurity/trufflehog step has no # vX.Y.Z pin comment, so its image version cannot be checked\n1 trufflehog image pin finding(s)'

# Two steps: only the one that drifted is reported.
expect_body two-steps.yml "$(one_step "${PIN}" "${GOOD_WITH}")
      - uses: ${PIN}
        with:
          version: 3.99.4@${OTHER_DIGEST:0:30}
" 1 "$(mismatch two-steps.yml 3.99.4 "3.99.4@${OTHER_DIGEST:0:30}")"

# A version written as an alias is read as its anchored text.
expect_body aliased-version.yml "x-image: &img 3.99.4@${DIGEST}
$(one_step "${PIN}" '        with:
          version: *img
')" 0 ''

# A file yq cannot parse cannot be verified, which is a finding.
expect_body unparsable.yml $'on: push\njobs:\n  a: [\n' 1 \
  $'DIR/unparsable.yml: yq parse failed; trufflehog image pins cannot be verified\n1 trufflehog image pin finding(s)'

# An empty scan set and a missing yq are could-not-run, exit 2.
empty_dir="$(mktemp --directory)"
empty_exit=0
empty_err="$(WORKFLOWS_DIR_OVERRIDE="${empty_dir}" "${SCRIPT}" 2>&1 >/dev/null)" || empty_exit=$?
rm --recursive --force -- "${empty_dir}"
if [[ ${empty_exit} != 2 || ${empty_err} != *'matched 0 files'* ]]; then
  printf 'FAIL empty-scan: exit %s (want 2)\n  stderr: %s\n' "${empty_exit}" "${empty_err}" >&2
  exit 1
fi
printf 'OK   empty scan set exits tooling code\n'

bash_abs="$(command -v bash)"
noyq_exit=0
noyq_err="$(env --unset=BASH_ENV PATH=/nonexistent \
  "${bash_abs}" "${SCRIPT}" 2>&1 >/dev/null)" || noyq_exit=$?
if [[ ${noyq_exit} != 2 || ${noyq_err} != *'yq'* ]]; then
  printf 'FAIL yq-absent: exit %s (want 2)\n  stderr: %s\n' "${noyq_exit}" "${noyq_err}" >&2
  exit 1
fi
printf 'OK   yq absent exits tooling code\n'

printf 'all tests passed\n'
