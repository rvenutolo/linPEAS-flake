#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-trufflehog-image-pin.sh"
readonly SHA='0123456789abcdef0123456789abcdef01234567'
readonly DIGEST='sha256:00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'
# The expression every TruffleHog step must pass, kept out of a double-
# quoted string so the shell never reads its braces.
# shellcheck disable=SC2016 # a GitHub Actions expression, not a shell one
readonly EXPR='${{ steps.trufflehog-image.outputs.version }}'
# An expression naming another step's output.
# shellcheck disable=SC2016 # a GitHub Actions expression, not a shell one
readonly OTHER_EXPR='${{ steps.image.outputs.version }}'
readonly GOOD_IMAGE="3.99.4@${DIGEST}"$'\n'
# The image-file content a scenario passes to leave the file out.
readonly ABSENT='<absent>'

# @description Scan one workflow written to a temp dir at run time, with
# the image file beside it, and compare the whole of stderr, so no
# workflow-shaped fixture is a tracked file a formatter or workflow
# linter reads.
# @arg $1 workflow file name, which is also the scenario's label
# @arg $2 workflow body  @arg $3 image file content, or ABSENT
# @arg $4 expected exit status
# @arg $5 expected stderr, with DIR standing for the temp dir
function expect_body() {
  local -r name="$1" body="$2" image="$3" want_exit="$4"
  local dir got_exit=0 got_stderr want
  dir="$(mktemp --directory)"
  mkdir -- "${dir}/wf"
  printf '%s' "${body}" >"${dir}/wf/${name}"
  if [[ ${image} != "${ABSENT}" ]]; then
    printf '%s' "${image}" >"${dir}/image"
  fi
  want="${5//DIR/${dir}}"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}/wf" \
    TRUFFLEHOG_IMAGE_FILE_OVERRIDE="${dir}/image" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
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

# @description The `with:` block passing a given version value.
# @arg $1 the version value as written in YAML
function with_version() {
  printf '        with:\n          version: %s\n' "$1"
}

# @description The stderr one finding produces, with its count line.
# @arg $1 the finding line
function one_finding() {
  printf '%s\n1 trufflehog image pin finding(s)' "$1"
}

# @description The finding a step passing the wrong version produces.
# @arg $1 workflow file name  @arg $2 the version it passes
function bad_version() {
  one_finding "DIR/wf/$1: trufflesecurity/trufflehog step passes version $(printf '%q' "$2"); want ${EXPR}"
}

# @description The finding a malformed image file produces.
# @arg $1 the file's content
function bad_shape() {
  one_finding "DIR/image: holds $(printf '%q' "$1"); want one line X.Y.Z@sha256:<64 hex>"
}

readonly PIN="trufflesecurity/trufflehog@${SHA} # v3.99.4"
GOOD_WITH="$(with_version "'${EXPR}'")"$'\n'
readonly GOOD_WITH

# The pinned form passes: the step reads the image file through the
# expression, and the file names the pin comment's release by digest.
expect_body matching.yml "$(one_step "${PIN}" "${GOOD_WITH}")" "${GOOD_IMAGE}" 0 ''

# A workflow with no TruffleHog step has nothing to check, and the image
# file is not read.
expect_body no-trufflehog.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@'"${SHA}"' # v7.0.1\n' \
  "${ABSENT}" 0 ''

# The step must take its version from the image-file step, not inline and
# not by default.
expect_body inline-version.yml "$(one_step "${PIN}" "$(with_version "3.99.4@${DIGEST}")"$'\n')" "${GOOD_IMAGE}" 1 \
  "$(bad_version inline-version.yml "3.99.4@${DIGEST}")"
expect_body version-missing.yml "$(one_step "${PIN}" '')" "${GOOD_IMAGE}" 1 \
  "$(bad_version version-missing.yml '')"
expect_body other-step-id.yml "$(one_step "${PIN}" "$(with_version "'${OTHER_EXPR}'")"$'\n')" "${GOOD_IMAGE}" 1 \
  "$(bad_version other-step-id.yml "${OTHER_EXPR}")"

# Each way the image file can drift from the action pin is a finding.
expect_body tag-mismatch.yml "$(one_step "${PIN}" "${GOOD_WITH}")" "3.99.3@${DIGEST}"$'\n' 1 \
  "$(one_finding 'DIR/wf/tag-mismatch.yml: trufflesecurity/trufflehog pinned at v3.99.4, but DIR/image names release 3.99.3')"
expect_body image-absent.yml "$(one_step "${PIN}" "${GOOD_WITH}")" "${ABSENT}" 1 \
  "$(one_finding 'DIR/image: missing or unreadable; the trufflehog-image step reads the image ref from it')"
expect_body tag-without-digest.yml "$(one_step "${PIN}" "${GOOD_WITH}")" $'3.99.4\n' 1 \
  "$(bad_shape $'3.99.4\n')"
expect_body short-digest.yml "$(one_step "${PIN}" "${GOOD_WITH}")" "3.99.4@${DIGEST:0:20}"$'\n' 1 \
  "$(bad_shape "3.99.4@${DIGEST:0:20}"$'\n')"
expect_body latest.yml "$(one_step "${PIN}" "${GOOD_WITH}")" $'latest\n' 1 \
  "$(bad_shape $'latest\n')"
expect_body no-final-newline.yml "$(one_step "${PIN}" "${GOOD_WITH}")" "3.99.4@${DIGEST}" 1 \
  "$(bad_shape "3.99.4@${DIGEST}")"
expect_body second-line.yml "$(one_step "${PIN}" "${GOOD_WITH}")" "${GOOD_IMAGE}${GOOD_IMAGE}" 1 \
  "$(bad_shape "${GOOD_IMAGE}${GOOD_IMAGE}")"
expect_body uppercase-digest.yml "$(one_step "${PIN}" "${GOOD_WITH}")" "3.99.4@${DIGEST^^}"$'\n' 1 \
  "$(bad_shape "3.99.4@${DIGEST^^}"$'\n')"

# The action's owner and repository resolve in any letter case, so a
# re-cased reference is still checked.
expect_body recased.yml "$(one_step "TruffleSecurity/TruffleHog@${SHA} # v3.99.4" '')" "${GOOD_IMAGE}" 1 \
  "$(bad_version recased.yml '')"

# Without a `# vX.Y.Z` comment there is no version to compare against.
expect_body comment-missing.yml "$(one_step "trufflesecurity/trufflehog@${SHA}" "${GOOD_WITH}")" "${GOOD_IMAGE}" 1 \
  "$(one_finding 'DIR/wf/comment-missing.yml: trufflesecurity/trufflehog step has no # vX.Y.Z pin comment, so its image version cannot be checked')"

# Two steps on different pins: the one that disagrees with the file is
# reported, the other is not.
expect_body two-steps.yml "$(one_step "${PIN}" "${GOOD_WITH}")
      - uses: trufflesecurity/trufflehog@${SHA} # v3.99.5
${GOOD_WITH}" "${GOOD_IMAGE}" 1 \
  "$(one_finding 'DIR/wf/two-steps.yml: trufflesecurity/trufflehog pinned at v3.99.5, but DIR/image names release 3.99.4')"

# A version written as an alias is read as its anchored text.
expect_body aliased-version.yml "x-image: &img '${EXPR}'
$(one_step "${PIN}" "$(with_version '*img')"$'\n')" "${GOOD_IMAGE}" 0 ''

# A file yq cannot parse cannot be verified, which is a finding.
expect_body unparsable.yml $'on: push\njobs:\n  a: [\n' "${GOOD_IMAGE}" 1 \
  "$(one_finding 'DIR/wf/unparsable.yml: yq parse failed; trufflehog image pins cannot be verified')"

# The live tree passes: its step and image file are the pinned form.
live_exit=0
live_err="$(cd -- "${REPO_ROOT}" && "${SCRIPT}" 2>&1 >/dev/null)" || live_exit=$?
if [[ ${live_exit} != 0 ]]; then
  printf 'FAIL live-tree: exit %s (want 0)\n  stderr: %s\n' "${live_exit}" "${live_err}" >&2
  exit 1
fi
printf 'OK   live tree\n'

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
