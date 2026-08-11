#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Both definition shapes appear here so the name collection is exercised
# with and without the `function` keyword.
function expected_keys() {
  jq --raw-output 'keys[]' expected.json
}

actual_keys() {
  jq --raw-output 'keys[]' actual.json
}

# `diff` consumes both substitutions as file arguments, and its own exit
# status is what the caller acts on, so neither producer's status is lost.
diff <(expected_keys) <(actual_keys)
