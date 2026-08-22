#!/usr/bin/env bash
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
printf '%s\n' "${REPO_ROOT}"
