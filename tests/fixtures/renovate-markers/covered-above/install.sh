#!/usr/bin/env bash
# renovate: datasource=git-refs depName=foo/bar packageName=https://github.com/foo/bar
# shellcheck disable=SC2034  # fixture variable; value is the artifact under test
readonly PIN_SHA='abcdef0123456789abcdef0123456789abcdef01'
