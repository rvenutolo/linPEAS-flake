#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-uses-no-self-reference.sh"
readonly SHA='0123456789abcdef0123456789abcdef01234567'

# @description Scan one file written to a temp dir at run time and
# compare the whole of stderr, so no workflow-shaped fixture is a tracked
# file a formatter or workflow linter reads.
# @arg $1 file name, which is also the scenario's label
# @arg $2 file body  @arg $3 expected exit status
# @arg $4 expected stderr, with DIR standing for the temp dir
# @arg $5 GITHUB_REPOSITORY for the run, or empty for the script's default
function expect_body() {
  local -r name="$1" body="$2" want_exit="$3" repo="${5:-}"
  local dir got_exit=0 got_stderr want
  dir="$(mktemp --directory)"
  [[ ${name} != */* ]] || mkdir --parents -- "${dir}/${name%/*}"
  printf '%s' "${body}" >"${dir}/${name}"
  want="${4//DIR/${dir}}"
  if [[ -n ${repo} ]]; then
    got_stderr="$(GITHUB_REPOSITORY="${repo}" WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  else
    got_stderr="$(env --unset=GITHUB_REPOSITORY WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  fi
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s, and stderr %q\n  got: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}

# @description The two stderr lines one finding produces.
# @arg $1 file name  @arg $2 the reference as the lint prints it (%q)
# @arg $3 the slug
function one_finding() {
  printf 'DIR/%s: %s names this repository (%s); use the ./ path instead\n1 self-reference uses: finding(s)' "$1" "$2" "$3"
}

readonly SELF='rvenutolo/linPEAS-flake'

# The forms the repo's own workflows use pass: the `./` path, and a
# third-party action pinned by SHA.
expect_body clean.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: ./.github/actions/notify-workflow-result\n      - uses: actions/checkout@'"${SHA}"$'\n' 0 ''

# A step naming this repository's composite by slug is a finding, at a
# SHA as at a branch, and so is the repository's root action.
expect_body step-sha.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: '"${SELF}"$'/.github/actions/notify-workflow-result@'"${SHA}"$'\n' 1 \
  "$(one_finding step-sha.yml "${SELF}/.github/actions/notify-workflow-result@${SHA}" "${SELF}")"
expect_body step-branch.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: '"${SELF}"$'/.github/actions/setup-nix@main\n' 1 \
  "$(one_finding step-branch.yml "${SELF}/.github/actions/setup-nix@main" "${SELF}")"
expect_body root-action.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: '"${SELF}"$'@'"${SHA}"$'\n' 1 \
  "$(one_finding root-action.yml "${SELF}@${SHA}" "${SELF}")"

# A reusable workflow called by slug at job level is the same defect.
expect_body reusable.yml $'on: push\njobs:\n  a:\n    uses: '"${SELF}"$'/.github/workflows/pages.yml@'"${SHA}"$'\n' 1 \
  "$(one_finding reusable.yml "${SELF}/.github/workflows/pages.yml@${SHA}" "${SELF}")"

# GitHub resolves an owner and repository however they are cased.
expect_body mixed-case.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: RVENUTOLO/linpeas-FLAKE/.github/actions/x@'"${SHA}"$'\n' 1 \
  "$(one_finding mixed-case.yml "RVENUTOLO/linpeas-FLAKE/.github/actions/x@${SHA}" "${SELF}")"

# Other repositories pass: one whose name starts with this one's, a fork
# under another owner, a container image whose path holds the slug, and
# a name that folds to this one's only through a non-ASCII letter (the
# Kelvin sign), which names no repository GitHub would resolve to it.
expect_body prefix.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: '"${SELF}"$'2/.github/actions/x@'"${SHA}"$'\n' 0 ''
expect_body fork.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: someone/linPEAS-flake/.github/actions/x@'"${SHA}"$'\n' 0 ''
expect_body docker.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: docker://ghcr.io/'"${SELF}"$'/tool:1\n' 0 ''
expect_body kelvin.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: rvenutolo/linPEAS-fla\u212ae/.github/actions/x@'"${SHA}"$'\n' 0 ''

# A value or key written as a YAML alias is read as its anchored text.
expect_body value-alias.yml $'on: push\nx-u: &u '"${SELF}"$'/.github/actions/x@'"${SHA}"$'\njobs:\n  a:\n    steps:\n      - uses: *u\n' 1 \
  "$(one_finding value-alias.yml "${SELF}/.github/actions/x@${SHA}" "${SELF}")"
expect_body key-alias.yml $'on: push\nenv:\n  X: &k uses\njobs:\n  a:\n    steps:\n      - *k : '"${SELF}"$'/.github/actions/x@'"${SHA}"$'\n' 1 \
  "$(one_finding key-alias.yml "${SELF}/.github/actions/x@${SHA}" "${SELF}")"

# A composite action's steps, and a `.yaml` file, are scanned too.
expect_body x/action.yaml $'name: a\nruns:\n  using: composite\n  steps:\n    - uses: '"${SELF}"$'/.github/actions/y@'"${SHA}"$'\n' 1 \
  "$(one_finding x/action.yaml "${SELF}/.github/actions/y@${SHA}" "${SELF}")"

# The slug comes from GITHUB_REPOSITORY: under another repository the
# default slug is a foreign action, and that repository's own slug is
# the finding.
expect_body other-repo-default.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: '"${SELF}"$'/.github/actions/x@'"${SHA}"$'\n' 0 '' other/repo
expect_body other-repo-self.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: other/repo/.github/actions/x@'"${SHA}"$'\n' 1 \
  "$(one_finding other-repo-self.yml "other/repo/.github/actions/x@${SHA}" other/repo)" other/repo

# A slug the fold cannot spell is a run that cannot happen, not a pass.
expect_body bad-slug.yml $'on: push\n' 2 \
  'check-uses-no-self-reference: GITHUB_REPOSITORY not\ a\ slug is not an owner/repo slug of ASCII letters, digits, - and _' 'not a slug'

# A file yq cannot parse cannot be cleared, so it is a finding.
expect_body broken.yml $'on: push\njobs: [\n' 1 \
  $'DIR/broken.yml: yq parse failed; uses: references cannot be verified\n1 self-reference uses: finding(s)'

# A filter that selects nothing, and an empty scan set, are runs that
# could not happen.
filter_dir="$(mktemp --directory)"
printf 'on: push\n' >"${filter_dir}/a.yml"
filter_exit=0
filter_err="$(WORKFLOWS_DIR_OVERRIDE="${filter_dir}" WORKFLOW_FILE_FILTER=no-such.yml \
  "${SCRIPT}" 2>&1 >/dev/null)" || filter_exit=$?
empty_dir="$(mktemp --directory)"
empty_exit=0
empty_err="$(env --unset=LINT_ALLOW_EMPTY_SCAN WORKFLOWS_DIR_OVERRIDE="${empty_dir}" \
  "${SCRIPT}" 2>&1 >/dev/null)" || empty_exit=$?
rm --recursive --force -- "${filter_dir}" "${empty_dir}"
if [[ ${filter_exit} != 2 || ${filter_err} != *'selected 0 of'* ]]; then
  printf 'FAIL filter-none: exit %s (want 2)\n  stderr: %s\n' "${filter_exit}" "${filter_err}" >&2
  exit 1
fi
printf 'OK   filter selecting nothing exits tooling code\n'
if [[ ${empty_exit} != 2 || ${empty_err} != *'matched 0 files'* ]]; then
  printf 'FAIL empty-scan: exit %s (want 2)\n  stderr: %s\n' "${empty_exit}" "${empty_err}" >&2
  exit 1
fi
printf 'OK   empty scan set exits tooling code\n'

# Without yq nothing is scanned. Run through an absolute bash with an
# empty PATH: the script is reached, its own tool guard is what fires.
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
