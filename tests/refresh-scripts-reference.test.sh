#!/usr/bin/env bash
# tests/refresh-scripts-reference.test.sh
#
# Round-trip + drift + hard-fail harness for
# scripts/refresh-scripts-reference.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-scripts-reference.sh"
readonly DOC="${REPO_ROOT}/docs/reference/scripts.md"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Declared at top-level so the EXIT trap can reach across function boundaries.
backup=''
fixture_dir=''
stray=''

function cleanup() {
  if [[ -n ${backup:-} && -f ${backup} ]]; then
    cp -- "${backup}" "${DOC}" 2>/dev/null || true
    rm --force -- "${backup}"
  fi
  if [[ -n ${fixture_dir:-} && -d ${fixture_dir} ]]; then
    rm --recursive --force -- "${fixture_dir}"
  fi
  if [[ -n ${stray:-} ]]; then
    rm --force -- "${stray}"
  fi
}
trap cleanup EXIT

function main() {
  # 1. Round trip: generate, then --check must pass.
  "${SCRIPT}"
  if "${SCRIPT}" --check; then
    pass '--check passes on freshly generated reference'
  else
    fail '--check failed right after generate'
  fi

  # 2. Markers + section H2s present.
  if grep --quiet '^<!-- BEGIN scripts-reference -->$' "${DOC}" &&
    grep --quiet '^<!-- END scripts-reference -->$' "${DOC}"; then
    pass 'BEGIN/END markers present'
  else
    fail 'BEGIN/END markers missing'
  fi

  if grep --quiet '^## Check scripts$' "${DOC}" &&
    grep --quiet '^## Refresh scripts$' "${DOC}" &&
    grep --quiet '^## Other$' "${DOC}" &&
    grep --quiet '^## Libraries$' "${DOC}"; then
    pass 'all four section H2s present'
  else
    fail 'one or more section H2s missing'
  fi

  # 2b. Libraries render per file and per function: the H3 names the
  # library path and each annotated function gets an H4 with its contract.
  if grep --quiet '^### scripts/lib/temp\.sh$' "${DOC}" &&
    grep --quiet '^#### make_temp()$' "${DOC}" &&
    grep --quiet '^\*\*Exit codes:\*\*$' "${DOC}"; then
    pass 'library H3, function H4 and exit-code list rendered'
  else
    fail 'library rendering missing an H3, H4 or exit-code list'
  fi

  # 3. Drift scenario: inject bogus H3 inside managed block.
  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  awk '
    { print }
    /^<!-- BEGIN scripts-reference -->$/ { print "### scripts/drift-injected.sh" }
  ' "${DOC}" >"${DOC}.tmp"
  mv -- "${DOC}.tmp" "${DOC}"
  local rc=0
  "${SCRIPT}" --check || rc=$?
  cp -- "${backup}" "${DOC}"
  rm --force -- "${backup}"
  backup=''
  if [[ ${rc} -eq 1 ]]; then
    pass '--check exits 1 on in-block drift'
  else
    fail "--check expected exit 1 on drift, got ${rc}"
  fi

  # 4. Hard-fail scenario: SCRIPTS_DIR_OVERRIDE points at a tmpdir
  # containing a fixture script with no @description; --check must
  # exit 2 (parser propagation).
  fixture_dir="$(mktemp --directory)"
  cat >"${fixture_dir}/no-desc.sh" <<'EOF'
#!/usr/bin/env bash
# no description annotation here.
set -Eeuo pipefail
echo hi
EOF
  rc=0
  SCRIPTS_DIR_OVERRIDE="${fixture_dir}" "${SCRIPT}" --check || rc=$?
  rm --recursive --force -- "${fixture_dir}"
  fixture_dir=''
  if [[ ${rc} -eq 2 ]]; then
    pass '--check exits 2 when fixture script lacks @description'
  else
    fail "--check expected exit 2 on missing @description, got ${rc}"
  fi

  # 4b. Library hard-fail scenario: an entry point parses cleanly, but a
  # library under lib/ has a function with no annotation block; --check
  # must exit 2 and name the library rather than the entry point.
  fixture_dir="$(mktemp --directory)"
  mkdir -- "${fixture_dir}/lib"
  cat >"${fixture_dir}/some-script.sh" <<'EOF'
#!/usr/bin/env bash
# @description something
set -Eeuo pipefail
echo hi
EOF
  cat >"${fixture_dir}/lib/bare.sh" <<'EOF'
# @description a library with an unannotated function

function bare() {
  :
}
EOF
  local lib_stderr
  lib_stderr="$(mktemp)"
  rc=0
  SCRIPTS_DIR_OVERRIDE="${fixture_dir}" "${SCRIPT}" --check 2>"${lib_stderr}" || rc=$?
  rm --recursive --force -- "${fixture_dir}"
  fixture_dir=''
  if [[ ${rc} -eq 2 ]] &&
    grep --fixed-strings --quiet 'parse failure in library' "${lib_stderr}"; then
    pass '--check exits 2 when a library function lacks @description'
  else
    fail "--check expected exit 2 naming the library, got ${rc}"
    sed 's/^/    /' "${lib_stderr}" >&2
  fi
  rm --force -- "${lib_stderr}"

  # 5. Parser-shape scenario: a parser that emits JSON of another shape
  # is a document the renderer could not read, not drift. The override
  # stands in for a changed parser; the shape gate must catch it before
  # any field read walks the wrong document.
  fixture_dir="$(mktemp --directory)"
  cat >"${fixture_dir}/some-script.sh" <<'EOF'
#!/usr/bin/env bash
# @description something
set -Eeuo pipefail
echo hi
EOF
  local wrong_parser stderr_file
  wrong_parser="$(mktemp)"
  stderr_file="$(mktemp)"
  cat >"${wrong_parser}" <<'EOF'
BEGIN { print "{\"description\": 42, \"args\": [], \"options\": [], \"example\": \"\"}"; exit }
EOF
  rc=0
  SCRIPT_DOCS_AWK_OVERRIDE="${wrong_parser}" SCRIPTS_DIR_OVERRIDE="${fixture_dir}" \
    "${SCRIPT}" --check 2>"${stderr_file}" || rc=$?
  rm --recursive --force -- "${fixture_dir}"
  fixture_dir=''
  if [[ ${rc} -eq 2 ]] &&
    grep --fixed-strings --quiet 'unexpected parser output shape' "${stderr_file}"; then
    pass '--check exits 2 when the parser emits an unexpected shape'
  else
    fail "--check expected exit 2 on unexpected parser shape, got ${rc}"
    sed 's/^/    /' "${stderr_file}" >&2
  fi
  rm --force -- "${wrong_parser}" "${stderr_file}"

  # 6. Leak cleanup: a stray in-repo temp from an interrupted run must be
  # swept by the EXIT trap on the next default-mode run.
  stray="${REPO_ROOT}/.refresh-scripts-reference-deadbeef.md"
  : >"${stray}"
  "${SCRIPT}"
  local -a leaked
  shopt -s nullglob
  # glob-exempt: an empty match set is the passing state here, not a
  # missed scan. The row passes only when the generator's sweep left no
  # .refresh-scripts-reference-*.md in the repo root, which the test
  # below reads as ${#leaked[@]} -eq 0, so a match is the leak being
  # hunted. Asserting a non-empty set would invert the assertion.
  leaked=("${REPO_ROOT}"/.refresh-scripts-reference-*.md)
  shopt -u nullglob
  if [[ ! -e ${stray} && ${#leaked[@]} -eq 0 ]]; then
    pass 'stray in-repo temp swept and none leaked after default run'
  else
    fail "leak cleanup failed: stray present=$([[ -e ${stray} ]] && echo yes || echo no), remaining=${#leaked[@]}"
  fi
  stray=''

  # 6. Swallowed-treefmt scenario: a failing treefmt must abort the generator
  # (nonzero exit) and must NOT overwrite the tracked doc with unformatted
  # content. With the `|| true` swallow the run went green while moving the
  # unformatted splice into place.
  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  local stub_bin
  stub_bin="$(mktemp --directory)"
  cat >"${stub_bin}/treefmt" <<'EOF'
#!/usr/bin/env bash
echo 'treefmt stub: simulated failure' >&2
exit 1
EOF
  chmod +x "${stub_bin}/treefmt"
  local rc4=0
  PATH="${stub_bin}:${PATH}" "${SCRIPT}" >/dev/null 2>&1 || rc4=$?
  rm --recursive --force -- "${stub_bin}"
  local doc_unchanged='no'
  cmp --silent -- "${backup}" "${DOC}" && doc_unchanged='yes'
  cp -- "${backup}" "${DOC}"
  rm --force -- "${backup}"
  backup=''
  if [[ ${rc4} -ne 0 && ${doc_unchanged} == 'yes' ]]; then
    pass 'failing treefmt aborts without writing an unformatted doc'
  else
    fail "treefmt-failure: want nonzero exit + unchanged doc, got exit ${rc4}, unchanged=${doc_unchanged}"
  fi

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
