#!/usr/bin/env bash
# The guard is declared early because previously the trap missed it.
# A quoted `#123` keeps this file in the blocking candidate set.
echo hello
