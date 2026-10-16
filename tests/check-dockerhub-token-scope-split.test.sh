#!/usr/bin/env bash
# tests/check-dockerhub-token-scope-split.test.sh
set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-dockerhub-token-scope-split.sh"

failures=0

# @description Write a valid baseline workflow set into $1.
# Stubs only need the secrets.* tokens the linter greps for.
# @arg $1 target workflows dir
function write_baseline() {
  local -r dir="$1"
  mkdir --parents "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  push:\n    steps:\n      - env:\n          DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN_RW }}\n' \
    >"${dir}/release-on-bump.yml"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  sync:\n    steps:\n      - with:\n          password: ${{ secrets.DOCKERHUB_TOKEN_DELETE }}\n' \
    >"${dir}/dockerhub-sync.yml"
  printf 'jobs:\n  verify:\n    steps:\n      - run: echo no docker secret here\n' \
    >"${dir}/verify-latest-release.yml"
  # The compliant delete snippet is part of the baseline: its token
  # placeholder sits many lines above the request, so every scenario that
  # passes also proves the rule is scoped to the fence, not to the line.
  write_md "${dir}/recovery.md" 'DOCKERHUB_TOKEN_DELETE'
}

# @description Write a shell-fenced Docker Hub tag-delete snippet whose
# credential placeholder names $2. Mirrors the real runbook's shape: the
# token is assigned many lines above the request, so a line-scoped rule
# would misread the compliant form as a violation.
# @arg $1 target markdown path
# @arg $2 DOCKERHUB_TOKEN_* name to paste into the placeholder
function write_md() {
  local -r path="$1" token="$2"
  cat >"${path}" <<MD
# Recovery

Delete the tag:

\`\`\`bash
DOCKERHUB_USERNAME=rvenutolo
DOCKERHUB_TOKEN="<paste ${token} value>"

curl --fail --silent --show-error \\
  --request DELETE \\
  --header "Authorization: JWT \${TOKEN}" \\
  "https://hub.docker.com/v2/repositories/rvenutolo/linpeas/tags/1.0-amd64/"
\`\`\`
MD
}

# @description Run the linter against a prepared dir; assert exit code and
# (for failures) a stderr substring.
# @arg $1 scenario name
# @arg $2 workflows dir
# @arg $3 expected exit code
# @arg $4 expected stderr substring (empty skips the check)
# @arg $5 PATHS_OVERRIDE value for the Markdown scan; defaults to the
#   baseline's compliant snippet so no scenario reads the real tree
# ASSERT_PATH_PREFIX, when set, is put first on the lint's PATH, for a
# scenario that stubs a tool.
function assert_run() {
  local -r name="$1" dir="$2" expected_exit="$3" expected_stderr="$4"
  local md_paths="${5:-${dir}/recovery.md}"
  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  PATH="${ASSERT_PATH_PREFIX:+${ASSERT_PATH_PREFIX}:}${PATH}" \
    WORKFLOWS_DIR_OVERRIDE="${dir}" PATHS_OVERRIDE="${md_paths}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" ||
    actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

function main() {
  local dir

  # Clean baseline passes.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  assert_run 'clean scope split and compliant delete snippet pass' \
    "${dir}" 0 ''
  rm --recursive --force -- "${dir}"

  # DELETE token leaked into release workflow.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - with:\n          password: ${{ secrets.DOCKERHUB_TOKEN_DELETE }}\n' \
    >>"${dir}/release-on-bump.yml"
  assert_run 'DELETE token in release fails' "${dir}" 1 \
    'release-on-bump.yml: consumes secrets.DOCKERHUB_TOKEN_DELETE'
  rm --recursive --force -- "${dir}"

  # DELETE token leaked into verify workflow.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - with:\n          password: ${{ secrets.DOCKERHUB_TOKEN_DELETE }}\n' \
    >>"${dir}/verify-latest-release.yml"
  assert_run 'DELETE token in verify fails' "${dir}" 1 \
    'verify-latest-release.yml: consumes secrets.DOCKERHUB_TOKEN_DELETE'
  rm --recursive --force -- "${dir}"

  # RW token leaked into verify workflow. verify-latest-release.yml runs its
  # Docker Hub attestation checks anonymously/read-only by design; the
  # write-scoped token is release-only, so its presence in verify is a
  # hardening regression the lint must reject.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - env:\n          X: ${{ secrets.DOCKERHUB_TOKEN_RW }}\n' \
    >>"${dir}/verify-latest-release.yml"
  assert_run 'RW token in verify fails' "${dir}" 1 \
    'verify-latest-release.yml: consumes secrets.DOCKERHUB_TOKEN_RW'
  rm --recursive --force -- "${dir}"

  # RW token leaked into sync workflow.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - env:\n          X: ${{ secrets.DOCKERHUB_TOKEN_RW }}\n' \
    >>"${dir}/dockerhub-sync.yml"
  assert_run 'RW token in sync fails' "${dir}" 1 \
    'dockerhub-sync.yml: consumes secrets.DOCKERHUB_TOKEN_RW'
  rm --recursive --force -- "${dir}"

  # Unsuffixed secret anywhere.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - env:\n          Y: ${{ secrets.DOCKERHUB_TOKEN }}\n' \
    >>"${dir}/release-on-bump.yml"
  assert_run 'unsuffixed token fails' "${dir}" 1 \
    'release-on-bump.yml: secrets.DOCKERHUB_TOKEN is not authoritative'
  rm --recursive --force -- "${dir}"

  # Producer removed — positive assertion catches the silent no-op.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  printf 'jobs:\n  sync:\n    steps:\n      - run: echo nothing\n' \
    >"${dir}/dockerhub-sync.yml"
  assert_run 'missing DELETE producer fails' "${dir}" 1 \
    'dockerhub-sync.yml: must consume secrets.DOCKERHUB_TOKEN_DELETE'
  rm --recursive --force -- "${dir}"

  # Unsuffixed secret in a .yaml workflow: fixed once the suffix-check glob
  # covers *.yaml too.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  extra:\n    steps:\n      - env:\n          Y: ${{ secrets.DOCKERHUB_TOKEN }}\n' \
    >"${dir}/bad-unsuffixed.yaml"
  assert_run 'unsuffixed token in .yaml workflow fails' "${dir}" 1 \
    'bad-unsuffixed.yaml: secrets.DOCKERHUB_TOKEN is not authoritative'
  rm --recursive --force -- "${dir}"

  # GitHub Actions reads a secret's name whatever its case, so each rule
  # reads a reference however its ASCII letters, and those of the
  # `secrets` context, are cased.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - with:\n          password: ${{ secrets.dockerhub_token_delete }}\n' \
    >>"${dir}/release-on-bump.yml"
  assert_run 'lower-case DELETE token in release fails' "${dir}" 1 \
    'release-on-bump.yml: consumes secrets.DOCKERHUB_TOKEN_DELETE'
  rm --recursive --force -- "${dir}"

  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - env:\n          X: ${{ Secrets.DockerHub_Token_Rw }}\n' \
    >>"${dir}/dockerhub-sync.yml"
  assert_run 'mixed-case RW token in sync fails' "${dir}" 1 \
    'dockerhub-sync.yml: consumes secrets.DOCKERHUB_TOKEN_RW'
  rm --recursive --force -- "${dir}"

  # GitHub Actions reads a property through the index form as well, so
  # each rule reads `secrets['NAME']` as it reads `secrets.NAME`, with
  # spaces inside the brackets, and inside a YAML single-quoted scalar
  # that writes each quote twice.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  printf "      - with:\n          password: \${{ secrets['DOCKERHUB_TOKEN_DELETE'] }}\n" \
    >>"${dir}/release-on-bump.yml"
  assert_run 'index-form DELETE token in release fails' "${dir}" 1 \
    'release-on-bump.yml: consumes secrets.DOCKERHUB_TOKEN_DELETE'
  rm --recursive --force -- "${dir}"

  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  printf "      - env:\n          X: '\${{ Secrets[ ''DockerHub_Token_Rw'' ] }}'\n" \
    >>"${dir}/dockerhub-sync.yml"
  assert_run 'index-form RW token in a single-quoted scalar in sync fails' "${dir}" 1 \
    'dockerhub-sync.yml: consumes secrets.DOCKERHUB_TOKEN_RW'
  rm --recursive --force -- "${dir}"

  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  printf "      - env:\n          X: \${{ SECRETS['DOCKERHUB_TOKEN_RW'] }}\n" \
    >>"${dir}/verify-latest-release.yml"
  assert_run 'index-form RW token in verify fails' "${dir}" 1 \
    'verify-latest-release.yml: consumes secrets.DOCKERHUB_TOKEN_RW'
  rm --recursive --force -- "${dir}"

  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  printf "      - env:\n          Y: \${{ secrets['DOCKERHUB_TOKEN'] }}\n" \
    >>"${dir}/release-on-bump.yml"
  assert_run 'index-form unsuffixed token fails' "${dir}" 1 \
    "release-on-bump.yml: secrets['DOCKERHUB_TOKEN'] is not authoritative"
  rm --recursive --force -- "${dir}"

  # The producers in the index form still consume their tokens, and a
  # suffix in the index form is authoritative in a workflow of its own.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  printf "jobs:\n  push:\n    steps:\n      - env:\n          DOCKERHUB_TOKEN: \${{ secrets['DOCKERHUB_TOKEN_RW'] }}\n" \
    >"${dir}/release-on-bump.yml"
  printf "jobs:\n  sync:\n    steps:\n      - with:\n          password: \${{ SECRETS[ 'DockerHub_Token_Delete' ] }}\n" \
    >"${dir}/dockerhub-sync.yml"
  printf "jobs:\n  other:\n    steps:\n      - env:\n          Z: \${{ secrets['dockerhub_token_rw'] }}\n" \
    >"${dir}/other.yml"
  printf "jobs:\n  other:\n    steps:\n      - env:\n          Z: '\${{ secrets[''DOCKERHUB_TOKEN_DELETE''] }}'\n" \
    >"${dir}/other-quoted.yml"
  assert_run 'producers in the index form pass' "${dir}" 0 ''
  rm --recursive --force -- "${dir}"

  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - env:\n          Y: ${{ secrets.dockerhub_token }}\n' \
    >>"${dir}/release-on-bump.yml"
  assert_run 'lower-case unsuffixed token fails' "${dir}" 1 \
    'release-on-bump.yml: secrets.dockerhub_token is not authoritative'
  rm --recursive --force -- "${dir}"

  # The producers spelled in lower and mixed case still consume their
  # tokens, and a suffix in any case is authoritative, in a workflow of
  # its own too.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  push:\n    steps:\n      - env:\n          DOCKERHUB_TOKEN: ${{ secrets.dockerhub_token_rw }}\n' \
    >"${dir}/release-on-bump.yml"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  sync:\n    steps:\n      - with:\n          password: ${{ SECRETS.DockerHub_Token_Delete }}\n' \
    >"${dir}/dockerhub-sync.yml"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  other:\n    steps:\n      - env:\n          Z: ${{ secrets.DockerHub_Token_Rw }}\n' \
    >"${dir}/other.yml"
  assert_run 'producers in lower and mixed case pass' "${dir}" 0 ''
  rm --recursive --force -- "${dir}"

  # A workflow the suffix scan listed but grep could not read. grep exits 2
  # there, and scoring that as "this file names no DOCKERHUB_TOKEN" clears
  # the file of every suffix violation it carries. The lever needs a
  # permission bit, so it reproduces only where the run is not privileged
  # enough to read a mode-000 file; the guard is what makes the failure
  # legible wherever it does reproduce.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - env:\n          Y: ${{ secrets.DOCKERHUB_TOKEN }}\n' \
    >>"${dir}/release-on-bump.yml"
  chmod 000 -- "${dir}/release-on-bump.yml"
  assert_run 'unreadable workflow is a could-not-run' "${dir}" 2 \
    'grep failed reading'
  chmod 644 -- "${dir}/release-on-bump.yml"
  rm --recursive --force -- "${dir}"

  # A workflows dir that is there but holds no YAML leaves the suffix scan
  # with nothing to read, and the run would otherwise exit 0 having asserted
  # nothing about any suffix.
  dir="$(mktemp --directory)"
  assert_run 'workflows dir with no YAML is a could-not-run' "${dir}" 2 \
    'matched 0 files via workflow YAML'
  rm --recursive --force -- "${dir}"

  # A use of the `secrets` context with no literal name may read either
  # token, or the unsuffixed one, so it is refused in every workflow, the
  # three the split binds and any other: the whole context, a name the
  # expression computes, the object filter, a double-quoted index, and the
  # word `secrets` inside a string literal, which the reader cannot tell
  # from a use.
  local case wf expr
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expressions, not shell expansion
  for case in 'release-on-bump.yml|${{ toJSON(secrets) }}' \
    "dockerhub-sync.yml|\${{ secrets[format('DOCKERHUB_TOKEN_{0}', 'RW')] }}" \
    'verify-latest-release.yml|${{ secrets[env.NAME] }}' \
    'other.yml|${{ secrets.* }}' \
    'other.yml|${{ secrets["DOCKERHUB_TOKEN_RW"] }}' \
    "other.yml|\${{ contains(github.head_ref, 'secrets') }}"; do
    wf="${case%%|*}" expr="${case#*|}"
    dir="$(mktemp --directory)"
    write_baseline "${dir}"
    if [[ ${wf} == other.yml ]]; then
      printf 'jobs:\n  a:\n    steps:\n' >"${dir}/${wf}"
    fi
    printf '      - env:\n          T: %s\n' "${expr}" >>"${dir}/${wf}"
    assert_run "unnamed secrets use ${expr} in ${wf} fails" "${dir}" 1 \
      "${wf}:$(grep --count '' "${dir}/${wf}"): ${expr} reads the secrets context without a literal name"
    rm --recursive --force -- "${dir}"
  done

  # A `${{` not closed on its line may read any secret: the lint reads one
  # line at a time.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  a:\n    steps:\n      - env:\n          T: >-\n            ${{\n            secrets.DOCKERHUB_TOKEN }}\n' \
    >"${dir}/other.yml"
  assert_run 'expression not closed on its line fails' "${dir}" 1 \
    'other.yml:6: expression not closed on its line'
  rm --recursive --force -- "${dir}"

  # GitHub Actions evaluates an expression in a scalar as YAML decodes it,
  # so an escape in a double-quoted scalar can hide a token's name from the
  # file text. Each double-quoted scalar is read again as decoded.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - with:\n          password: "${{ s\\x65crets.DOCKERHUB_TOKEN_DELETE }}"\n' \
    >>"${dir}/release-on-bump.yml"
  assert_run 'escaped DELETE token in release fails' "${dir}" 1 \
    'release-on-bump.yml: consumes secrets.DOCKERHUB_TOKEN_DELETE'
  rm --recursive --force -- "${dir}"

  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  a:\n    steps:\n      - env:\n          T: "${{ secrets.DOCKERHUB_T\\x4fKEN_OLD }}"\n' \
    >"${dir}/other.yml"
  assert_run 'escaped unsuffixed token fails' "${dir}" 1 \
    'other.yml: secrets.DOCKERHUB_TOKEN_OLD is not authoritative'
  rm --recursive --force -- "${dir}"

  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  a:\n    steps:\n      - env:\n          T: "${{ toJSON(\\x73ecrets) }}"\n' \
    >"${dir}/other.yml"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  assert_run 'escaped whole context fails' "${dir}" 1 \
    'other.yml: ${{ toJSON(secrets) }} reads the secrets context without a literal name (the scope split cannot tell which token it reads) (read decoded from a double-quoted scalar)'
  rm --recursive --force -- "${dir}"

  # A tag hides the double-quoted style from `yq`; the tagged scalar is
  # read decoded all the same.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  a:\n    steps:\n      - env:\n          T: !!str "${{ secrets.DOCKERHUB_T\\x4fKEN_TAGGED }}"\n' \
    >"${dir}/other.yml"
  assert_run 'escaped unsuffixed token in a tagged scalar fails' "${dir}" 1 \
    'other.yml: secrets.DOCKERHUB_TOKEN_TAGGED is not authoritative'
  rm --recursive --force -- "${dir}"

  # A grep that fails reading the decoded text is a could-not-run, never a
  # workflow that consumes no token: this shim fails each read of a token
  # pattern from stdin, and passes every other read through.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  mkdir -- "${dir}/stub"
  # shellcheck disable=SC2016 # the shim's own text
  printf '#!/usr/bin/env bash\nlast="${!#}"\nif [[ $* == *"[kK][eE][nN]"* && ! -f ${last} ]]; then exit 2; fi\nexec %q "$@"\n' \
    "$(command -v grep)" >"${dir}/stub/grep"
  chmod +x -- "${dir}/stub/grep"
  ASSERT_PATH_PREFIX="${dir}/stub" assert_run 'grep failing on the decoded text is a could-not-run' "${dir}" 2 \
    'could not grep the decoded scalars of'
  rm --recursive --force -- "${dir}"

  # Markdown: the write-scoped token in a delete snippet. The tree
  # complies today, so this fixture is what proves the branch runs at all.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  write_md "${dir}/bad-rw.md" 'DOCKERHUB_TOKEN_RW'
  assert_run 'markdown delete snippet using _RW fails' "${dir}" 1 \
    'names DOCKERHUB_TOKEN_RW' "${dir}/bad-rw.md"
  rm --recursive --force -- "${dir}"

  # Markdown: naming no token at all is not compliance. Also exercises
  # the attached `-XDELETE` spelling and the host-only scoping signal.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # markdown fence backticks, not command substitution
  printf '# bad\n\n```bash\ncurl -XDELETE "https://hub.docker.com/v2/repositories/rvenutolo/linpeas/tags/1.0-amd64/"\n```\n' \
    >"${dir}/bad-notoken.md"
  assert_run 'markdown delete snippet naming no token fails' "${dir}" 1 \
    'names no DOCKERHUB_TOKEN_DELETE' "${dir}/bad-notoken.md"
  rm --recursive --force -- "${dir}"

  # A DELETE against some other API is not this rule's business.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # markdown fence backticks, not command substitution
  printf '# unrelated\n\n```bash\ncurl --request DELETE "https://api.github.com/repos/o/r/releases/assets/1"\n```\n' \
    >"${dir}/other-api.md"
  assert_run 'delete against another API is out of scope' "${dir}" 0 '' \
    "${dir}/other-api.md"
  rm --recursive --force -- "${dir}"

  # The Binding list itself names both spellings in prose. Prose is not a
  # fence, and flagging the rule's own statement would be a false positive.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # markdown fence backticks, not command substitution
  printf 'Snippets performing a tag delete (`--request DELETE` or `-X DELETE`)\nmust use `DOCKERHUB_TOKEN_DELETE` against hub.docker.com.\n' \
    >"${dir}/prose.md"
  assert_run 'prose naming the spellings is not a fence' "${dir}" 0 '' \
    "${dir}/prose.md"
  rm --recursive --force -- "${dir}"

  # A non-shell fence is not a snippet an operator pastes.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # markdown fence backticks, not command substitution
  printf '# json\n\n```json\n{"note": "curl --request DELETE https://hub.docker.com/v2/x/"}\n```\n' \
    >"${dir}/json-fence.md"
  assert_run 'non-shell fence is out of scope' "${dir}" 0 '' \
    "${dir}/json-fence.md"
  rm --recursive --force -- "${dir}"

  # An unreadable doc scored as "no offending fence" clears every snippet
  # it carries, so it must be a could-not-run.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  write_md "${dir}/unreadable.md" 'DOCKERHUB_TOKEN_RW'
  chmod 000 -- "${dir}/unreadable.md"
  assert_run 'unreadable markdown is a could-not-run' "${dir}" 2 \
    'awk failed reading' "${dir}/unreadable.md"
  chmod 644 -- "${dir}/unreadable.md"
  rm --recursive --force -- "${dir}"

  # A PATHS_OVERRIDE resolving to nothing would clear the whole Markdown
  # rule while the run still exited 0.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  assert_run 'empty markdown scan set is a could-not-run' "${dir}" 2 \
    'markdown scan set is empty' $'\n'
  rm --recursive --force -- "${dir}"

  # A job calling a reusable workflow with `secrets: inherit` hands it every
  # secret, either token or the unsuffixed one among them, though no
  # `${{ }}` names one. Refused in every workflow, as an unnamed use is. It
  # is read through `yq`, so a value written as an alias is read the same.
  local i
  local -r call=$'  call:\n    uses: o/r/.github/workflows/x.yml@0123456789012345678901234567890123456789\n'
  for wf in release-on-bump.yml dockerhub-sync.yml verify-latest-release.yml other.yml; do
    dir="$(mktemp --directory)"
    write_baseline "${dir}"
    if [[ ${wf} == other.yml ]]; then
      printf 'jobs:\n' >"${dir}/${wf}"
    fi
    printf '%s    secrets: inherit\n' "${call}" >>"${dir}/${wf}"
    assert_run "secrets: inherit in ${wf} fails" "${dir}" 1 \
      "${wf}: job \"call\" passes every secret to the workflow it calls (secrets: inherit; the scope split cannot tell which token it hands on)"
    rm --recursive --force -- "${dir}"
  done
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  printf 'x: &s inherit\njobs:\n%s    secrets: *s\n' "${call}" >"${dir}/other.yml"
  assert_run 'an aliased secrets: inherit fails' "${dir}" 1 \
    'other.yml: job "call" passes every secret to the workflow it calls (secrets: inherit; the scope split cannot tell which token it hands on)'
  rm --recursive --force -- "${dir}"

  # An explicit `secrets:` map names the secrets it hands on in its values,
  # which the token rules read as any other expression.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '%s    secrets:\n      T: ${{ secrets.DOCKERHUB_TOKEN_DELETE }}\n' "${call}" >>"${dir}/release-on-bump.yml"
  assert_run 'DELETE token in an explicit secrets: map in release fails' "${dir}" 1 \
    'release-on-bump.yml: consumes secrets.DOCKERHUB_TOKEN_DELETE'
  rm --recursive --force -- "${dir}"

  # Controls: a call passing no secrets, and one with an empty `secrets:`,
  # each in its own count of extra workflows so their summaries differ.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  for i in 1 2 3; do
    printf 'jobs:\n%s' "${call}" >"${dir}/other${i}.yml"
  done
  assert_run 'a reusable-workflow call passing no secrets passes' "${dir}" 0 ''
  rm --recursive --force -- "${dir}"
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  for i in 1 2 3; do
    printf 'jobs:\n%s' "${call}" >"${dir}/other${i}.yml"
  done
  printf 'jobs:\n%s    secrets:\n' "${call}" >"${dir}/other4.yml"
  assert_run 'an empty secrets: passes' "${dir}" 0 ''
  rm --recursive --force -- "${dir}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
