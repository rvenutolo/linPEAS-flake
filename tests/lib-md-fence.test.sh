#!/usr/bin/env bash
# @subject scripts/lib/md-fence.sh
# tests/lib-md-fence.test.sh — proves `md_step` in scripts/lib/md-fence.sh
# classifies Markdown lines as prose, fence open, fence content and fence
# close, and reports each fence's tag, by driving it over constructed
# documents. Fences are spelled through variables so no scenario text
# carries a literal marker.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/md-fence.sh
source "${REPO_ROOT}/scripts/lib/md-fence.sh"

failures=0

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

readonly BT=$'\x60'
readonly F3="${BT}${BT}${BT}"
readonly F4="${BT}${BT}${BT}${BT}"

# @description Print one record per input line: the `md_step` result, then
# `md_closed`, `md_read` and `md_lang` as they stand after the call, and
# the line as `md_text` leaves it (content lines only).
# @arg $1 document
function classify() {
  awk "${MD_FENCE_AWK}"'
    BEGIN { md_in = 0 }
    {
      r = md_step($0)
      printf "%d c=%d read=%d lang=[%s] text=[%s]\n", r, md_closed, md_read, md_lang, (r == 2 ? md_text : "")
    }
  ' <<<"$1"
}

# @description Assert the per-line records of a document.
# @arg $1 scenario  @arg $2 document  @arg $3 expected records, one per line
function check() {
  local -r name="$1" doc="$2" want="$3"
  local got out_file
  out_file="$(mktemp)"
  got="$(classify "${doc}")"
  printf '%s\n' "${got//$'\n'/;}" >"${out_file}"
  harness_assert_record "${name}" "${want//$'\n'/;}" "${out_file}"
  if [[ ${got} == "${want}" ]]; then
    pass "${name}"
  else
    fail "${name}: got
${got}
want
${want}"
  fi
  rm --force -- "${out_file}"
}

check 'backtick-fence' "prose"$'\n'"${F3}sh"$'\n'"cmd"$'\n'"${F3}"$'\n'"after" \
  "0 c=0 read=0 lang=[] text=[]
1 c=0 read=1 lang=[sh] text=[]
2 c=0 read=1 lang=[sh] text=[cmd]
3 c=0 read=1 lang=[sh] text=[]
0 c=0 read=1 lang=[sh] text=[]"

check 'tilde-fence-keeps-backtick-line' "~~~bash"$'\n'"${F3}"$'\n'"~~~" \
  "1 c=0 read=1 lang=[bash] text=[]
2 c=0 read=1 lang=[bash] text=[${F3}]
3 c=0 read=1 lang=[bash] text=[]"

check 'longer-closer-closes' "${F3}sh"$'\n'"x"$'\n'"${F4}" \
  "1 c=0 read=1 lang=[sh] text=[]
2 c=0 read=1 lang=[sh] text=[x]
3 c=0 read=1 lang=[sh] text=[]"

check 'closer-with-text-is-content' "${F3}sh"$'\n'"${F3} x"$'\n'"${F3}" \
  "1 c=0 read=1 lang=[sh] text=[]
2 c=0 read=1 lang=[sh] text=[${F3} x]
3 c=0 read=1 lang=[sh] text=[]"

check 'tag-spellings' "${F3} YAML"$'\n'"${F3}"$'\n'"${F3}{.Sh .x}"$'\n'"${F3}" \
  "1 c=0 read=0 lang=[yaml] text=[]
3 c=0 read=0 lang=[yaml] text=[]
1 c=0 read=1 lang=[sh] text=[]
3 c=0 read=1 lang=[sh] text=[]"

check 'backtick-in-backtick-info-is-prose' "${F3}a${BT}b"$'\n'"${F3}zsh" \
  "0 c=0 read=0 lang=[] text=[]
1 c=0 read=0 lang=[zsh] text=[]"

check 'blockquote-fence-strips-markers' "> ${F3}sh"$'\n'"> > cmd"$'\n'"> ${F3}" \
  "1 c=0 read=1 lang=[sh] text=[]
2 c=0 read=1 lang=[sh] text=[> cmd]
3 c=0 read=1 lang=[sh] text=[]"

check 'shallower-quote-ends-fence' "> ${F3}sh"$'\n'"> cmd"$'\n'"plain" \
  "1 c=0 read=1 lang=[sh] text=[]
2 c=0 read=1 lang=[sh] text=[cmd]
0 c=1 read=1 lang=[sh] text=[]"

check 'implicit-close-then-open' "> ${F3}sh"$'\n'"${F3}yaml" \
  "1 c=0 read=1 lang=[sh] text=[]
1 c=1 read=0 lang=[yaml] text=[]"

check 'list-marker-opener' "- ${F3}sh"$'\n'"  cmd"$'\n'"  ${F3}" \
  "1 c=0 read=1 lang=[sh] text=[]
2 c=0 read=1 lang=[sh] text=[  cmd]
3 c=0 read=1 lang=[sh] text=[]"

check 'list-marker-line-inside-fence-is-content' "${F3}sh"$'\n'"- ${F3}" \
  "1 c=0 read=1 lang=[sh] text=[]
2 c=0 read=1 lang=[sh] text=[- ${F3}]"

check 'two-backticks-are-prose' "${BT}${BT}sh"$'\n'"x"$'\n'"y"$'\n'"z" \
  "0 c=0 read=0 lang=[] text=[]
0 c=0 read=0 lang=[] text=[]
0 c=0 read=0 lang=[] text=[]
0 c=0 read=0 lang=[] text=[]"

check 'text-and-console-tags-read' "${F3}text"$'\n'"${F3}"$'\n'"${F3}console"$'\n'"${F3}" \
  "1 c=0 read=1 lang=[text] text=[]
3 c=0 read=1 lang=[text] text=[]
1 c=0 read=1 lang=[console] text=[]
3 c=0 read=1 lang=[console] text=[]"

check 'shell-tag-reads' "${F3}shell"$'\n'"${F3}" \
  "1 c=0 read=1 lang=[shell] text=[]
3 c=0 read=1 lang=[shell] text=[]"

check 'tilde-info-may-hold-a-backtick' "~~~a${BT}b" \
  "1 c=0 read=0 lang=[a${BT}b] text=[]"

check 'implicit-close-reopens-at-new-depth' \
  "> > ${F3}sh"$'\n'"> ${F3}sh"$'\n'"z"$'\n'"y" \
  "1 c=0 read=1 lang=[sh] text=[]
1 c=1 read=1 lang=[sh] text=[]
0 c=1 read=1 lang=[sh] text=[]
0 c=0 read=1 lang=[sh] text=[]"

check 'crlf-lines-classify-like-lf' "${F3}bash"$'\r\n'"cmd"$'\r\n'"${F3}"$'\r\n'"after"$'\r' \
  "1 c=0 read=1 lang=[bash] text=[]
2 c=0 read=1 lang=[bash] text=[cmd]
3 c=0 read=1 lang=[bash] text=[]
0 c=0 read=1 lang=[bash] text=[]"

check 'whitespace-kinds-around-fences' $'\f'"${F3}zsh"$'\v'$'\n'"cmd"$'\r\r\n'"${F3}"$'\f'$'\n'"after" \
  "1 c=0 read=0 lang=[zsh] text=[]
2 c=0 read=0 lang=[zsh] text=[cmd]
3 c=0 read=0 lang=[zsh] text=[]
0 c=0 read=0 lang=[zsh] text=[]"

# @description The opening line's number, as `md_start` reports it.
# @arg $1 scenario  @arg $2 document  @arg $3 expected line number
function check_start() {
  local -r name="$1" doc="$2" want="$3"
  local got out_file
  out_file="$(mktemp)"
  got="$(awk "${MD_FENCE_AWK}"'
    BEGIN { md_in = 0 }
    { if (md_step($0) == 1) { print "start=" md_start } }
  ' <<<"${doc}")"
  printf '%s\n' "${got}" >"${out_file}"
  harness_assert_record "${name}" "start=${want}" "${out_file}"
  if [[ ${got} == "start=${want}" ]]; then
    pass "${name}"
  else
    fail "${name}: got ${got@Q}, want start=${want}"
  fi
  rm --force -- "${out_file}"
}

check_start 'start-is-the-opening-line' "a"$'\n'"b"$'\n'"${F3}sh"$'\n'"c" 3

harness_assert_verify || failures=$((failures + 1))

if ((failures > 0)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nAll lib-md-fence tests passed\n'
