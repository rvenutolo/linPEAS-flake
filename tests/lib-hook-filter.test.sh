#!/usr/bin/env bash
# @subject scripts/lib/hook-filter.sh
# tests/lib-hook-filter.test.sh — proves scripts/lib/hook-filter.sh reads
# a hook block's `files` and `excludes` out of Nix source, and decides
# admission the way pre-commit does: Python `re.search`, a path admitted
# when `files` matches and the joined exclude pattern does not, Nix string
# escapes undone first. A pattern that does not compile names its hook
# once and yields no verdict at all.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/hook-filter.sh
source "${REPO_ROOT}/scripts/lib/hook-filter.sh"

failures=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Record a scenario's rendered outcome with the
# discrimination gate and assert it equals the expected text exactly.
# @arg $1 scenario name  @arg $2 rendered outcome  @arg $3 expected outcome
function check_rendered() {
  local -r name="$1" got="$2" want="$3"
  local out_file
  out_file="$(mktemp)"
  printf '%s\n' "${got}" >"${out_file}"
  harness_assert_record "${name}" '' "${out_file}"
  if [[ ${got} == "${want}" ]]; then
    pass "${name}"
  else
    fail "${name}: got ${got@Q}, want ${want@Q}"
  fi
  rm --force -- "${out_file}"
}

# @description Hand `hook_filter_admits` one query per four arguments
# (hook, files, exclude, path) and render its outcome: the exit status,
# each path beside the verdict returned for it, then stderr. A verdict
# with no query left to pair it with is rendered as `extra`, so a
# matcher that answered out of step cannot pass as an exact match.
# @arg $1 scenario name  @arg $2 expected outcome  @arg $@ query fields
function check_queries() {
  local -r name="$1" want="$2"
  shift 2
  local -a fields=("$@")
  local status=0 verdicts stderr_file rendered i
  stderr_file="$(mktemp)"
  verdicts="$(printf '%s\037%s\037%s\037%s\0' "${fields[@]}" |
    hook_filter_admits lib-test 2>"${stderr_file}")" || status=$?
  local -a verdict_list=()
  [[ -z ${verdicts} ]] || mapfile -t verdict_list <<<"${verdicts}"
  rendered="exit=${status}"
  for ((i = 0; i < ${#verdict_list[@]}; i++)); do
    if ((4 * i + 3 < ${#fields[@]})); then
      rendered+=$'\n'"${fields[4 * i + 3]@Q}=${verdict_list[i]}"
    else
      rendered+=$'\n'"extra=${verdict_list[i]}"
    fi
  done
  if [[ -s ${stderr_file} ]]; then
    rendered+=$'\n'"$(cat -- "${stderr_file}")"
  fi
  rm --force -- "${stderr_file}"
  check_rendered "${name}" "${rendered}" "${want}"
}

# 1. A negative lookahead is honored, the shape POSIX ERE cannot read.
check_queries 'lookahead' \
  "exit=0"$'\n'"'nix/hooks/a.nix'=true"$'\n'"'docs/a.nix'=false" \
  h '^(?!docs/).*\\.nix$' '^$' 'nix/hooks/a.nix' \
  h '^(?!docs/).*\\.nix$' '^$' 'docs/a.nix'

# 2. A path `files` admits is dropped when the exclude pattern matches it.
check_queries 'exclude-drops' \
  "exit=0"$'\n'"'nix/a.nix'=true"$'\n'"'nix/hooks/b.nix'=false" \
  h '^nix/' '(^nix/hooks/|^docs/)' 'nix/a.nix' \
  h '^nix/' '(^nix/hooks/|^docs/)' 'nix/hooks/b.nix'

# 3. The Nix escape `\\.` reaches the regex as `\.`, a literal dot, so
# a name differing only at that byte is not admitted.
check_queries 'nix-escapes' \
  "exit=0"$'\n'"'flake.lock'=true"$'\n'"'flakeXlock'=false" \
  h '^flake\\.lock$' '^$' 'flake.lock' \
  h '^flake\\.lock$' '^$' 'flakeXlock'

# 4. A path holding a newline is one query and gets one verdict: the
# record ends at NUL, not at the newline.
check_queries 'newline-path' \
  "exit=0"$'\n'"$'ev\\nil.nix'=true"$'\n'"'plain.txt'=false" \
  h 'il\\.nix$' '^$' $'ev\nil.nix' \
  h 'il\\.nix$' '^$' 'plain.txt'

# 5. A `files` pattern that does not compile names its hook once, though
# the hook is queried twice, and no verdict is printed for any query,
# the well-formed hook's included.
check_queries 'files-uncompilable' \
  "exit=2"$'\n'"lib-test: hook bad-files: its files pattern does not compile under Python re: missing ), unterminated subpattern at position 0" \
  good '^a$' '^$' 'a' \
  bad-files '(unclosed' '^$' 'a' \
  bad-files '(unclosed' '^$' 'b'

# 6. The same for the joined exclude pattern.
check_queries 'exclude-uncompilable' \
  "exit=2"$'\n'"lib-test: hook bad-exclude: its exclude pattern does not compile under Python re: missing ), unterminated subpattern at position 0" \
  bad-exclude '^a$' '((x)' 'a'

# 7. A record short of four fields is a could-not-run, not a verdict.
short_status=0
short_stderr="$(printf 'h\037^a$\037^$\0' | hook_filter_admits lib-test 2>&1)" ||
  short_status=$?
check_rendered 'short-record' "exit=${short_status}"$'\n'"${short_stderr}" \
  "exit=2"$'\n'"lib-test: hook-filter record has 3 field(s), want 4"

# 8. With python3 absent the helper says so by name and returns 2 rather
# than leaving the caller a command-not-found status.
nopy_status=0
nopy_stderr="$(
  # shellcheck disable=SC2123 # emptying the search path is the scenario
  PATH="${work}/empty-path"
  printf 'h\037^a$\037^$\037a\0' | hook_filter_admits lib-test 2>&1
)" || nopy_status=$?
check_rendered 'python3-missing' "exit=${nopy_status}"$'\n'"${nopy_stderr}" \
  "exit=2"$'\n'"lib-test: missing required tool: python3"

# 9. The awk reader: a block without `excludes` gets pre-commit's default
# `^$`; a list spanning lines is joined, a `]` inside a quoted entry does
# not end it, and the `files` value is kept as written, escapes included.
cat >"${work}/hooks.nix" <<'EOF'
{
  plain-hook = {
    files = "^flake\\.lock$";
  };
  listed-hook = {
    files = "^nix/";
    excludes = [
      "^docs/[]a]"
      "^nix/hooks/"
    ];
    language = "system";
  };
  inline-hook = {
    excludes = [ "^justfile$" ];
    files = "^x$";
  };
}
EOF
awk_out="$(awk "${HOOK_FILTER_AWK}"'
  /^  [a-z-]+ = \{/ { name = $1; hook_filter_reset(); next }
  /^  \};/ { printf "%s files=%s exclude=%s\n", name, hook_filter_files, hook_filter_exclude(); next }
  { hook_filter_scan($0) }
' "${work}/hooks.nix")"
check_rendered 'awk-reader' "${awk_out}" \
  'plain-hook files=^flake\\.lock$ exclude=^$'$'\n''listed-hook files=^nix/ exclude=(^docs/[]a]|^nix/hooks/)'$'\n''inline-hook files=^x$ exclude=(^justfile$)'

harness_assert_verify || failures=$((failures + 1))

if ((failures > 0)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
