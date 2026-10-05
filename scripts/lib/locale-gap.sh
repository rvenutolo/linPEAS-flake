# scripts/lib/locale-gap.sh
#
# @description Locale precondition for harness scenarios that pin a
# locale to show a locale-bound regex range. Source after
# `set -Eeuo pipefail`.
# shellcheck shell=bash

# @description Fail unless a bash run under `LC_ALL=<locale>` matches the
# fullwidth digit `５` (U+FF15) against `^[0-9]$`. A range in a bash
# `[[ =~ ]]` regex follows the locale's collation, so in `en_US.UTF-8` it
# admits characters a C locale does not. Where the pinned locale is not
# installed, bash warns, falls back to C, and a scenario meant to show the
# difference passes whether or not the script under test spells its class
# out. The probe runs the `bash` on PATH, the one the scripts run under,
# rather than asking `locale -a`, whose answer comes from the system C
# library and can disagree with the one bash is linked against. On failure
# it prints one line naming the locale and what the probe printed.
# @arg $1 locale name, such as `en_US.UTF-8`
# @exitcode 0 the locale shows the gap
# @exitcode 1 it does not
function require_locale_gap() {
  local -r locale="$1"
  local probe=''
  probe="$(LC_ALL="${locale}" bash -c '[[ $1 =~ ^[0-9]$ ]] && printf gap' _ '５' 2>&1)" || true
  if [[ ${probe} != gap ]]; then
    printf '%s: locale %s cannot show a locale-bound [0-9] range (probe printed %q); scenarios pinned to it would pass without testing it\n' \
      "${0##*/}" "${locale}" "${probe}" >&2
    return 1
  fi
}
