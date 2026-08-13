#!/usr/bin/env bash
# A sourced library carrying an executable's shebang, which advertises a
# file meant to be run rather than sourced.
# shellcheck shell=bash

function joined() {
  printf '%s\n' "$*"
}
