#!/usr/bin/env bash
# scripts/retry-command.sh
#
# @description Run a command up to N times, sleeping between attempts, and
# exit with the last attempt's status. Bounds the wait for a registry
# index that lags a push (Docker Hub's referrers index can trail it by a
# minute or two), so a signature or attestation check that races the
# index retries instead of failing the release. The command's stdout and
# stderr pass through unchanged; after each failed attempt except the
# last, a `retry-command: attempt N/M failed (exit X); retrying in Ds`
# line goes to stderr.
#
# Usage:
#   retry-command.sh <attempts> <delay-seconds> -- <command> [args...]
#
# Exit codes:
#   0  the command succeeded on some attempt
#   2  usage error: a non-numeric or zero attempt count, a non-numeric
#      delay, a missing `--`, or no command after it
#   *  the last attempt's exit code, when every attempt failed

set -Eeuo pipefail
IFS=$'\n\t'

function usage() {
  printf 'usage: %s <attempts> <delay-seconds> -- <command> [args...]\n' "${0##*/}" >&2
  exit 2
}

if (($# < 4)) || [[ $3 != '--' ]]; then
  usage
fi
readonly ATTEMPTS="$1" DELAY="$2"
shift 3
if [[ ! ${ATTEMPTS} =~ ^[123456789][0123456789]*$ || ! ${DELAY} =~ ^[0123456789]+$ ]]; then
  usage
fi

attempt=1
while :; do
  rc=0
  "$@" || rc=$?
  if ((rc == 0)); then
    exit 0
  fi
  if ((attempt >= ATTEMPTS)); then
    exit "${rc}"
  fi
  printf 'retry-command: attempt %d/%d failed (exit %d); retrying in %ds\n' \
    "${attempt}" "${ATTEMPTS}" "${rc}" "${DELAY}" >&2
  sleep "${DELAY}"
  attempt=$((attempt + 1))
done
