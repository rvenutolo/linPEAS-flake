#!/usr/bin/env bash
# @subject scripts/check-manifest-digest-pinned.sh
# @subject scripts/check-cosign-identity-pinned.sh
# @subject scripts/check-nix-run-pinned.sh
# @subject scripts/check-dockerhub-token-scope-split.sh
# tests/md-fence-shapes.test.sh — proves the four fenced-command lints read
# the same Markdown fences: a command inside a shell-tagged fence is read
# whatever the fence's marker character, run length, quoting, list
# placement or tag spelling, and a command inside a fence tagged for
# another language is not. Fixtures are written into a temp dir at run
# time because mdformat rewrites tilde, quoted and list-opened fences.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"

failures=0

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Backticks are spelled through variables so no scenario text carries a
# literal fence marker.
readonly BT=$'\x60'
readonly F3="${BT}${BT}${BT}"
readonly F4="${BT}${BT}${BT}${BT}"

# One violating command per lint, in the shape that lint reads. The Docker
# Hub command names the token as literal text, so its `${...}` stays
# unexpanded.
# shellcheck disable=SC2016
declare -A CMD=(
  ['check-manifest-digest-pinned']='docker buildx imagetools create --tag r/x:latest r/x:amd64'
  ['check-cosign-identity-pinned']='cosign verify r/x:latest'
  ['check-nix-run-pinned']='nix run nixpkgs#cosign -- version'
  ['check-dockerhub-token-scope-split']='curl --request DELETE https://hub.docker.com/v2/x --header "Authorization: Bearer ${DOCKERHUB_TOKEN_RW}"'
)
readonly -a LINTS=(
  check-manifest-digest-pinned
  check-cosign-identity-pinned
  check-nix-run-pinned
  check-dockerhub-token-scope-split
)

work="$(mktemp --directory)"
readonly work
trap 'rm --recursive --force -- "${work:?}"' EXIT

# @description Write one scenario's Markdown file. `@C` in the body is
# replaced by the lint's violating command.
# @arg $1 file path  @arg $2 lint  @arg $3 body
function write_md() {
  local -r path="$1" lint="$2" body="$3"
  printf '%s\n' "${body//@C/${CMD[${lint}]}}" >"${path}"
}

# @description Run one lint over a newline-separated file list.
# Prints the exit code; stderr goes to $2.
# @arg $1 lint  @arg $2 stderr file  @arg $3 file list
function run_lint() {
  local -r lint="$1" err_file="$2" paths="$3"
  local rc=0
  PATHS_OVERRIDE="${paths}" LINT_ALLOW_EMPTY_SCAN=1 \
    "${REPO_ROOT}/scripts/${lint}.sh" >/dev/null 2>"${err_file}" || rc=$?
  printf '%s' "${rc}"
}

# @description A shape that must be READ: the lint exits 1 and names the
# scenario's own file.
# The Docker Hub lint also names the line the fence opens on.
# @arg $1 shape name  @arg $2 body  @arg $3 opening line (default 1)
function expect_read() {
  local -r shape="$1" body="$2" start="${3:-1}"
  local lint file err_file rc want=""
  for lint in "${LINTS[@]}"; do
    file="${work}/${lint#check-}.${shape}.md"
    err_file="${work}/${lint#check-}.${shape}.err"
    write_md "${file}" "${lint}" "${body}"
    rc="$(run_lint "${lint}" "${err_file}" "${file}")"
    want="${file##*/}"
    if [[ ${lint} == check-dockerhub-token-scope-split ]]; then want="${file##*/}:${start}:"; fi
    harness_assert_record "read:${lint#check-}:${shape}" "${want}" "${err_file}"
    if [[ ${rc} == 1 ]] && grep --fixed-strings --quiet -- "${want}" "${err_file}"; then
      pass "read:${lint#check-}:${shape}"
    else
      fail "read:${lint#check-}:${shape}: exit ${rc}, want 1 naming ${want}"
      cat -- "${err_file}" >&2
    fi
  done
}

# @description A shape that must NOT be read. A plain shell fence with the
# same violation rides in the same run, so the run is proven to have read
# Markdown at all: the lint must exit 1 naming the control and must not
# name the shape's file.
# @arg $1 shape name  @arg $2 body
function expect_unread() {
  local -r shape="$1" body="$2"
  local lint file control err_file rc
  for lint in "${LINTS[@]}"; do
    file="${work}/${lint#check-}.${shape}.md"
    control="${work}/${lint#check-}.${shape}.control.md"
    err_file="${work}/${lint#check-}.${shape}.err"
    write_md "${file}" "${lint}" "${body}"
    write_md "${control}" "${lint}" "${F3}sh"$'\n''@C'$'\n'"${F3}"
    rc="$(run_lint "${lint}" "${err_file}" "${file}"$'\n'"${control}")"
    harness_assert_record "unread:${lint#check-}:${shape}" "${control##*/}" "${err_file}"
    if [[ ${rc} == 1 ]] && grep --fixed-strings --quiet -- "${control##*/}" "${err_file}" &&
      ! grep --fixed-strings --quiet -- "${file##*/}" "${err_file}"; then
      pass "unread:${lint#check-}:${shape}"
    else
      fail "unread:${lint#check-}:${shape}: exit ${rc}, want 1 naming ${control##*/} and not ${file##*/}"
      cat -- "${err_file}" >&2
    fi
  done
}

# Shapes that carry a shell command and must be read.
expect_read 'backtick-sh' "${F3}sh"$'\n''@C'$'\n'"${F3}"
expect_read 'backtick-untagged' "${F3}"$'\n''@C'$'\n'"${F3}"
expect_read 'tilde' "~~~sh"$'\n''@C'$'\n'"~~~"
expect_read 'four-backticks' "${F4}sh"$'\n''@C'$'\n'"${F4}"
expect_read 'blockquote' "> ${F3}sh"$'\n''> @C'$'\n'"> ${F3}"
expect_read 'nested-blockquote' "> > ${F3}sh"$'\n''> > @C'$'\n'"> > ${F3}"
expect_read 'list-marker' "- ${F3}sh"$'\n''  @C'$'\n'"  ${F3}"
expect_read 'ordered-list-marker' "1. ${F3}sh"$'\n''   @C'$'\n'"   ${F3}"
expect_read 'tag-uppercase' "${F3}Bash"$'\n''@C'$'\n'"${F3}"
expect_read 'tag-attribute-braces' "${F3}{.sh}"$'\n''@C'$'\n'"${F3}"
expect_read 'tag-after-space' "${F3} sh"$'\n''@C'$'\n'"${F3}"
expect_read 'short-closer-stays-open' "${F4}sh"$'\n'"${F3}"$'\n''@C'$'\n'"${F4}"
expect_read 'other-marker-stays-open' "~~~sh"$'\n'"${F3}"$'\n''@C'$'\n'"~~~"
expect_read 'crlf-tagged' "${F3}bash"$'\r\n''@C'$'\r\n'"${F3}"$'\r'
expect_read 'crlf-untagged' "${F3}"$'\r\n''@C'$'\r\n'"${F3}"$'\r'
expect_read 'formfeed-after-tag' "${F3}sh"$'\f\n''@C'$'\n'"${F3}"
expect_read 'formfeed-indent' $'\f'"${F3}sh"$'\n''@C'$'\n'$'\f'"${F3}"
expect_read 'doubled-carriage-return' "${F3}sh"$'\r\r\n''@C'$'\r\r\n'"${F3}"$'\r\r'
expect_read 'unterminated' "${F3}sh"$'\n''@C'
expect_read 'blockquote-unclosed-then-plain' "> ${F3}sh"$'\n''> @C'$'\n'$'\n''plain'
expect_read 'fence-after-prose' 'prose'$'\n'$'\n'"${F3}sh"$'\n''@C'$'\n'"${F3}" 3

# Shapes that carry the same command in a fence of another language, or
# outside any fence, and must not be read.
expect_unread 'tag-after-space-yaml' "${F3} yaml"$'\n''@C'$'\n'"${F3}"
expect_unread 'tilde-yaml' "~~~yaml"$'\n''@C'$'\n'"~~~"
expect_unread 'wrapped-fence' "${F4}yaml"$'\n'"${F3}sh"$'\n'"inner"$'\n'"${F3}"$'\n''@C'$'\n'"${F4}"
expect_unread 'blockquote-yaml' "> ${F3}yaml"$'\n''> @C'$'\n'"> ${F3}"
expect_unread 'blockquote-ends-fence' "> ${F3}sh"$'\n''> echo hi'$'\n'$'\n''@C'
expect_unread 'prose-outside-fence' "${F3}sh"$'\n''echo hi'$'\n'"${F3}"$'\n'$'\n''@C'
expect_unread 'crlf-closed-fence-then-prose' "${F3}sh"$'\r\n''echo hi'$'\r\n'"${F3}"$'\r\n'$'\r\n''@C'
expect_unread 'command-in-info-string' "${F3}sh @C"$'\n'"${F3}"

# @description Run the digest-pin lint over a body that must come back clean.
# A blockquoted continuation line keeps its `>` only when the reader fails
# to strip it, and that token reads as an unpinned source.
# @arg $1 shape name  @arg $2 body
function expect_digest_clean() {
  local -r shape="$1" body="$2"
  local file err_file rc
  file="${work}/digest-clean.${shape}.md"
  err_file="${work}/digest-clean.${shape}.err"
  printf '%s\n' "${body}" >"${file}"
  rc="$(run_lint check-manifest-digest-pinned "${err_file}" "${file}")"
  if [[ ${rc} == 0 && ! -s ${err_file} ]]; then
    pass "digest-clean:${shape}"
  else
    fail "digest-clean:${shape}: exit ${rc}, want 0 and no output"
    cat -- "${err_file}" >&2
  fi
}

DIGEST="sha256:$(printf 'a%.0s' {1..64})"
readonly DIGEST
# A backslash, spelled by code point so no quoting shape has to hold it.
readonly BACKSLASH=$'\x5c'
expect_digest_clean 'blockquote-continuation' "> ${F3}sh"$'\n'"> docker buildx imagetools create --tag r/x:latest ${BACKSLASH}"$'\n'"> r/x@${DIGEST}"$'\n'"> ${F3}"

# @description The Docker Hub lint over fences in one file: each fence's
# state starts fresh. A fence the lint must flag names its file and line.
# A file it must leave clean rides with a plain violating file, so the run
# is proven to have read Markdown: the lint must name the control and not
# the file.
# @arg $1 shape name  @arg $2 want exit (0 clean, 1 flagged)  @arg $3 body
function expect_dockerhub() {
  local -r shape="$1" want_rc="$2" body="$3"
  local -r lint=check-dockerhub-token-scope-split
  local file control err_file rc ok=0
  file="${work}/dockerhub-state.${shape}.md"
  control="${work}/dockerhub-state.${shape}.control.md"
  err_file="${work}/dockerhub-state.${shape}.err"
  printf '%s\n' "${body}" >"${file}"
  write_md "${control}" "${lint}" "${F3}sh"$'\n''@C'$'\n'"${F3}"
  if [[ ${want_rc} == 1 ]]; then
    rc="$(run_lint "${lint}" "${err_file}" "${file}")"
    harness_assert_record "dockerhub-state:${shape}" "${file##*/}" "${err_file}"
    if [[ ${rc} == 1 ]] && grep --fixed-strings --quiet -- "${file##*/}" "${err_file}"; then ok=1; fi
  else
    rc="$(run_lint "${lint}" "${err_file}" "${file}"$'\n'"${control}")"
    harness_assert_record "dockerhub-state:${shape}" "${control##*/}" "${err_file}"
    if [[ ${rc} == 1 ]] && grep --fixed-strings --quiet -- "${control##*/}" "${err_file}" &&
      ! grep --fixed-strings --quiet -- "${file##*/}" "${err_file}"; then ok=1; fi
  fi
  if ((ok)); then
    pass "dockerhub-state:${shape}"
  else
    fail "dockerhub-state:${shape}: exit ${rc}, want a verdict of ${want_rc} for ${file##*/}"
    cat -- "${err_file}" >&2
  fi
}

# shellcheck disable=SC2016
readonly DEL='curl --request DELETE https://hub.docker.com/v2/x --header "Authorization: Bearer $DOCKERHUB_TOKEN_DELETE"'
# shellcheck disable=SC2016
readonly GET_RW='curl https://hub.docker.com/v2/x --header "Authorization: Bearer $DOCKERHUB_TOKEN_RW"'
# shellcheck disable=SC2016
readonly GET_DEL='curl https://hub.docker.com/v2/x --header "Authorization: Bearer $DOCKERHUB_TOKEN_DELETE"'
readonly DEL_BARE='curl --request DELETE https://hub.docker.com/v2/x'
readonly DEL_OTHER='curl --request DELETE https://example.com/v2/x'

expect_dockerhub 'delete-seen-does-not-leak' 0 "${F3}sh"$'\n'"${DEL}"$'\n'"${F3}"$'\n'"${F3}sh"$'\n'"${GET_RW}"$'\n'"${F3}"
expect_dockerhub 'rw-seen-does-not-leak' 0 "${F3}sh"$'\n'"${GET_RW}"$'\n'"${F3}"$'\n'"${F3}sh"$'\n'"${DEL}"$'\n'"${F3}"
expect_dockerhub 'token-seen-does-not-leak' 0 "${F3}sh"$'\n'"${GET_DEL}"$'\n'"${F3}"$'\n'"${F3}sh"$'\n'"${DEL_OTHER}"$'\n'"${F3}"
expect_dockerhub 'hub-seen-does-not-leak' 0 "${F3}sh"$'\n'"curl https://hub.docker.com/v2/x"$'\n'"${F3}"$'\n'"${F3}sh"$'\n'"${DEL_OTHER}"$'\n'"${F3}"
expect_dockerhub 'delete-token-seen-does-not-leak' 1 "${F3}sh"$'\n'"${GET_DEL}"$'\n'"${F3}"$'\n'"${F3}sh"$'\n'"${DEL_BARE}"$'\n'"${F3}"
expect_dockerhub 'unclosed-fence-is-judged-at-end' 1 "${F3}sh"$'\n'"${DEL_BARE}"
expect_dockerhub 'blockquote-end-judges-the-fence' 1 "> ${F3}sh"$'\n'"> ${DEL_BARE}"$'\n'$'\n''plain'

harness_assert_verify || failures=$((failures + 1))

if ((failures > 0)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nAll md-fence-shapes tests passed\n'
