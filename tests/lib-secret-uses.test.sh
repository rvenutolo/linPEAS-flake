#!/usr/bin/env bash
# @subject scripts/lib/secret-uses.sh
# tests/lib-secret-uses.test.sh — proves secret_uses prints a `named`
# record for each literal-name reference inside a `${{ }}` expression, one
# `unnamed` record for an expression that uses the `secrets` context any
# other way, an `open` record for a `${{` not closed on its line, nothing
# for text outside an expression or for `secrets` as a step id, each
# record with its line number, and exits 2 when grep fails reading; and
# that double_quoted_scalars prints each double-quoted key and value as
# YAML decodes it, a NUL as a space, no other style, and exits 2 when `yq`
# cannot read the file.
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
failures=0

work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
# The probe sources both libraries, runs secret_uses on its stdin, and
# prints each record with its tabs as `|` and a `;` after it, then the
# status.
# shellcheck disable=SC2016 # the probe's own text
printf '%s\n' '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  "source '${REPO_ROOT}/scripts/lib/ascii-match.sh'" \
  "source '${REPO_ROOT}/scripts/lib/secret-uses.sh'" \
  'rc=0' \
  'records="$(secret_uses)" || rc=$?' \
  'while IFS= read -r record; do' \
  '  [[ -n ${record} ]] || continue' \
  '  printf "%s;" "${record//$'"'"'\t'"'"'/|}"' \
  'done <<<"${records}"' \
  'printf " status=%d\n" "${rc}"' \
  >"${work}/probe.sh"
chmod +x "${work}/probe.sh"

# A grep that fails as it would on a read error, for the exit-2 scenario.
mkdir -- "${work}/stub"
printf '#!/usr/bin/env bash\nexit 2\n' >"${work}/stub/grep"
chmod +x "${work}/stub/grep"

# @description Run the probe on one text and compare the whole of stdout,
# which starts with the text read so that every scenario's output is its
# own.
# @arg $1 scenario name  @arg $2 text  @arg $3 the expected records
# @arg $4 the expected status (default 0)
# @arg $5 a directory put first on PATH (optional)
function run_scenario() {
  local -r name="$1" text="$2" records="$3" status="${4:-0}" stub="${5:-}"
  local -r want="text=${text@Q} ${records} status=${status}"
  local out err outcome rc=0 run_path="${PATH}"
  if [[ -n ${stub} ]]; then run_path="${stub}:${PATH}"; fi
  out="$(mktemp)"
  err="$(mktemp)"
  outcome="$(mktemp)"
  {
    printf 'text=%s ' "${text@Q}"
    env --unset=BASH_ENV PATH="${run_path}" "${work}/probe.sh" <<<"${text}" 2>"${err}"
  } >"${out}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${want}" "${outcome}" "${out}" "${err}"
  if [[ ${rc} -eq 0 && "$(cat -- "${out}")" == "${want}" && ! -s ${err} ]]; then
    printf 'PASS: %s\n' "${name}"
  else
    printf 'FAIL: %s: expected stdout %q; got exit %d, stdout %q, stderr %q\n' \
      "${name}" "${want}" "${rc}" "$(cat -- "${out}")" "$(cat -- "${err}")" >&2
    failures=$((failures + 1))
  fi
  rm --force -- "${out}" "${err}" "${outcome}"
}

# A literal name, in the dot or the single-quoted index form, is a
# `named` record whatever the case of the context's letters.
# shellcheck disable=SC2016 # the workflow expressions are literal text
{
  run_scenario 'the dot form is named' \
    'K: ${{ secrets.FOO }}' '1|named|secrets.FOO;'
  run_scenario 'the index form is named' \
    "K: \${{ Secrets[ 'Bar' ] }}" "1|named|Secrets[ 'Bar' ];"
  run_scenario 'two names in one expression are two records' \
    'K: ${{ secrets.A || secrets.B }}' '1|named|secrets.A;1|named|secrets.B;'
  # Any other use of the context names no secret: one record for the
  # expression, which is its text.
  run_scenario 'the whole context is unnamed' \
    'K: ${{ toJSON(secrets) }}' '1|unnamed|${{ toJSON(secrets) }};'
  run_scenario 'a computed index is unnamed' \
    "K: \${{ secrets[format('X_{0}', 'Y')] }}" "1|unnamed|\${{ secrets[format('X_{0}', 'Y')] }};"
  run_scenario 'an index read from another context is unnamed' \
    'K: ${{ secrets[env.NAME] }}' '1|unnamed|${{ secrets[env.NAME] }};'
  run_scenario 'the object filter is unnamed' \
    'K: ${{ secrets.* }}' '1|unnamed|${{ secrets.* }};'
  run_scenario 'a double-quoted index is unnamed' \
    'K: ${{ secrets["FOO"] }}' '1|unnamed|${{ secrets["FOO"] }};'
  run_scenario 'the word in a string literal is unnamed' \
    "K: \${{ format('secrets {0}', 1) }}" "1|unnamed|\${{ format('secrets {0}', 1) }};"
  run_scenario 'a named use comes before the unnamed record' \
    'K: ${{ secrets.A && toJSON(secrets) }}' '1|named|secrets.A;1|unnamed|${{ secrets.A && toJSON(secrets) }};'
  # A `${{` with no `}}` on its line is an `open` record.
  run_scenario 'an expression not closed on its line is open' \
    $'K: >-\n  ${{\n  secrets.FOO }}' '2|open|${{;'
  # No use: a step id, another context, text outside an expression.
  run_scenario 'a step id is no use' \
    'K: ${{ steps.secrets.outputs.x }}' ''
  run_scenario 'another context is no use' \
    "K: \${{ vars['FOO'] }}" ''
  run_scenario 'text outside an expression is not read' \
    'run: echo secrets.FOO toJSON(secrets)' ''
  run_scenario 'each record carries its own line' \
    $'a: 1\nb: ${{ secrets.ONE }}\nc: 2\nd: ${{ toJSON(secrets) }}' '2|named|secrets.ONE;4|unnamed|${{ toJSON(secrets) }};'
  # A grep that cannot read the text is a could-not-read, never a text with
  # no use.
  run_scenario 'a grep failure is exit 2' \
    'K: ${{ secrets.FOO }}' '' 2 "${work}/stub"
}

# The scalar probe writes its argument to a file, runs
# double_quoted_scalars on it, and prints each line of the output with a
# `;` after it, then the status.
# shellcheck disable=SC2016 # the probe's own text
printf '%s\n' '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  "source '${REPO_ROOT}/scripts/lib/ascii-match.sh'" \
  "source '${REPO_ROOT}/scripts/lib/secret-uses.sh'" \
  'file="$(mktemp)"' \
  'printf "%s" "$1" >"${file}"' \
  'rc=0' \
  'texts="$(double_quoted_scalars "${file}" 2>/dev/null)" || rc=$?' \
  'rm --force -- "${file}"' \
  'while IFS= read -r text; do printf "%s;" "${text}"; done <<<"${texts}"' \
  'printf " status=%d\n" "${rc}"' \
  >"${work}/scalar-probe.sh"
chmod +x "${work}/scalar-probe.sh"

# @description Run the scalar probe on one YAML text and compare the whole
# of stdout, which starts with the text read.
# @arg $1 scenario name  @arg $2 YAML text  @arg $3 the expected lines
# @arg $4 the expected status (default 0)
function run_scalar_scenario() {
  local -r name="$1" text="$2" lines="$3" status="${4:-0}"
  local -r want="yaml=${text@Q} ${lines} status=${status}"
  local out err outcome rc=0
  out="$(mktemp)"
  err="$(mktemp)"
  outcome="$(mktemp)"
  {
    printf 'yaml=%s ' "${text@Q}"
    env --unset=BASH_ENV "${work}/scalar-probe.sh" "${text}" 2>"${err}"
  } >"${out}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${want}" "${outcome}" "${out}" "${err}"
  if [[ ${rc} -eq 0 && "$(cat -- "${out}")" == "${want}" && ! -s ${err} ]]; then
    printf 'PASS: %s\n' "${name}"
  else
    printf 'FAIL: %s: expected stdout %q; got exit %d, stdout %q, stderr %q\n' \
      "${name}" "${want}" "${rc}" "$(cat -- "${out}")" "$(cat -- "${err}")" >&2
    failures=$((failures + 1))
  fi
  rm --force -- "${out}" "${err}" "${outcome}"
}

# A double-quoted scalar, value or key, is printed as YAML decodes it; a
# plain, single-quoted or block scalar is not printed, since no escape can
# make its text differ from the file's.
# shellcheck disable=SC2016 # the workflow expressions are literal text
{
  run_scalar_scenario 'an escaped value is printed decoded' \
    'a: "${{ s\x65crets.A }}"' '${{ secrets.A }};'
  run_scalar_scenario 'an escaped key is printed decoded' \
    '"\x24{{ secrets.K }}": v' '${{ secrets.K }};'
  run_scalar_scenario 'a unicode escape is printed decoded' \
    'a: "secr\u0065ts"' 'secrets;'
  run_scalar_scenario 'an escaped line break splits the text' \
    'a: "one\ntwo"' 'one;two;'
  run_scalar_scenario 'a NUL is printed as a space' \
    'a: "x\0y"' 'x y;'
  run_scalar_scenario 'other styles are not printed' \
    $'a: plain\nb: \'single\'\nc: |\n  block\n' ';'
  run_scalar_scenario 'a scalar under an anchor is printed once' \
    $'a: &x "anchored"\nb: *x\nc: *x\n' 'anchored;'
  run_scalar_scenario 'yaml yq cannot read is exit 2' \
    $'a: [\n' ';' 2
}

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -ne 0 ]]; then
  printf '%d failure(s)\n' "${failures}" >&2
  exit 1
fi
