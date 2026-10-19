#!/usr/bin/env bash
# scripts/check-regex-range-ascii.sh
#
# @description Lint: a bash `[[ … =~ … ]]` regex, a GNU `grep` regex
# pattern, or a GNU `sed` script, in `scripts/*.sh`, `scripts/lib/*.sh`
# or `tests/*.sh` must not hold a locale-bound range between ASCII
# letters or digits unless it is matched under a C locale. A range
# follows the locale's collation: under `en_US.UTF-8` `[0-9]` in a bash
# regex also matches digits such as `٣` and `５`, and `[a-f]` matches
# `é`, while the CI runner's `C.UTF-8` matches ASCII only. A validator
# written with a range therefore passes on a developer's machine a value
# CI refuses, and the difference is invisible to CI.
#
# In bash, every such range is reported. GNU grep keeps a positive bracket
# whose ranges all run between digits (`[0-9]`, `Q[1-4]`, `[0-9.]`) ASCII
# in every locale, so only a bracket that holds a letter endpoint
# (`[a-z]`, `[0-9a-f]`, `[A-Za-z0-9._/-]`) or is negated (`[^0-9]`: under
# `en_US.UTF-8` `٣` falls outside it) is reported for grep. GNU sed follows
# the same bracket rules, so a sed script is judged the same way.
#
# A test is matched under a C locale when it follows a
# `local LC_ALL=C` or `local LC_ALL=C.UTF-8` that is a direct statement
# of its own function (`ascii_match` in `scripts/lib/ascii-match.sh` is
# one), or follows a top-level `export LC_ALL=C` or
# `export LC_ALL=C.UTF-8`; the value is one word, unquoted or in single
# quotes, the last `LC_ALL` word on its line. A later assignment,
# `declare`, `local` or `export` (also behind `builtin` or `command`, and
# with the whole assignment quoted) that sets anything but one lone `C` or
# `C.UTF-8` word, or a later `unset LC_ALL`, `wait -p LC_ALL`, `read`,
# `mapfile`, `getopts`, `printf -v`, a `let`, `(( ))` or `$(( ))` that
# holds `LC_ALL` as a name of its own, bare or in double quotes, read or
# written (a single-quoted one, or a quoted word holding more than the
# name, such as `let "LC_ALL=1"`, is not read), a C-style `for` whose header
# or body holds one (`echo LC_ALL` counts; `$LC_ALL` is not a literal),
# `exec {LC_ALL}>` or `for LC_ALL in`, in the same function or outside
# any function, ends that; an element name (`LC_ALL[0]`) counts as
# `LC_ALL`, except inside a `let`, `(( ))`, `$(( ))` or C-style `for`
# header. A write through `eval` or a nameref is not read, nor is the
# order in which functions are called. A declaration
# inside a subshell, a command substitution, a conditional or a
# background statement does not start a C locale; an `unset` or write in
# one still ends it, as do `unset -f`, `unset -n` and
# `command -v unset LC_ALL`, so a range after them is reported although
# the shell would match it as C. A backslash-newline inside an operator or
# a regex is joined before it is read. Otherwise the class is spelled out
# (`[0123456789]`), or the text is matched through `ascii_match`.
#
# The `=~` tests are read from the `shfmt --tojson` parse tree, and the
# operator from the source text between the two operands, since shfmt
# releases encode the operator differently. A file is parsed when it
# holds `~`, holds the marker text, or holds a `grep`, `egrep`, `fgrep`
# or `sed` word together with range-shaped text (a bracket-aware match:
# classes, equivalence classes, collating symbols, and a leading `]` or
# `^]`); any other file is not parsed. That match reads line by line, so
# a grep or sed range split by a backslash-newline inside its bracket,
# in a file with no other sign, is not seen. A regex held in a variable
# is read through the assignments to that variable and the items of a
# `for` loop over it in the same file, following variables they name,
# three levels deep. A quoted operand (`=~ "[0-9]"`) is a literal match,
# but is read like an unquoted one and reported; so is a function whose
# `local LC_ALL` value is in double quotes. Unquote it or spell the
# class out.
#
# A grep call is a command whose word, after leading `command` or
# `builtin` words and their options and `env` with its options and
# NAME=value words, is `grep`, `egrep` or `fgrep`; `command -v grep` is
# a lookup, not a call. `env` options are skipped, and `-u`/`--unset`
# and `-C`/`--chdir` consume their argument; `env -S` is not read. A
# call's patterns are its `-e`/`--regexp` operands, or, when there are
# none and no `-f`/`--file`, its first operand; options are read
# wherever they stand, up to `--`, and an option's own argument (`-m 1`)
# is never a pattern. The grep options read as taking an argument are
# `-e`, `-f`, `-m`, `-A`, `-B`, `-C`, `-d` and `-D`, and the long
# options `--regexp`, `--file`, `--max-count`, `--after-context`,
# `--before-context`, `--context`, `--label`, `--include`, `--exclude`,
# `--exclude-from`, `--exclude-dir`, `--binary-files`, `--devices` and
# `--directories`. A first operand before any `--` that is a plain
# variable (`"$opt"`, `${opt}`) with a same-file value starting with `-`
# is an option, so the call is unresolved. A call with
# `-F`/`--fixed-strings` holds no regex and one with
# `-P`/`--perl-regexp` matches by code point; neither is read. A call
# runs under a C locale when an `LC_ALL=C` or `LC_ALL=C.UTF-8`
# assignment prefixes it (also through `env`), or when it stands in a
# scope that sets a C locale as described above; a prefix with any other
# `LC_ALL` value overrides that scope, and so does `env -u LC_ALL` (or
# `--unset`) unless a later `env` word sets `LC_ALL=C` again. Only
# `LC_ALL` is read. A pattern held in a variable is followed as a `=~`
# regex is. Inside a pattern, a `$name` or a backtick in single quotes
# is still read as an expansion, as for `=~`: a single-quoted `$name` is
# followed, and a backtick counts the call as unresolved. That also
# reads a sed `$` address followed by a command letter (`'$d'`) as the
# variable `d`, so such a call can be reported through a same-file `d`
# value.
#
# A sed call is found as a grep call is: the same leading `command`,
# `builtin` and `env` handling, and the same prefix and scope C-locale
# rules. Its scripts are its `-e`/`--expression` operands, or, when there
# are none and no `-f`/`--file`, its first operand; `-f`/`--file` makes the
# call unresolved. `-l`/`--line-length` take an argument, and `-i` takes
# the rest of its word as a backup suffix. The whole script text is read,
# so a range in replacement text or in a `y` command is reported too; mark
# such a call. A sed script held in a variable is followed as a grep
# pattern is, and a first operand that is a variable holding an option
# makes the call unresolved.
#
# A grep or sed call that is locale-bound on purpose carries the marker
# `# regex-range-ascii: locale-bound: <reason>` on the line directly
# above the line its command starts on (inside a pipeline too); the word
# is exactly `locale-bound`, so `locale-boundary` is not a marker. A marker
# with no reason, or one that exempts no reported call, is itself
# reported. The marker never exempts a `=~` test. A marker-shaped line
# inside a heredoc is read as a marker.
#
# Findings print sorted by line within a file, ties broken by message
# text. The final line is the summary: `regex-range-ascii: ok — scanned N
# file(s), N =~ test(s), N with a regex in a variable, N under a C locale;
# N grep call(s), N not regex (-F/-P), N under a C locale, N unresolved,
# N marked; N sed call(s), N under a C locale, N unresolved, N marked`.
#
# Not read: a regex or pattern that reaches the test or call as a
# function argument, from a function's output or a command substitution,
# from an array assigned as a list (`re=(…)`), from a sourced file, or
# from a `-f` file or a sed `-f` script file; a call whose options come
# from an array or `$@` expansion; an abbreviated long option
# (`--regex=`) or a separate-argument long option outside the set the
# grep-call paragraph lists (`--group-separator SEP`); a regex inside
# `eval` or `bash -c` text; grep or sed in workflow and composite-action
# `run:` blocks, which run only on the runner, whose locale is
# `C.UTF-8`; grep run through a wrapper command (`xargs`, `find -exec`,
# `timeout`, `nice`, `sudo` and the like), which is neither read nor
# counted, and so is sed run through one; and `awk`, `jq` and `yq`
# patterns.
#
# The summary counts each grep or sed call once, in the first bucket it
# fits: not regex (`-F`/`-P`, grep only), then under a C locale, then
# reported or marked when a range is found, then unresolved when a
# pattern or option cannot be read.
#
# Honors SCRIPTS_DIR_OVERRIDE (default: scripts) and TESTS_DIR_OVERRIDE
# (default: tests), and LINT_ALLOW_EMPTY_SCAN=1 for fixtures.
#
# Exits 0 when no such range is found, 1 when one is. Exits 2 when the
# check cannot run: `shfmt` or `jq` absent from PATH, a file in the scan
# set it cannot read, a file in the parse set (described above) that
# `shfmt` cannot parse, or a scan set matching no file.

set -Eeuo pipefail
IFS=$'\n\t'
# Byte offsets from the parse tree index the file text, so slicing it
# must count bytes.
export LC_ALL=C
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"
readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"
readonly MARKER='regex-range-ascii: locale-bound'
# The marker word ends at a colon, whitespace or the line end, so
# `locale-boundary` is not the marker.
readonly MARKER_LINE_RE="^[[:space:]]*# ${MARKER}(:|[[:space:]]|\$)"
# An expansion whose text the lint cannot follow: a command or arithmetic
# substitution, a positional or special parameter.
# shellcheck disable=SC2016 # the expansions are the text matched
readonly OPAQUE_RE='\$\(|`|\$[0123456789@*#?!$-]|\$\{[0123456789@*#?!]'
FOLLOW_RANGE=''
FOLLOW_VIA=''
FOLLOW_UNRES=0

require_tool shfmt
require_tool jq

# @description Emit the parse-tree records of one file, tab-separated:
# `T line x_end y_pos y_end safe` for each binary test (safe is 1 after
# a `local LC_ALL=C` earlier in its function, or after a top-level
# `export LC_ALL=C` or `=C.UTF-8`), `A name value_pos value_end` for
# each assignment and each `for` loop item, and
# `G call line mode c_locale unresolved pat_start pat_end optpos` for each
# pattern of a `grep`, `egrep` or `fgrep` call, and the same fields under
# kind `S` for each script of a `sed` call: `call` is the call's byte
# offset, shared by its patterns; `mode` is `G`, `E`, `F` or `P`, or `S`;
# `c_locale` is 1 when the call runs under `LC_ALL=C` or `C.UTF-8`;
# `unresolved` is 1 when a pattern source cannot be read (`-f`, or a word
# that may expand to options); `pat_start` and `pat_end` are the pattern
# word's byte offsets, both -1 for a call with no readable pattern;
# `optpos` is 1 when the pattern is a first operand before any `--`, where
# a word expanding to an option is read by grep as that option.
# @arg $1 file path
# @exitcode 2 shfmt cannot parse the file
function records_of() {
  local -r file="$1"
  local tree
  if ! tree="$(shfmt --tojson <"${file}" 2>/dev/null)"; then
    log_err "cannot parse ${file}"
    exit 2
  fi
  jq -r '
    def c_locale: (.Value.Parts // []) as $p
      | .Name.Value? == "LC_ALL" and .Index? == null and ($p | length) == 1
        and ($p[0].Value? == "C" or $p[0].Value? == "C.UTF-8");
    # A word as the shell reads it when it holds no expansion.
    def wstr: [.Parts[]?
        | if .Type? == "Lit" then (.Value | gsub("\\\\"; ""))
          elif .Type? == "SglQuoted" then .Value
          elif .Type? == "DblQuoted" then ([.Parts[]? | .Value? // ""] | join(""))
          else "\u0000" end] | join("");
    # `export "LC_ALL=x"` keeps the whole assignment in one word.
    def naked: (.Args[]? | select(.Naked? == true) | .Value | wstr
        | select(startswith("LC_ALL="))
        | {Name: {Value: "LC_ALL"}, Value: {Parts: [{Value: .[7:]}]}});
    def assigns: (.Args[]? | select(.Name? != null)), (.Assigns[]?), naked;
    def lc_writes: [assigns | select(.Name.Value? == "LC_ALL")];
    # The last word wins: `local LC_ALL=C LC_ALL=x` leaves x.
    def last_c: (lc_writes | last // {}) | c_locale;
    # Drop leading `builtin` and `command` words and their options;
    # [how many were dropped, the words left].
    def strip($n): if (.[0]? == "builtin" or .[0]? == "command") then .[1:] | strip($n + 1)
        elif $n > 0 and (.[0]? | type == "string" and startswith("-")) then .[1:] | strip($n)
        else [$n, .] end;
    def lc_name: . == "LC_ALL" or startswith("LC_ALL[");
    def lc_word: select(lc_name or startswith("LC_ALL="));
    # Index of the command word after leading `command`/`builtin` words
    # and their options, and `env` with its options and NAME=value words;
    # -1 when `command -v`/`-V` only looks the word up.
    def lead($w; $i):
      def opts($j): if (($w[$j]? // "") | startswith("-")) then opts($j + 1) else $j end;
      # `-u NAME` and `-C DIR`, alone or ending a cluster, and `--unset`
      # and `--chdir` without `=`, take the next word as their argument.
      def envw($j): ($w[$j]? // "") as $x
        | if ($x | test("^-[A-Za-z]*[uC]$")) or ($x | IN("--unset", "--chdir")) then envw($j + 2)
          elif ($x | startswith("-") or test("^[A-Za-z_][A-Za-z0-9_]*=")) then envw($j + 1)
          else lead($w; $j) end;
      if ($w[$i]? | IN("command", "builtin")) then
        opts($i + 1) as $j
        | if any($w[$i + 1:$j][]; test("^-[A-Za-z]*[vV]")) then -1 else lead($w; $j) end
      elif $w[$i]? == "env" then envw($i + 1)
      else $i end;
    # The literal text an option is recognised by: the leading literal
    # part of the word, or the whole word when it holds no expansion.
    def opt_text($a; $s): if $a.Parts[0].Type? == "Lit" then $a.Parts[0].Value
        elif ($s | contains("\u0000") | not) then $s else "" end;
    # A word that may expand to several words, any of them an option.
    def list_exp($a): [$a | .. | objects | select(.Type? == "ParamExp")
        | select((.Param.Value? | IN("@", "*"))
          or (((.Index.Parts[0].Value?) // "") | IN("@", "*")))] | length > 0;
    # One short-option cluster, letter by letter from index $t.
    def cluster($a; $l; $t):
      if $t >= ($l | length) then .
      else $l[$t:$t + 1] as $c
        | if ($c | IN("F", "P", "E", "G")) then .mode = $c | cluster($a; $l; $t + 1)
          elif ("efmABCdD" | contains($c)) then
            ($a.Pos.Offset + $t + 1) as $r
            | if $r < $a.End.Offset then
                (if $c == "e" then .pats += [[$r, $a.End.Offset]]
                  elif $c == "f" then .unres = 1 | .hasf = true
                  else . end)
              else .skip = (if $c == "e" then "e" elif $c == "f" then "f" else "x" end) end
          else cluster($a; $l; $t + 1) end
      end;
    # Fold one word after the command word into the operand state.
    def operand($a; $s):
      opt_text($a; $s) as $l
      | if .skip == "e" then .pats += [[$a.Pos.Offset, $a.End.Offset]] | .skip = null
        elif .skip == "f" then .unres = 1 | .hasf = true | .skip = null
        elif .skip == "x" then .skip = null
        elif .dd then .ops += [[$a.Pos.Offset, $a.End.Offset]]
        elif $s == "--" then .dd = true
        elif ($l | startswith("--")) then
          ($l[2:] | split("=")[0]) as $n | ($l | contains("=")) as $eq
          | if $n == "regexp" then (if $eq then .pats += [[$a.Pos.Offset + 9, $a.End.Offset]] else .skip = "e" end)
            elif $n == "file" then (if $eq then .unres = 1 | .hasf = true else .skip = "f" end)
            elif $n == "fixed-strings" then .mode = "F"
            elif $n == "perl-regexp" then .mode = "P"
            elif $n == "extended-regexp" then .mode = "E"
            elif $n == "basic-regexp" then .mode = "G"
            elif ($eq | not) and ($n | IN("max-count", "after-context", "before-context",
                "context", "label", "include", "exclude", "exclude-from", "exclude-dir",
                "binary-files", "devices", "directories")) then .skip = "x"
            else . end
        elif ($l | startswith("-")) and $l != "-" then cluster($a; $l; 1)
        elif list_exp($a) then .unres = 1
        else .ops += [[$a.Pos.Offset, $a.End.Offset, 1]] end;
    # One sed short-option cluster, letter by letter from index $t. `-i`
    # takes the rest of its word as a backup suffix, so it ends the
    # cluster; `-e`, `-f` and `-l` take the rest of the word or the next.
    def sed_cluster($a; $l; $t):
      if $t >= ($l | length) then .
      else $l[$t:$t + 1] as $c
        | if $c == "i" then .
          elif ("efl" | contains($c)) then
            ($a.Pos.Offset + $t + 1) as $r
            | if $r < $a.End.Offset then
                (if $c == "e" then .pats += [[$r, $a.End.Offset]]
                  elif $c == "f" then .unres = 1 | .hasf = true
                  else . end)
              else .skip = (if $c == "e" then "e" elif $c == "f" then "f" else "x" end) end
          else sed_cluster($a; $l; $t + 1) end
      end;
    # Fold one word after a sed command word into the operand state.
    def sed_operand($a; $s):
      opt_text($a; $s) as $l
      | if .skip == "e" then .pats += [[$a.Pos.Offset, $a.End.Offset]] | .skip = null
        elif .skip == "f" then .unres = 1 | .hasf = true | .skip = null
        elif .skip == "x" then .skip = null
        elif .dd then .ops += [[$a.Pos.Offset, $a.End.Offset]]
        elif $s == "--" then .dd = true
        elif ($l | startswith("--")) then
          ($l[2:] | split("=")[0]) as $n | ($l | contains("=")) as $eq
          | if $n == "expression" then (if $eq then .pats += [[$a.Pos.Offset + 13, $a.End.Offset]] else .skip = "e" end)
            elif $n == "file" then (if $eq then .unres = 1 | .hasf = true else .skip = "f" end)
            elif $n == "line-length" and ($eq | not) then .skip = "x"
            else . end
        elif ($l | startswith("-")) and $l != "-" then sed_cluster($a; $l; 1)
        elif list_exp($a) then .unres = 1
        else .ops += [[$a.Pos.Offset, $a.End.Offset, 1]] end;
    # Every object node, collected once: each stream below scans this
    # list instead of walking the tree again.
    [.. | objects] as $all
    | [ $all[] | select(.Type? == "FuncDecl") | [.Pos.Offset, .End.Offset] ] as $funcs
    | def innermost($x): [ $funcs[] | select(.[0] <= $x and $x < .[1]) ]
        | if length == 0 then [null, null] else max_by(.[0]) end;
    # Every write to LC_ALL that is not a lone C or C.UTF-8 word:
    # [offset, enclosing function start, end], null outside a function.
    [ ( $all[]
        | select(.Type? == "DeclClause"
            or (.Type? == "CallExpr" and ((.Args // []) | length) == 0))
        | select((lc_writes | length) > 0 and (last_c | not))
        | .Pos.Offset as $o | [$o] + innermost($o) ),
      ( $all[] | select(.Type? == "CallExpr" and ((.Args // []) | length) > 0)
        | (.Args | map(wstr) | strip(0)) as [$n, $w]
        | ($w[0] // "") as $cmd
        | $w[1:] as $rest
        | select(
            (($cmd == "unset" or $cmd == "wait") and any($rest[]; lc_name))
            or ($n > 0 and ($cmd | IN("export", "declare", "local", "typeset", "readonly"))
                and ([$rest[] | lc_word] as $lw
                  | ($lw | length) > 0
                    and ($lw | last | IN("LC_ALL=C", "LC_ALL=C.UTF-8") | not)))
            or (($cmd | IN("mapfile", "readarray", "getopts", "read"))
                and any($rest[]; lc_word != null))
            or ($cmd == "printf"
                and (any($rest[]; startswith("-vLC_ALL"))
                  or ([range(0; ($rest | length) - 1) | select($rest[.] == "-v" and ($rest[. + 1] | lc_name))] | length > 0))))
        | .Pos.Offset as $o | [$o] + innermost($o) ),
      ( $all[] | select(.Type? == "LetClause" or .Type? == "ArithmCmd" or .Type? == "ArithmExp"
            or (.Type? == "ForClause" and .Loop.Type? == "CStyleLoop"))
        | select([.. | objects | select(.Type? == "Lit" and .Value? == "LC_ALL")] | length > 0)
        | .Pos.Offset as $o | [$o] + innermost($o) ),
      ( $all[] | select(.N? != null and .N.Value? == "{LC_ALL}")
        | .N.Pos.Offset as $o | [$o] + innermost($o) ),
      ( $all[] | select(.Type? == "ForClause")
        | .Loop | select(.Type? == "WordIter" and .Name.Value? == "LC_ALL")
        | .Name.Pos.Offset as $o | [$o] + innermost($o) ) ] as $cancels
    | def cancelled($s; $at): any($cancels[];
        .[0] > $s and .[0] < $at and (.[1] == null or (.[1] <= $at and $at < .[2])));
    # A C locale set by a statement of its own scope: a top-level export,
    # or a local that is a direct statement of its function body.
    [ .Stmts[]? | select(.Background | not) | .Cmd
        | select(.Type? == "DeclClause" and .Variant.Value? == "export")
        | select(last_c) | .Pos.Offset ] as $file_safe
    | [ $all[] | select(.Type? == "FuncDecl") | . as $f
        | .Body.Cmd.Stmts[]? | select(.Background | not) | .Cmd
        | select(.Type? == "DeclClause" and .Variant.Value? == "local")
        | select(last_c)
        | [$f.Pos.Offset, $f.End.Offset, .Pos.Offset] ] as $safe_spans
    | def safe_at($at): any($file_safe[]; . < $at and (cancelled(.; $at) | not))
        or any($safe_spans[]; .[0] <= $at and $at < .[1] and .[2] < $at
          and (cancelled(.[2]; $at) | not));
    ( $all[] | select(.Type? == "BinaryTest")
        | .Pos.Offset as $at
        | [ "T", .Pos.Line, .X.End.Offset, .Y.Pos.Offset, .Y.End.Offset,
            (if safe_at($at) then 1 else 0 end) ] ),
      ( $all[] | select(.Type? == "DeclClause" or .Type? == "CallExpr")
        | assigns | select(.Value? != null and .Value.Pos? != null)
        | [ "A", .Name.Value, .Value.Pos.Offset, .Value.End.Offset ] ),
      ( $all[] | select(.Type? == "ForClause")
        | .Loop | select(.Type? == "WordIter")
        | .Name.Value as $n | .Items[]?
        | [ "A", $n, .Pos.Offset, .End.Offset ] )
      ,
      ( $all[] | select(.Type? == "CallExpr" and ((.Args // []) | length) > 0)
        | . as $call
        | [.Args[] | wstr] as $w
        | lead($w; 0) as $k
        | select($k >= 0 and ($w[$k] | IN("grep", "egrep", "fgrep", "sed")))
        | ([range(0; $k) | select($w[.] | startswith("LC_ALL="))] | last) as $env_at
        # An `env` unset of LC_ALL: `-u NAME` (alone or ending a cluster of
        # `-i`, `-0`, `-v`), `-uNAME`, `--unset NAME`, `--unset=NAME`.
        | ([range(0; $k) | select(
              ($w[.] | IN("--unset=LC_ALL") or test("^-[i0v]*uLC_ALL$"))
              or (($w[.] | test("^-[i0v]*u$") or . == "--unset") and $w[. + 1] == "LC_ALL"))]
            | last) as $unset_at
        | ([$call.Assigns[]? | select(.Name.Value? == "LC_ALL")] | last) as $pre_lc
        | (if $unset_at != null and ($env_at == null or $env_at < $unset_at) then false
            elif $env_at != null then ($w[$env_at][7:] | IN("C", "C.UTF-8"))
            elif $pre_lc != null then ($pre_lc | c_locale)
            else safe_at($call.Pos.Offset) end) as $safe
        | (if $w[$k] == "sed" then
            reduce range($k + 1; $w | length) as $i (
              {mode: "S", pats: [], ops: [], unres: 0, hasf: false, dd: false, skip: null};
              sed_operand($call.Args[$i]; $w[$i]))
          else
            ({"grep": "G", "egrep": "E", "fgrep": "F"}[$w[$k]]) as $mode
            | reduce range($k + 1; $w | length) as $i (
                {mode: $mode, pats: [], ops: [], unres: 0, hasf: false, dd: false, skip: null};
                operand($call.Args[$i]; $w[$i]))
          end) as $st
        | ($st.pats | if length > 0 then . elif $st.hasf then [] else $st.ops[0:1] end) as $p
        | select(($p | length) > 0 or $st.unres == 1)
        | (if ($p | length) == 0 then [[-1, -1]] else $p end)[]
        | [ (if $st.mode == "S" then "S" else "G" end), $call.Pos.Offset, $call.Pos.Line, $st.mode,
            (if $safe then 1 else 0 end), $st.unres, .[0], .[1], (.[2] // 0) ] )
    | @tsv' <<<"${tree}"
}

# @description Print the first range between ASCII letters or digits
# inside a bracket expression of a regex text, or nothing. `[:alpha:]`
# style classes, equivalence classes and collating symbols inside a
# bracket are skipped; a backslash before `[` outside one makes it
# literal.
# @arg $1 regex text
function first_range() {
  local -r re="$1"
  local i=0 n=${#re} c j k
  while ((i < n)); do
    c="${re:i:1}"
    # shellcheck disable=SC1003 # a single backslash, which shfmt writes this way
    if [[ ${c} == '\' ]]; then
      i=$((i + 2))
      continue
    fi
    if [[ ${c} != '[' ]]; then
      i=$((i + 1))
      continue
    fi
    j=$((i + 1))
    [[ ${re:j:1} == '^' ]] && j=$((j + 1))
    [[ ${re:j:1} == ']' ]] && j=$((j + 1))
    while ((j < n)) && [[ ${re:j:1} != ']' ]]; do
      if [[ ${re:j:2} == '[:' || ${re:j:2} == '[=' || ${re:j:2} == '[.' ]]; then
        k="${re:j+1:1}"
        j=$((j + 2))
        while ((j < n)) && [[ ${re:j:2} != "${k}]" ]]; do j=$((j + 1)); done
        j=$((j + 2))
        continue
      fi
      if [[ ${re:j+1:1} == '-' && ${re:j:1} == [[:alnum:]] && ${re:j+2:1} == [[:alnum:]] ]]; then
        printf '%s\n' "${re:j:3}"
        return 0
      fi
      j=$((j + 1))
    done
    i=$((j + 1))
  done
}

# @description Print the first bracket of a grep regex text that GNU grep
# matches by the locale's collation, or nothing: a bracket holding a range
# between ASCII letters or digits that is negated or has a letter
# endpoint. A positive bracket whose ranges all run between digits
# matches ASCII digits only in every locale. Classes, equivalence classes
# and collating symbols inside a bracket are skipped; a backslash before
# `[` outside one makes it literal.
# @arg $1 regex text
function grep_range() {
  local -r re="$1"
  local i=0 n=${#re} c j k negated ranged lettered
  while ((i < n)); do
    c="${re:i:1}"
    # shellcheck disable=SC1003 # a single backslash, which shfmt writes this way
    if [[ ${c} == '\' ]]; then
      i=$((i + 2))
      continue
    fi
    if [[ ${c} != '[' ]]; then
      i=$((i + 1))
      continue
    fi
    j=$((i + 1))
    negated=0 ranged=0 lettered=0
    if [[ ${re:j:1} == '^' ]]; then
      negated=1
      j=$((j + 1))
    fi
    [[ ${re:j:1} == ']' ]] && j=$((j + 1))
    while ((j < n)) && [[ ${re:j:1} != ']' ]]; do
      if [[ ${re:j:2} == '[:' || ${re:j:2} == '[=' || ${re:j:2} == '[.' ]]; then
        k="${re:j+1:1}"
        j=$((j + 2))
        while ((j < n)) && [[ ${re:j:2} != "${k}]" ]]; do j=$((j + 1)); done
        j=$((j + 2))
        continue
      fi
      if [[ ${re:j+1:1} == '-' && ${re:j:1} == [[:alnum:]] && ${re:j+2:1} == [[:alnum:]] ]]; then
        ranged=1
        [[ ${re:j:1} == [0123456789] && ${re:j+2:1} == [0123456789] ]] || lettered=1
        j=$((j + 3))
        continue
      fi
      j=$((j + 1))
    done
    if ((ranged && (negated || lettered))); then
      printf '%s\n' "${re:i:j+1-i}"
      return 0
    fi
    i=$((j + 1))
  done
}

# @description Follow a regex text through the same-file assignments in
# the caller's `values` map, three levels deep. Sets FOLLOW_RANGE to the
# first range the classifier prints (empty for none), FOLLOW_VIA to the
# variable it came through (empty when the text itself holds it), and
# FOLLOW_UNRES to 1 when the text or a value it reached holds an
# expansion the lint cannot follow or names a variable with no
# assignment in the file.
# @arg $1 classifier: `first_range` or `grep_range`
# @arg $2 regex text
function follow_range() {
  local -r classify="$1" regex="$2"
  local pending="${regex}" seen=' ' depth name next
  FOLLOW_RANGE="$("${classify}" "${regex}")"
  FOLLOW_VIA=''
  FOLLOW_UNRES=0
  [[ ${regex} =~ ${OPAQUE_RE} ]] && FOLLOW_UNRES=1
  for ((depth = 1; depth <= 3; depth++)); do
    [[ -z ${FOLLOW_RANGE} ]] || break
    next=''
    while [[ ${pending} =~ \$\{?([A-Za-z_][A-Za-z0-9_]*) ]]; do
      name="${BASH_REMATCH[1]}"
      pending="${pending#*"${BASH_REMATCH[0]}"}"
      [[ ${seen} == *" ${name} "* ]] && continue
      seen+="${name} "
      if [[ -z ${values[${name}]:-} ]]; then
        FOLLOW_UNRES=1
        continue
      fi
      [[ ${values[${name}]} =~ ${OPAQUE_RE} ]] && FOLLOW_UNRES=1
      FOLLOW_RANGE="$("${classify}" "${values[${name}]}")"
      if [[ -n ${FOLLOW_RANGE} ]]; then
        FOLLOW_VIA="${name}"
        break
      fi
      next+="${values[${name}]}"
    done
    pending="${next}"
  done
  return 0
}

# @description Succeed when a word is a bare expansion of a variable
# (`$name` or `${name}`, alone or in double quotes) that one of its
# same-file values, quotes removed, sets to text starting with `-`: in an
# operand position grep reads it as an option, so the pattern is another
# word. Reads the caller's `values` map.
# @arg $1 word text
function option_variable() {
  local word="$1" name v
  word="${word#\"}"
  word="${word%\"}"
  [[ ${word} =~ ^\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))$ ]] || return 1
  name="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
  while IFS= read -r v; do
    v="${v//\'/}"
    v="${v//\"/}"
    [[ ${v} == -* ]] && return 0
  done <<<"${values[${name}]:-}"
  return 1
}

# @description Report whether a file holds a match for the given grep
# options and pattern. grep's status 2 is a file it could not read, and
# ends the run: read as "no match", it would skip the file as holding no
# sign of a finding while still counting it as scanned.
# @arg $1 file path
# @arg $@ grep options and pattern, ending with `--` and the pattern
# @exitcode 0 the file holds a match
# @exitcode 1 it does not
function file_holds() {
  local -r file="$1"
  shift
  local rc=0
  grep --quiet "$@" "${file}" 2>/dev/null || rc=$?
  if ((rc > 1)); then
    log_err "cannot read ${file}"
    exit 2
  fi
  return "${rc}"
}

function main() {
  local -a files=()
  glob_into files 'scripts, script libraries and harnesses' \
    "${SCRIPTS_DIR}/*.sh" "${SCRIPTS_DIR}/lib/*.sh" "${TESTS_DIR}/*.sh"

  local file text records kind f2 f3 f4 f5 f6 f7 f8 f9 op regex value line cid markers rc
  local found=0 tests=0 resolved=0 c_locale=0
  local not_regex=0 tool
  local -A n_calls=([grep]=0 [sed]=0) n_c_locale=([grep]=0 [sed]=0)
  local -A n_unresolved=([grep]=0 [sed]=0) n_marked=([grep]=0 [sed]=0)
  for file in "${files[@]}"; do
    # A file is parsed only if it can hold a finding: a `~` (the `=~`
    # operator, whose `=` and `~` a backslash-newline can separate), a
    # marker, or a grep or sed word beside a bracket range, since a grep
    # or sed range is read only from the file's own text. The bracket
    # text may hold classes, equivalence classes, collating symbols or a
    # leading `]` before the range, as grep_range reads them. The match
    # is line by line, so a range split by a backslash-newline inside
    # its bracket is not seen here, and a file holding no other sign is
    # not parsed.
    if ! file_holds "${file}" --fixed-strings -- '~' &&
      ! file_holds "${file}" --fixed-strings -- "${MARKER}" &&
      ! { file_holds "${file}" --word-regexp --regexp=grep --regexp=egrep --regexp=fgrep --regexp=sed -- &&
        file_holds "${file}" --extended-regexp -- \
          '\[\^?\]?([^]]|\[[:=.][^]]*[:=.]\])*[[:alnum:]]-[[:alnum:]]'; }; then
      continue
    fi
    text="$(<"${file}")"
    if ! records="$(records_of "${file}")"; then
      exit 2
    fi
    local -A values=() call_line=() call_mode=() call_c=() call_unres=() call_range=() call_via=() call_tool=()
    local -A marker_ok=() marker_used=()
    local -a findings=()
    while IFS=$'\t' read -r kind f2 f3 f4 f5 f6 f7 f8 f9; do
      [[ ${kind} == A ]] || continue
      value="${text:f3:f4-f3}"
      values["${f2}"]+="${value//\\$'\n'/}"$'\n'
    done <<<"${records}"

    while IFS=$'\t' read -r kind f2 f3 f4 f5 f6 f7 f8 f9; do
      [[ ${kind} == T ]] || continue
      op="${text:f3:f4-f3}"
      op="${op//\\/}"
      op="${op//[[:space:]]/}"
      [[ ${op} == '=~' ]] || continue
      tests=$((tests + 1))
      if ((f6)); then
        c_locale=$((c_locale + 1))
        continue
      fi
      regex="${text:f4:f5-f4}"
      regex="${regex//\\$'\n'/}"
      follow_range first_range "${regex}"
      [[ ${regex} =~ \$\{?[A-Za-z_] ]] && resolved=$((resolved + 1))
      [[ -n ${FOLLOW_RANGE} ]] || continue
      if [[ -n ${FOLLOW_VIA} ]]; then
        findings+=("${f2}"$'\t'"${file}:${f2}: regex range ${FOLLOW_RANGE} (through ${FOLLOW_VIA}) follows the locale")
      else
        findings+=("${f2}"$'\t'"${file}:${f2}: regex range ${FOLLOW_RANGE} follows the locale")
      fi
    done <<<"${records}"

    # G and S records: call id, line, mode, C locale, unresolved,
    # pattern start and end (-1 when the call has no pattern operand),
    # option position.
    while IFS=$'\t' read -r kind f2 f3 f4 f5 f6 f7 f8 f9; do
      [[ ${kind} == G || ${kind} == S ]] || continue
      call_tool["${f2}"]="${kind}"
      call_line["${f2}"]="${f3}"
      call_mode["${f2}"]="${f4}"
      call_c["${f2}"]="${f5}"
      ((f6)) && call_unres["${f2}"]=1
      ((f7 >= 0)) || continue
      [[ -z ${call_range[${f2}]:-} ]] || continue
      regex="${text:f7:f8-f7}"
      regex="${regex//\\$'\n'/}"
      if ((f9)) && option_variable "${regex}"; then
        call_unres["${f2}"]=1
        continue
      fi
      follow_range grep_range "${regex}"
      ((FOLLOW_UNRES)) && call_unres["${f2}"]=1
      if [[ -n ${FOLLOW_RANGE} ]]; then
        call_range["${f2}"]="${FOLLOW_RANGE}"
        call_via["${f2}"]="${FOLLOW_VIA}"
      fi
    done <<<"${records}"

    rc=0
    markers="$(grep --line-number --extended-regexp --regexp="${MARKER_LINE_RE}" -- "${file}")" || rc=$?
    if ((rc > 1)); then
      log_err "cannot read ${file}"
      exit 2
    fi
    while IFS=: read -r line value; do
      [[ -n ${line} ]] || continue
      [[ ${value} =~ ${MARKER_LINE_RE}(.*)$ ]] || continue
      value="${BASH_REMATCH[2]}"
      value="${value#:}"
      value="${value#"${value%%[![:space:]]*}"}"
      if [[ -z ${value} ]]; then
        findings+=("${line}"$'\t'"${file}:${line}: marker has no reason")
      else
        marker_ok["${line}"]=1
      fi
    done <<<"${markers}"

    for cid in "${!call_line[@]}"; do
      tool="grep"
      [[ ${call_tool[${cid}]} == S ]] && tool="sed"
      n_calls[${tool}]=$((n_calls[${tool}] + 1))
      line="${call_line[${cid}]}"
      if [[ ${call_mode[${cid}]} == F || ${call_mode[${cid}]} == P ]]; then
        not_regex=$((not_regex + 1))
      elif [[ ${call_c[${cid}]} == 1 ]]; then
        n_c_locale[${tool}]=$((n_c_locale[${tool}] + 1))
      elif [[ -n ${call_range[${cid}]:-} ]]; then
        if [[ -n ${marker_ok[$((line - 1))]:-} ]]; then
          n_marked[${tool}]=$((n_marked[${tool}] + 1))
          marker_used[$((line - 1))]=1
        elif [[ -n ${call_via[${cid}]} ]]; then
          findings+=("${line}"$'\t'"${file}:${line}: ${tool} range ${call_range[${cid}]} (through ${call_via[${cid}]}) follows the locale")
        else
          findings+=("${line}"$'\t'"${file}:${line}: ${tool} range ${call_range[${cid}]} follows the locale")
        fi
      elif [[ -n ${call_unres[${cid}]:-} ]]; then
        n_unresolved[${tool}]=$((n_unresolved[${tool}] + 1))
      fi
    done
    for line in "${!marker_ok[@]}"; do
      [[ -n ${marker_used[${line}]:-} ]] ||
        findings+=("${line}"$'\t'"${file}:${line}: marker exempts nothing")
    done

    if ((${#findings[@]})); then
      found=$((found + ${#findings[@]}))
      printf '%s\n' "${findings[@]}" |
        sort --field-separator=$'\t' --key=1,1n --key=2 |
        cut --fields=2- >&2
    fi
    unset values call_line call_mode call_c call_unres call_range call_via call_tool marker_ok marker_used findings
  done

  if ((found)); then
    printf '\n%d finding(s). A range follows the locale: under en_US.UTF-8 [0-9] in a\n' "${found}" >&2
    printf 'bash regex also matches digits such as U+0663 and U+FF15. Spell the class\n' >&2
    printf 'out ([0123456789]) or match through ascii_match (scripts/lib/ascii-match.sh).\n' >&2
    printf 'GNU grep and sed keep a positive [0-9] ASCII but follow the locale for a\n' >&2
    printf 'letter, mixed or negated range: run the call under LC_ALL=C, or mark the\n' >&2
    printf 'line above it with: # %s: <reason>\n' "${MARKER}" >&2
    exit 1
  fi
  printf 'regex-range-ascii: ok — scanned %d file(s), %d =~ test(s), %d with a regex in a variable, %d under a C locale; %d grep call(s), %d not regex (-F/-P), %d under a C locale, %d unresolved, %d marked; %d sed call(s), %d under a C locale, %d unresolved, %d marked\n' \
    "${#files[@]}" "${tests}" "${resolved}" "${c_locale}" \
    "${n_calls[grep]}" "${not_regex}" "${n_c_locale[grep]}" "${n_unresolved[grep]}" "${n_marked[grep]}" \
    "${n_calls[sed]}" "${n_c_locale[sed]}" "${n_unresolved[sed]}" "${n_marked[sed]}"
}

main "$@"
