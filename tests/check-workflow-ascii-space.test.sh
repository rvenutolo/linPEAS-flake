#!/usr/bin/env bash
# tests/check-workflow-ascii-space.test.sh — proves the lint refuses every
# listed Unicode space or line separator in workflow and composite-action
# YAML wherever it sits (indent, after a key, before a comment, inside a
# run block), reads both scan sets, leaves tab, ASCII and escape text
# alone, and treats an empty scan set as a could-not-run. Every tree is
# built at run time.
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-workflow-ascii-space.sh"

failures=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

# @description Write a file under the scenario tree; the lines are printf
# formats, so `\xNN` escapes build the bytes under test.
# @arg $1 scenario name  @arg $2 path under the tree  @arg $@ lines
function put() {
  local -r name="$1" rel="$2"
  shift 2
  mkdir --parents "${work}/${name}/${rel%/*}"
  local line
  : >"${work}/${name}/${rel}"
  for line in "$@"; do
    # shellcheck disable=SC2059 # the line is a format by design
    printf "${line}\n" >>"${work}/${name}/${rel}"
  done
}

# @description Run the lint over one scenario tree and compare exit code,
# the whole of stdout and the whole of stderr. DIR in the expected text
# stands for the tree.
# @arg $1 scenario name  @arg $2 expected exit  @arg $3 whole stdout
# @arg $4 whole stderr
function run_case() {
  local -r name="$1" want_exit="$2"
  local -r dir="${work}/${name}"
  local -r want_out="${3//DIR/${dir}}" want_err="${4//DIR/${dir}}"
  mkdir --parents "${dir}/workflows" "${dir}/actions"
  local out="${work}/${name}.out" err="${work}/${name}.err" outcome="${work}/${name}.outcome"
  local rc=0
  env --unset=BASH_ENV --unset=LINT_ALLOW_EMPTY_SCAN ${CASE_ENV[@]+"${CASE_ENV[@]}"} \
    WORKFLOWS_DIR_OVERRIDE="${dir}/workflows" ACTIONS_DIR_OVERRIDE="${dir}/actions" \
    "${SCRIPT}" >"${out}" 2>"${err}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  local asserted="${want_err%%$'\n'*}"
  [[ -n ${asserted} ]] || asserted="${want_out}"
  harness_assert_record "${name}" "${asserted}" "${outcome}" "${out}" "${err}"
  local got_err
  got_err="$(sed --regexp-extended 's/^\[[^]]*\] //' -- "${err}")"
  if [[ ${rc} -eq ${want_exit} && "$(cat -- "${out}")" == "${want_out}" && ${got_err} == "${want_err}" ]]; then
    printf 'PASS: %s (exit %d)\n' "${name}" "${rc}"
  else
    printf 'FAIL: %s: expected exit %d, stdout %q, stderr %q; got exit %d, stdout %q, stderr %q\n' \
      "${name}" "${want_exit}" "${want_out}" "${want_err}" "${rc}" \
      "$(cat -- "${out}")" "${got_err}" >&2
    failures=$((failures + 1))
  fi
}

declare -a CASE_ENV=()

# @description The message for one finding, and the closing line.
function finding() { printf 'DIR/%s:%s: U+%s is not YAML whitespace; write it as an escape in a double-quoted scalar' "$1" "$2" "$3"; }
function closing() { printf 'workflow-ascii-space: %d Unicode space(s) in %d file(s)' "$1" "$2"; }

put clean workflows/a.yml 'on: push' 'jobs:' '\ta:' 'x: "\\u2003"'
run_case clean 0 'workflow-ascii-space: 1 file(s), 4 line(s) clean' ''

put after-key workflows/a.yml 'on:\xe2\x80\x83push'
run_case after-key 1 '' "$(finding workflows/a.yml 1 2003)
$(closing 1 1)"

put indent workflows/a.yml 'jobs:' '\xe2\x80\x83a: {}'
run_case indent 1 '' "$(finding workflows/a.yml 2 2003)
$(closing 1 1)"

put before-comment workflows/a.yml 'on: push\xe2\x80\x83# note'
run_case before-comment 1 '' "$(finding workflows/a.yml 1 2003)
$(closing 1 1)"

put in-run-block workflows/a.yml 'run: |' '  echo a\xc2\xa0b'
run_case in-run-block 1 '' "$(finding workflows/a.yml 2 00A0)
$(closing 1 1)"

put in-action actions/x/action.yml 'name: x' 'runs:\xe3\x80\x80using: composite'
run_case in-action 1 '' "$(finding actions/x/action.yml 2 3000)
$(closing 1 1)"

put yaml-extension workflows/a.yaml 'on:\xe2\x80\xa8push'
run_case yaml-extension 1 '' "$(finding workflows/a.yaml 1 2028)
$(closing 1 1)"

put clean-beside-bad workflows/a.yml 'on: push'
put clean-beside-bad workflows/b.yml 'x:\xe2\x80\x83y'
put clean-beside-bad workflows/c.yml 'on: push'
run_case clean-beside-bad 1 '' "$(finding workflows/b.yml 1 2003)
$(closing 1 1)"

# One scan glob matching nothing is no could-not-run while another matches.
put actions-glob-empty workflows/a.yml 'on:\xc2\xa0push'
run_case actions-glob-empty 1 '' "$(finding workflows/a.yml 1 00A0)
$(closing 1 1)"

put two-files workflows/a.yml 'a:\xe2\x80\x8bb' 'c: d'
put two-files workflows/b.yml 'x:\xe2\x80\x8ay' 'z:\xe2\x80\x8ay'
run_case two-files 1 '' "$(finding workflows/a.yml 1 200B)
$(finding workflows/b.yml 1 200A)
$(finding workflows/b.yml 2 200A)
$(closing 3 2)"

put tab-ascii-escape workflows/a.yml 'on:\tpush' 'x: "\\u2003"' "y: 'é'"
run_case tab-ascii-escape 0 'workflow-ascii-space: 1 file(s), 3 line(s) clean' ''

# Every listed separator, one scenario each.
declare -a ALL=(
  '0085:\xc2\x85' '00A0:\xc2\xa0' '1680:\xe1\x9a\x80' '2000:\xe2\x80\x80'
  '2001:\xe2\x80\x81' '2002:\xe2\x80\x82' '2003:\xe2\x80\x83' '2004:\xe2\x80\x84'
  '2005:\xe2\x80\x85' '2006:\xe2\x80\x86' '2007:\xe2\x80\x87' '2008:\xe2\x80\x88'
  '2009:\xe2\x80\x89' '200A:\xe2\x80\x8a' '200B:\xe2\x80\x8b' '2028:\xe2\x80\xa8'
  '2029:\xe2\x80\xa9' '202F:\xe2\x80\xaf' '205F:\xe2\x81\x9f' '3000:\xe3\x80\x80'
)
for entry in "${ALL[@]}"; do
  code="${entry%%:*}"
  put "sep-${code}" workflows/a.yml "k:${entry#*:}v"
  run_case "sep-${code}" 1 '' "$(finding workflows/a.yml 1 "${code}")
$(closing 1 1)"
done

# Neighbours of the listed ranges are not separators.
put not-listed workflows/a.yml 'a: \xe2\x80\x8c' 'b: \xe2\x80\xaa' 'c: \xc2\xa1' 'd: \xef\xbb\xbf' 'e: \xe3\x80\x81'
run_case not-listed 0 'workflow-ascii-space: 1 file(s), 5 line(s) clean' ''

# An empty scan set is a could-not-run; LINT_ALLOW_EMPTY_SCAN accepts it.
run_case empty-scan 2 '' 'check-workflow-ascii-space.sh: matched 0 files via workflow and composite-action YAML — a real tree cannot have an empty scan set; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate'
CASE_ENV=(LINT_ALLOW_EMPTY_SCAN=1)
run_case empty-scan-allowed 0 'workflow-ascii-space: 0 file(s), 0 line(s) clean' ''
CASE_ENV=()

# A composite action may be written action.yaml.
put action-yaml-extension actions/y/action.yaml 'name: y' 'runs:\xc2\xa0{}'
run_case action-yaml-extension 1 '' "$(finding actions/y/action.yaml 2 00A0)
$(closing 1 1)"

# A directory the glob matches is no file and is skipped.
mkdir --parents "${work}/directory-skipped/workflows/d.yml"
put directory-skipped workflows/a.yml 'on: push' 'jobs: {}'
run_case directory-skipped 0 'workflow-ascii-space: 1 file(s), 2 line(s) clean' ''

# A file with no line counts as 0 lines and is clean.
put empty-file-clean workflows/a.yml 'on: push'
: >"${work}/empty-file-clean/workflows/b.yml"
run_case empty-file-clean 0 'workflow-ascii-space: 2 file(s), 1 line(s) clean' ''

# A scan set holding no regular file is a could-not-run, like an empty one.
mkdir --parents "${work}/only-non-files/workflows/d.yml"
ln --symbolic -- missing-target "${work}/only-non-files/workflows/x.yml"
run_case only-non-files 2 '' 'ERROR no regular file among the scan globs — a real tree cannot have an empty scan set; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate'

# A NUL or a byte that is no UTF-8 does not hide a separator or move its
# line: the file is read as text whatever it holds.
put binary-bytes workflows/a.yml 'on: push' 'a: \x00\xff' 'b:\xe2\x80\x83c'
run_case binary-bytes 1 '' "$(finding workflows/a.yml 3 2003)
$(closing 1 1)"

# The result does not depend on the locale the lint runs in.
for loc in C en_US.UTF-8; do
  put "locale-${loc%%.*}" workflows/a.yml 'a: \xff' 'b:\xe2\x80\x83c' "k: ${loc%%.*}"
  CASE_ENV=("LC_ALL=${loc}")
  run_case "locale-${loc%%.*}" 1 '' "$(finding workflows/a.yml 2 2003)
$(closing 1 1)"
  CASE_ENV=()
done

# A grep that fails is a could-not-run, whether it fails the count or the
# search.
mkdir --parents "${work}/grep-fails-bin"
real_grep="$(command -v grep)"
for mode in count search; do
  case "${mode}" in
  count) marker_arg='--count' ;;
  search) marker_arg='--fixed-strings' ;;
  esac
  printf '#!/usr/bin/env bash\ncase "$*" in *%s*) exit 2 ;; esac\nexec %q "$@"\n' \
    "${marker_arg}" "${real_grep}" >"${work}/grep-fails-bin/grep"
  chmod +x "${work}/grep-fails-bin/grep"
  put "grep-fails-${mode}" workflows/a.yml 'on: push'
  CASE_ENV=("PATH=${work}/grep-fails-bin:${PATH}")
  run_case "grep-fails-${mode}" 2 '' "ERROR grep failed (exit 2) reading DIR/workflows/a.yml"
  CASE_ENV=()
done

# grep absent from PATH is a could-not-run naming grep.
mkdir --parents "${work}/no-grep-bin"
ln --symbolic -- "$(command -v bash)" "${work}/no-grep-bin/bash"
put no-grep workflows/a.yml 'on: push'
CASE_ENV=("PATH=${work}/no-grep-bin")
run_case no-grep 2 '' 'ERROR missing required tool: grep'
CASE_ENV=()

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -ne 0 ]]; then
  printf '%d failure(s)\n' "${failures}" >&2
  exit 1
fi
printf 'all tests passed\n'
