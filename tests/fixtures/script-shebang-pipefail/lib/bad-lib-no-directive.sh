# shellcheck disable=SC2148 # the absent dialect declaration IS the fixture
# A sourced library with neither a shebang nor a dialect directive, so
# nothing states which shell to parse it as. The disable above keeps the
# repo's own shellcheck hook from rejecting the file it exists to be:
# it suppresses the complaint without declaring a dialect, which is what
# the lint under test looks for.

function joined() {
  printf '%s\n' "$*"
}
