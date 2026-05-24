#!/usr/bin/env bash
# scripts/check-script-shebang-pipefail.sh
#
# @description Lint: every `scripts/*.sh` starts with
# `#!/usr/bin/env bash` (exact first line) and contains
# `set -Eeuo pipefail` somewhere in the file.

# Lint: every file under `scripts/*.sh` starts with
# `#!/usr/bin/env bash` (exact first line) and contains
# `set -Eeuo pipefail` somewhere in the file.
#
# A script that silently swallows a failure can corrupt
# `linpeas-pin.json`, skip a security check, or leave a stale build
# artifact behind. `set -Eeuo pipefail` plus a portable shebang are
# the project's hardening minimum.
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
shopt -s nullglob
for f in "${DIR}"/*.sh; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  first_line="$(head -n 1 "${f}")"
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
shopt -u nullglob

if ((failed > 0)); then
  printf '%d script(s) missing required shebang or strict-mode line\n' "${failed}" >&2
  exit 1
fi
exit 0
