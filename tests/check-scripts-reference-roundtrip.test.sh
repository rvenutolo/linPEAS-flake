#!/usr/bin/env bash
# tests/check-scripts-reference-roundtrip.test.sh
#
# Failure-mode harness for scripts/check-scripts-reference-roundtrip.sh.
# Every fixture is built at run time in a scratch directory: a page that
# encodes a generator bug is valid Markdown the formatter would otherwise
# be free to rewrite, and a header written with tabs would be reformatted.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-scripts-reference-roundtrip.sh"

failures=0
work=''
TREE=''
LAST_STDERR=''
LAST_NAME=''

function cleanup() {
  if [[ -n ${work} && -d ${work} ]]; then
    rm --recursive --force -- "${work}"
  fi
  rm --force -- "${LAST_STDERR}"
}
trap cleanup EXIT

# @description Start a fixture tree: a scripts/ root holding one library,
# whose page entry every page this harness writes carries.
# @arg $1 scenario name, used as the tree's directory
function new_tree() {
  TREE="${work}/$1"
  mkdir --parents -- "${TREE}/scripts/lib"
  printf '%s\n' '#!/usr/bin/env bash' '# @description Lib header.' \
    >"${TREE}/scripts/lib/l.sh"
}

# @description Write the tree's page: the entry-point entries given on
# stdin, then the library's own entry, inside the managed block.
function write_page() {
  {
    printf '%s\n\n' '# Scripts' '<!-- BEGIN scripts-reference -->' '{% raw %}' '## Check scripts'
    cat
    printf '\n%s\n\n' '## Libraries' '### scripts/lib/l.sh' 'Lib header.'
    printf '%s\n' '{% endraw %}' '<!-- END scripts-reference -->'
  } >"${TREE}/page.md"
}

# @description Run the check against the current tree; assert exit code,
# stderr and, on the clean path, the tally line.
# @arg $1 scenario name
# @arg $2 expected exit code
# @arg $3 expected stderr substring (empty skips the check)
# @arg $4 expected stdout substring (empty skips the check)
# @arg $5 alternate page path (defaults to the tree's page.md)
function run_scenario() {
  local -r name="$1" expected_exit="$2" expected_stderr="$3"
  local -r expected_stdout="${4:-}" page="${5:-${TREE}/page.md}"
  local stderr_file stdout_file outcome_file actual_exit=0
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  SCRIPTS_DIR_OVERRIDE="${TREE}/scripts" \
    SCRIPTS_REFERENCE_DOC_OVERRIDE="${page}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    sed 's/^/    /' -- "${stderr_file}" "${stdout_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    sed 's/^/    /' -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    sed 's/^/    /' -- "${stdout_file}" "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stdout} ]]; then
    harness_assert_also "${expected_stdout}"
  fi
  rm --force -- "${outcome_file}" "${stdout_file}" "${LAST_STDERR}"
  LAST_STDERR="${stderr_file}"
  LAST_NAME="${name}"
}

# @description Assert one more substring in the last scenario's stderr.
# @arg $1 expected stderr substring
function also_expect() {
  local -r substring="$1"
  if ! grep --fixed-strings --quiet -- "${substring}" "${LAST_STDERR}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${LAST_NAME}" "${substring}" >&2
    sed 's/^/    /' -- "${LAST_STDERR}" >&2
    failures=$((failures + 1))
  fi
  harness_assert_also "${substring}"
}

# A header using every shape the reader must accept, and a page showing it
# as the generator renders it. Each near-miss here is a rule's negative
# case: the check must not report a shellcheck directive, a path line, a
# non-colon indented wrap, a code span's trimmed edge blank, a second tag
# on one line, a bare @generates, the prose after a closed @option (shown
# as description), or an `@tag` indented in a later comment block.
function scenario_intact() {
  new_tree intact
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# scripts/t.sh
#
# @description Intact header. Usage:
#
#   t.sh --check
#
#   t.sh
# shellcheck disable=SC2034
# Wrapped at an indent without a lead-in
#   stays prose.
# @option --check exit 1 on drift; exit 2 if the check
# cannot run, with `<subject>: ` as its prefix
#
# Env overrides (test-only):
#   T_OVERRIDE — alternate root
# @arg $1 first  @arg $2 second
# @generates docs/t.md
# @example
#   t.sh --check

#   @option <flag> <text>  prose about the tag, not an annotation
set -Eeuo pipefail
# @description a function doc in an entry script is not published
function f() { :; }
EOF
  write_page <<'EOF'
### scripts/t.sh

Intact header. Usage:

```text
  t.sh --check

  t.sh
```

Wrapped at an indent without a lead-in
stays prose.

Env overrides (test-only):

```text
  T_OVERRIDE — alternate root
```

**Args:**

- `$1` — first
- `$2` — second

**Options:**

- `--check` — exit 1 on drift; exit 2 if the check cannot run, with `<subject>: ` as its prefix

```bash
  t.sh --check
```
EOF
  run_scenario 'every header shape published intact' 0 '' \
    'ok — 2 file(s), 7 annotation unit(s), 2 indented block(s) published intact'
}

function scenario_truncated_annotation() {
  new_tree truncated
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Truncation.
# @option --check exit 2 if the check
# cannot run; do not mutate the working tree
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Truncation.

**Options:**

- `--check` — exit 2 if the check
EOF
  run_scenario 'an annotation cut at its first line is reported' 1 \
    "scripts/t.sh: @option (line 3) is not one item of its list: published 7 of 15 words; dropped or altered from: 'cannot run; do not mutate the working tree'"
}

function scenario_escapes_eaten_and_run_collapsed() {
  new_tree escapes
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Scanner. The ignore pattern:
#
#   --ignore 'steps\.\*\*\.outputs'
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Scanner. The ignore pattern:

--ignore 'steps\.\*\*\.outputs'
EOF
  run_scenario 'escapes a paragraph render eats are reported' 1 \
    "scripts/t.sh: @description (line 2) published 5 of 6 words; dropped or altered from: \"'steps\\\\.\\\\*\\\\*\\\\.outputs'\""
  also_expect "scripts/t.sh: indented block (line 2 description) is not exactly one preformatted block on the page, starting \"--ignore 'steps"
}

function scenario_collapsed_run() {
  new_tree collapsed
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Exit codes:
#   0  clean
#   1  drift
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Exit codes:
0 clean
1 drift
EOF
  run_scenario 'a colon-led run rendered as a paragraph is reported' 1 \
    "scripts/t.sh: indented block (line 2 description) is not exactly one preformatted block on the page, starting '0  clean'"
}

function scenario_uncolon_wrap_is_prose() {
  new_tree wrap
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description A header that wraps
#   at an indent is prose.
true
EOF
  write_page <<'EOF'
### scripts/t.sh

A header that wraps
at an indent is prose.
EOF
  run_scenario 'an indented wrap with no colon lead-in may be a paragraph' 0 '' \
    'ok — 2 file(s), 2 annotation unit(s), 0 indented block(s) published intact'
}

function scenario_split_and_tab_runs() {
  new_tree split
  {
    printf '%s\n' '#!/usr/bin/env bash' '# @description Split run:' \
      '#' '#   alpha' '#' '#   beta' '#' '# Tab run:'
    printf '#\t\tgamma\n#\t\tdelta\n'
    printf '%s\n' 'true'
  } >"${TREE}/scripts/t.sh"
  write_page <<'EOF'
### scripts/t.sh

Split run:

```text
  alpha
```

beta

Tab run:

gamma
delta
EOF
  run_scenario 'a run split at a blank line, or tab-indented and collapsed, is reported' 1 \
    "scripts/t.sh: indented block (line 2 description) is not exactly one preformatted block on the page, starting 'alpha'"
  also_expect "is not exactly one preformatted block on the page, starting 'gamma'"
}

function scenario_placeholder_swallowed() {
  new_tree placeholder
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Placeholder.
# @option --flake <dir> flake to check
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Placeholder.

**Options:**

- `--flake` — <dir> flake to check
EOF
  run_scenario 'a placeholder the renderer reads as HTML is reported' 1 \
    "scripts/t.sh: @option (line 3) is not one item of its list: published 2 of 6 words; dropped or altered from: '<dir> flake to check'"
}

function scenario_resumed_paragraph_dropped() {
  new_tree resumed
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Resumed.
# @option --check exit 1 on drift
#
# A paragraph after the option.
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Resumed.

**Options:**

- `--check` — exit 1 on drift
EOF
  run_scenario 'prose after a closed annotation missing from the page is reported' 1 \
    "scripts/t.sh: @description (line 4) published 0 of 5 words; dropped or altered from: 'A paragraph after the option.'"
}

function scenario_prose_before_first_tag() {
  new_tree pretag
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# scripts/t.sh
# An intro the parser never reads.
# @description Body.
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Body.
EOF
  run_scenario 'header prose before the first tag is reported' 1 \
    'scripts/t.sh:3: header text before the first tag is not published: An intro the parser never reads.'
}

function scenario_tag_after_header_blank() {
  new_tree afterblank
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Body.

# @option --check exit 1 on drift
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Body.
EOF
  run_scenario "an annotation past the header's first blank line is reported" 1 \
    "scripts/t.sh:4: annotation after the header's first blank line is not published: # @option --check exit 1 on drift"
}

function scenario_library_block_unbound() {
  new_tree unbound
  cat >"${TREE}/scripts/lib/l.sh" <<'EOF'
#!/usr/bin/env bash
# @description Lib header.

# @description Orphaned block.
readonly X=1
EOF
  printf '%s\n' '#!/usr/bin/env bash' '# @description Body.' 'true' >"${TREE}/scripts/t.sh"
  printf '%s\n' '### scripts/t.sh' '' 'Body.' | write_page
  run_scenario 'a library block not followed by a function is reported' 1 \
    'scripts/lib/l.sh:4: @description block is not followed by a function line, so it is not published'
}

function scenario_library_tag_outside_block() {
  new_tree libstray
  cat >"${TREE}/scripts/lib/l.sh" <<'EOF'
#!/usr/bin/env bash
# @description Lib header.

# @arg $1 an argument with no block
readonly X=1
EOF
  printf '%s\n' '#!/usr/bin/env bash' '# @description Body.' 'true' >"${TREE}/scripts/t.sh"
  printf '%s\n' '### scripts/t.sh' '' 'Body.' | write_page
  run_scenario "a library annotation outside a function's block is reported" 1 \
    "scripts/lib/l.sh:4: annotation outside a function's @description block is not published: # @arg \$1 an argument with no block"
}

function scenario_library_function_published() {
  new_tree libfn
  cat >"${TREE}/scripts/lib/l.sh" <<'EOF'
#!/usr/bin/env bash
# @description Lib header.

# @description Do the thing.
# @arg $1 the input
function thing() {
  :
}
EOF
  printf '%s\n' '#!/usr/bin/env bash' '# @description Body.' 'true' >"${TREE}/scripts/t.sh"
  # shellcheck disable=SC2016 # `$1` is page text, not an expansion
  printf '%s\n' '### scripts/t.sh' '' 'Body.' '' '## Libraries' '' \
    '### scripts/lib/l.sh' '' 'Lib header.' '' '#### thing()' '' 'Do the thing.' '' \
    '**Args:**' '' '- `$1` — the input' | write_page
  run_scenario 'a library function entry is matched under its own heading' 0 '' \
    'ok — 2 file(s), 4 annotation unit(s), 0 indented block(s) published intact'
  # shellcheck disable=SC2016 # `$1` is page text, not an expansion
  printf '%s\n' '### scripts/t.sh' '' 'Body.' '' '## Libraries' '' \
    '### scripts/lib/l.sh' '' 'Lib header.' '' 'Do the thing.' '' \
    '**Args:**' '' '- `$1` — the input' | write_page
  run_scenario 'a library function with no heading of its own is reported' 1 \
    'scripts/lib/l.sh::thing: @description (line 4) has no entry on the page'
}

function scenario_no_entry() {
  new_tree noentry
  printf '%s\n' '#!/usr/bin/env bash' '# @description Body.' 'true' >"${TREE}/scripts/t.sh"
  printf '%s\n' '#!/usr/bin/env bash' '# @description Other.' 'true' >"${TREE}/scripts/u.sh"
  printf '%s\n' '### scripts/t.sh' '' 'Body.' | write_page
  run_scenario 'a script with no entry on the page is reported' 1 \
    'scripts/u.sh: @description (line 2) has no entry on the page'
}

function scenario_unknown_tag_text() {
  new_tree unknown
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Body.
# @bogus words the parser warns about and drops
true
EOF
  printf '%s\n' '### scripts/t.sh' '' 'Body.' | write_page
  run_scenario 'text on an unknown-tag line is header text that must publish' 1 \
    "scripts/t.sh: @description (line 2) published 1 of 9 words; dropped or altered from: '@bogus words the parser warns about and drops'"
}

function scenario_generates_continuation() {
  new_tree generates
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Body.
# @generates docs/t.md
# and a sentence wrapped under it
true
EOF
  printf '%s\n' '### scripts/t.sh' '' 'Body.' | write_page
  run_scenario 'prose wrapped under a non-rendering tag is reported' 1 \
    "scripts/t.sh: @generates (line 3) published 0 of 6 words; dropped or altered from: 'and a sentence wrapped under it'"
}

function scenario_cannot_run() {
  new_tree cannot
  printf '%s\n' '#!/usr/bin/env bash' '# @description Body.' 'true' >"${TREE}/scripts/t.sh"
  run_scenario 'a missing page is exit 2' 2 'absent.md not found' '' "${TREE}/absent.md"

  printf '%s\n' '# Scripts' '' '### scripts/t.sh' '' 'Body.' >"${TREE}/nomarkers.md"
  run_scenario 'a page without its markers is exit 2' 2 \
    'lacks the scripts-reference BEGIN/END markers' '' "${TREE}/nomarkers.md"

  printf '%s\n' '### scripts/t.sh' '' 'Body.' | write_page
  printf '#!/usr/bin/env bash\n# @description \xff\xfe\ntrue\n' >"${TREE}/scripts/t.sh"
  run_scenario 'a header that is not UTF-8 is exit 2' 2 't.sh is not UTF-8'

  printf '%s\n' '#!/usr/bin/env bash' '# @description' 'true' >"${TREE}/scripts/t.sh"
  printf '%s\n' '#!/usr/bin/env bash' '# @description' >"${TREE}/scripts/lib/l.sh"
  run_scenario 'files holding no annotation text are exit 2' 2 \
    'no annotation text found in 2 file(s)'
  rm --force -- "${TREE}/scripts/t.sh"
  rm --force -- "${TREE}/scripts/lib/l.sh"
  run_scenario 'an empty scripts directory is exit 2' 2 'matched 0 files via scripts directory'
}

# The interpreter is stubbed, so the two failure paths that live outside
# the checker's own logic are reached: a python3 that cannot import
# python-markdown, and a checker that dies with a status it never exits
# with on purpose.
function scenario_interpreter_failures() {
  new_tree interp
  printf '%s\n' '#!/usr/bin/env bash' '# @description Body.' 'true' >"${TREE}/scripts/t.sh"
  printf '%s\n' '### scripts/t.sh' '' 'Body.' | write_page
  local real_python stub_dir
  real_python="$(command -v python3)"
  stub_dir="${work}/stub-bin"
  mkdir --parents -- "${stub_dir}"
  printf '#!/usr/bin/env bash\nexec %q -I -S "$@"\n' "${real_python}" >"${stub_dir}/python3"
  chmod +x -- "${stub_dir}/python3"
  PATH="${stub_dir}:${PATH}" run_scenario 'python-markdown missing is exit 2' 2 \
    'python-markdown is not importable'
  # A renderer that raises stands in for any bug inside the checker: an
  # uncaught exception would otherwise exit 1 and read as findings.
  local stub_py="${work}/stub-py"
  mkdir --parents -- "${stub_py}"
  printf '%s\n' 'def markdown(*args, **kwargs):' '    raise RuntimeError("stub renderer")' \
    >"${stub_py}/markdown.py"
  PYTHONPATH="${stub_py}:${PYTHONPATH:-}" run_scenario 'a checker exception is exit 2, not a finding' 2 \
    'the checker failed: RuntimeError: stub renderer'
  printf '#!/usr/bin/env bash\nexit 3\n' >"${stub_dir}/python3"
  PATH="${stub_dir}:${PATH}" run_scenario 'a checker that dies is exit 2' 2 \
    'the checker died with status 3'
}

# The file count is derived here, independently of the check, so the pass
# line is pinned to the real tree's scope rather than to its wording.
# A unit is matched against its own part of the entry. Each deleted part
# here survives as a substring elsewhere: "1 — drift" inside "1 — drift
# found", and "JSON" inside the description.
function scenario_unit_matched_in_its_own_part() {
  new_tree ownpart
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Emits JSON.
# @exitcode 1 drift
# @exitcode 1 drift found
# @stdout JSON
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Emits JSON.

**Exit codes:**

- `1` — drift found
EOF
  run_scenario 'an annotation present only inside another unit is reported' 1 \
    "scripts/t.sh: @exitcode (line 3) is not one item of its list: its text appears only inside other text"
  also_expect "scripts/t.sh: @stdout (line 5) is not one item of its list: published 0 of 1 words; dropped or altered from: 'JSON'"
}

# The indented-block rule reads description fences only: the example fence
# carrying the same line must not satisfy it.
function scenario_example_fence_not_a_description_block() {
  new_tree examplefence
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Usage:
#   a.sh --foo
# @example
#   a.sh --foo
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Usage: a.sh --foo

```bash
  a.sh --foo
```
EOF
  run_scenario 'a collapsed run is not rescued by the example fence' 1 \
    "scripts/t.sh: indented block (line 2 description) is not exactly one preformatted block on the page, starting 'a.sh --foo'"
}

# A fence that fails to close swallows what follows it: every word is still
# on the page, and the run is still inside a fence.
function scenario_fence_swallows_what_follows() {
  new_tree unclosed
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Usage:
#   a.sh --foo
#
# Trailing prose.
# @exitcode 1 drift
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Usage:

```text
  a.sh --foo

Trailing prose.

**Exit codes:**

- `1` — drift
```
EOF
  run_scenario 'a fence that swallows the rest of the entry is reported' 1 \
    "scripts/t.sh: indented block (line 2 description) is not exactly one preformatted block on the page, starting 'a.sh --foo'"
  also_expect "scripts/t.sh: @exitcode (line 6) is not one item of its list"
}

# Near misses for the page model: a Markdown list in a description shows
# bullets rather than its markers, and a description line reading
# "Exit codes:" is prose, not the generator's bold list label.
function scenario_description_list_and_label_prose() {
  new_tree desclist
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Steps:
#
# - first step here
# 1. numbered one
#
# Exit codes:
#
#   0  clean
# @exitcode 0 clean
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Steps:

- first step here

1. numbered one

Exit codes:

```text
  0  clean
```

**Exit codes:**

- `0` — clean
EOF
  run_scenario 'a description list and a prose "Exit codes:" line are published intact' 0 '' \
    'ok — 2 file(s), 3 annotation unit(s), 1 indented block(s) published intact'
}

# Description units are matched in source order, so a resumed paragraph
# that repeats words of the first one needs its own occurrence.
function scenario_resumed_paragraph_needs_its_own_text() {
  new_tree order
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Run the check.
# @option --check exit 1 on drift
#
# Run the check.
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Run the check.

**Options:**

- `--check` — exit 1 on drift
EOF
  run_scenario 'a resumed paragraph satisfied only by earlier text is reported' 1 \
    "scripts/t.sh: @description (line 4) published 0 of 3 words; dropped or altered from: 'Run the check.'"
}

# The repo root supplies only defaults: with both overrides set the check
# runs outside a work tree, and without them it is a could-not-run.
function scenario_outside_work_tree() {
  new_tree outside
  printf '%s\n' '#!/usr/bin/env bash' '# @description Body.' 'true' >"${TREE}/scripts/t.sh"
  printf '%s\n' '#!/usr/bin/env bash' '# @description Other.' 'true' >"${TREE}/scripts/u.sh"
  printf '%s\n' '### scripts/t.sh' '' 'Body.' '' '### scripts/u.sh' '' 'Other.' | write_page
  local stdout_file stderr_file outcome_file actual_exit=0
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"
  (cd -- "${TREE}" && GIT_CEILING_DIRECTORIES="${work}" "${SCRIPT}") \
    >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${actual_exit} -eq 2 ]] &&
    grep --fixed-strings --quiet -- 'not in a git work tree' "${stderr_file}"; then
    printf 'PASS: outside a work tree with no overrides is exit 2 (exit 2)\n'
  else
    printf 'FAIL: outside a work tree with no overrides is exit 2 — exit %d\n' "${actual_exit}" >&2
    sed 's/^/    /' -- "${stderr_file}" >&2
    failures=$((failures + 1))
  fi
  harness_assert_record 'outside a work tree with no overrides is exit 2' \
    'not in a git work tree' "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
  # Not a subshell: run_scenario's failure count and assertion record must
  # outlive the call.
  cd -- "${TREE}"
  GIT_CEILING_DIRECTORIES="${work}" run_scenario \
    'outside a work tree with both overrides runs' 0 '' \
    'ok — 3 file(s), 3 annotation unit(s), 0 indented block(s) published intact'
  cd -- "${REPO_ROOT}"
}

# An @example is its entry's last fence, whole: a truncated one is
# reported even though its first words match.
function scenario_example_truncated() {
  new_tree example
  cat >"${TREE}/scripts/t.sh" <<'EOF'
#!/usr/bin/env bash
# @description Body.
# @example
#   t.sh --check --verbose
true
EOF
  write_page <<'EOF'
### scripts/t.sh

Body.

```bash
  t.sh --check
```
EOF
  run_scenario 'a truncated example is reported' 1 \
    "scripts/t.sh: @example (line 3) is not the entry's example block: published 2 of 3 words; dropped or altered from: '--verbose'"
}

function scenario_live_tree() {
  local stdout_file stderr_file outcome_file actual_exit=0 f
  local -i files=0
  for f in "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/scripts/lib/*.sh; do
    if [[ ${f##*/} != _* ]]; then
      files+=1
    fi
  done
  local -r want="ok — ${files} file(s), "
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"
  "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${actual_exit} -eq 0 ]] &&
    grep --fixed-strings --quiet -- "${want}" "${stdout_file}" &&
    grep --quiet -- '^check-scripts-reference-roundtrip: ok — [1-9][0-9]* file(s), [1-9][0-9]* annotation unit(s), [1-9][0-9]* indented block(s) published intact$' "${stdout_file}"; then
    printf 'PASS: live tree publishes every header intact (exit 0)\n'
  else
    printf 'FAIL: live tree publishes every header intact — exit %d\n' "${actual_exit}" >&2
    sed 's/^/    /' -- "${stdout_file}" "${stderr_file}" >&2
    failures=$((failures + 1))
  fi
  harness_assert_record 'live tree publishes every header intact' \
    "${want}" "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

function main() {
  work="$(mktemp --directory)"
  scenario_live_tree
  scenario_intact
  scenario_truncated_annotation
  scenario_escapes_eaten_and_run_collapsed
  scenario_collapsed_run
  scenario_uncolon_wrap_is_prose
  scenario_split_and_tab_runs
  scenario_placeholder_swallowed
  scenario_resumed_paragraph_dropped
  scenario_prose_before_first_tag
  scenario_tag_after_header_blank
  scenario_library_block_unbound
  scenario_library_tag_outside_block
  scenario_library_function_published
  scenario_no_entry
  scenario_unknown_tag_text
  scenario_generates_continuation
  scenario_unit_matched_in_its_own_part
  scenario_example_fence_not_a_description_block
  scenario_fence_swallows_what_follows
  scenario_description_list_and_label_prose
  scenario_resumed_paragraph_needs_its_own_text
  scenario_example_truncated
  scenario_cannot_run
  scenario_interpreter_failures
  scenario_outside_work_tree
  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall passed\n'
}

main "$@"
