#!/usr/bin/env bash
# scripts/check-script-shebang-pipefail.sh
#
# @description Lint: every executable script under `scripts/` starts
# with `#!/usr/bin/env bash` (exact first line) and contains
# `set -Eeuo pipefail` somewhere in the file; every sourced library
# under `scripts/lib/` satisfies the inverse.

# A script that silently swallows a failure can corrupt
# `linpeas-pin.json`, skip a security check, or leave a stale build
# artifact behind. `set -Eeuo pipefail` plus a portable shebang are
# the project's hardening minimum.
#
# The scan recurses, and the rule splits on where a file sits. A file
# under a `lib/` component is a sourced library, and the executable rule
# is wrong for one: a library runs inside the caller's shell, so setting
# its own options overrides whatever the caller chose, and a shebang
# advertises a file meant to be run rather than sourced. So a library is
# held to the inverse assertion — a `shellcheck shell=` directive
# (nothing else tells shellcheck the dialect once the shebang is gone),
# no shebang, and no shell-option line of its own.
#
# Classification is by path rather than by content. "No shebang means
# library" would excuse exactly the executable that forgot one, which is
# half of what this lint exists to catch.
#
# Honors SCRIPTS_DIR_OVERRIDE + SCRIPT_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_DIR="scripts"
readonly OVERRIDE="${SCRIPTS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${SCRIPT_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"

readonly WANT_SHEBANG="#!/usr/bin/env bash"
readonly WANT_SET_LINE="set -Eeuo pipefail"

failed=0
shopt -s nullglob globstar
for f in "${DIR}"/**/*.sh; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  first_line="$(head -n 1 "${f}")"
  rel="${f#"${DIR}"/}"

  if [[ ${rel} == lib/* || ${rel} == */lib/* ]]; then
    if ! grep --quiet --extended-regexp '^#[[:space:]]*shellcheck[[:space:]]+shell=' "${f}"; then
      printf '%s: sourced library carries no shellcheck shell= directive; without a shebang nothing states the dialect\n' \
        "${f}" >&2
      failed=$((failed + 1))
    fi

    if [[ ${first_line} == '#!'* ]]; then
      printf '%s: sourced library opens with a shebang (%q); a library is sourced into the caller shell, never run\n' \
        "${f}" "${first_line}" >&2
      failed=$((failed + 1))
    fi

    if grep --quiet --extended-regexp '^[[:space:]]*set[[:space:]]+-' "${f}"; then
      printf '%s: sourced library sets its own shell options; it inherits the caller shell, so setting them overrides the caller choice\n' \
        "${f}" >&2
      failed=$((failed + 1))
    fi

    continue
  fi

  if [[ ${first_line} != "${WANT_SHEBANG}" ]]; then
    printf '%s: first line is %q; must be %q\n' \
      "${f}" "${first_line}" "${WANT_SHEBANG}" >&2
    failed=$((failed + 1))
  fi

  if ! grep --quiet --fixed-strings --line-regexp -- "${WANT_SET_LINE}" "${f}"; then
    # Accept the same setting as part of a longer set line too
    # (e.g. `set -Eeuo pipefail -x`), but reject if absent.
    if ! grep --quiet --extended-regexp '^set -Eeuo pipefail([[:space:]]|$)' "${f}"; then
      printf '%s: missing %q (need it as its own line)\n' \
        "${f}" "${WANT_SET_LINE}" >&2
      failed=$((failed + 1))
    fi
  fi
done
shopt -u nullglob globstar

if ((failed > 0)); then
  printf '%d preamble violation(s) across executables and sourced libraries\n' "${failed}" >&2
  exit 1
fi
exit 0
