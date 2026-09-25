# scripts/_scripts_reference_roundtrip.py
#
# The checker behind scripts/check-scripts-reference-roundtrip.sh, which
# enumerates the files and passes them here. It reads every script header
# on its own terms, renders the committed docs/reference/scripts.md with
# python-markdown and the extensions mkdocs.yml loads, and asserts that each
# piece of header text is visible in its script's entry. It shares no code with scripts/_script_docs.awk on
# purpose: a checker that parsed headers with the generator's own parser
# would agree with every text that parser drops.
#
# Usage: python3 _scripts_reference_roundtrip.py DOC MKDOCS --entry F... --lib F...
# Exit 0 when every unit is published intact, 3 on any finding, 2 when the
# check cannot run: the page or its markers are missing, mkdocs.yml loads an
# extension this checker cannot configure, a header is not UTF-8, or the
# files named hold no annotation at all. Findings use 3, not 1, because
# Python itself exits 1 on a syntax error or an uncaught exception, and the
# wrapper must not read either as findings.

import html.parser
import os
import re
import sys

try:
    import markdown
except ImportError:
    print("scripts-reference-roundtrip: python-markdown is not importable", file=sys.stderr)
    sys.exit(2)

PROG = "scripts-reference-roundtrip"

# The tags the generator renders or declares. A line opening with any other
# `@word` is header text, and it has to publish like any other text.
RENDERED = ("description", "arg", "option", "example", "exitcode", "stdout")
DECLARED = ("generates-block", "generates")
KNOWN = RENDERED + DECLARED
TAG_LINE = re.compile(r"^#[ \t]+@[A-Za-z]")
# Several tags may share a line when two or more blanks separate them.
TAG_SPLIT = re.compile(r"[ \t]{2,}(?=@(?:%s)(?![A-Za-z-]))" % "|".join(KNOWN))
TAG = re.compile(r"^@([A-Za-z-]+)[ \t]*(.*)$", re.S)
SHELLCHECK = re.compile(r"^#[ \t]+shellcheck[ \t]")
FUNC = re.compile(r"^(?:function[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(\)")
# House style for an annotation is `# @tag`, one blank after the hash. A
# comment that indents an `@tag` further is prose about the tag.
STRAY_TAG = re.compile(r"^# @(?:%s)(?:[ \t]|$)" % "|".join(RENDERED))
BOUND_OPENER = re.compile(r"^#[ \t]+@description(?![A-Za-z-])")
# Indented: two or more leading blanks, or a leading tab.
INDENTED = re.compile(r"^(?: {2,}|\t| +\t)[ \t]*\S")


def comment_body(raw):
    return re.sub(r"^#[ \t]?", "", raw, count=1)


def blank(text):
    return text.strip() == ""


class Unit:
    def __init__(self, tag, head, line):
        self.tag, self.head, self.line, self.lines = tag, head, line, []

    def closes_on_blank(self):
        return self.tag in ("arg", "option", "exitcode", "stdout")

    def expected(self):
        """The text a reader must be able to see for this unit.

        Prose is Markdown on the page, so its code spans show without their
        backticks; a colon-led indented run and an @example are fenced, so
        they show exactly as written.
        """
        if self.tag in ("arg", "option", "exitcode"):
            parts = self.head.split(None, 1)
            name = parts[0] if parts else ""
            rest = parts[1] if len(parts) > 1 else ""
            return name + " — " + prose([rest] + self.lines)
        if self.tag in DECLARED:
            return prose(self.lines)
        if self.tag == "example":
            return " ".join([self.head] + self.lines)
        if self.tag == "description":
            lines = [self.head] + self.lines
            out, i = [], 0
            for start, end, fenced in run_spans(lines):
                out.append(prose(lines[i:start]))
                out.append(" ".join(lines[start:end]) if fenced else prose(lines[start:end]))
                i = end
            out.append(prose(lines[i:]))
            return " ".join(out)
        return prose([self.head] + self.lines)

    def label(self):
        return "@" + self.tag if self.tag != "?" else "header text"


def units_of(run, findings, rel):
    """Split one comment run into units. run: [(lineno, raw)]."""
    units, cur, started = [], None, False
    for no, raw in run:
        if SHELLCHECK.match(raw):
            continue
        if TAG_LINE.match(raw):
            started = True
            text = re.sub(r"^#[ \t]+", "", raw, count=1)
            for seg in TAG_SPLIT.split(text):
                m = TAG.match(seg)
                if m and m.group(1) in KNOWN:
                    cur = Unit(m.group(1), m.group(2), no)
                    units.append(cur)
                elif cur is not None:
                    cur.lines.append(seg)
                else:
                    cur = Unit("?", seg, no)
                    units.append(cur)
            continue
        body = comment_body(raw)
        if not started:
            text = body.strip()
            # The path line and the shebang are not prose.
            if text and text != rel and not (no == 1 and raw.startswith("#!")):
                findings.append((rel, no, "header text before the first tag is not published: " + text))
            continue
        if cur.closes_on_blank() and blank(body):
            # A blank comment line closes the annotation; what follows is
            # a further paragraph of the description.
            cur = Unit("description", "", no)
            cur.resumed = True
            units.append(cur)
            continue
        if getattr(cur, "resumed", False) and not cur.lines:
            if blank(body):
                continue
            # A resumed paragraph is reported at its first line of text.
            cur.line = no
        cur.lines.append(body)
    return [u for u in units if not (getattr(u, "resumed", False) and not "".join(u.lines).strip())]


def read_lines(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().split("\n")
    except UnicodeDecodeError:
        print(f"{PROG}: {path} is not UTF-8", file=sys.stderr)
        sys.exit(2)
    except OSError as err:
        print(f"{PROG}: cannot read {path}: {err.strerror}", file=sys.stderr)
        sys.exit(2)


def extract(path, library, findings):
    """Return [(section key, unit)] for one file; append unreached text to findings."""
    lines = read_lines(path)
    numbered = list(enumerate(lines, 1))
    base = os.path.basename(path)
    key = ("scripts/lib/" if library else "scripts/") + base
    i = 0
    while i < len(lines) and lines[i].startswith("#") and not blank(lines[i]):
        i += 1
    out = [(key, u) for u in units_of(numbered[:i], findings, key)]
    rest = numbered[i:]
    if not library:
        # An annotation in a comment block after the first blank line never
        # reaches the header, so it is not published.
        for no, raw in rest:
            if blank(raw):
                continue
            if not raw.startswith("#"):
                break
            if STRAY_TAG.match(raw):
                findings.append((key, no, "annotation after the header's first blank line is not published: " + raw.strip()))
        return out
    j = 0
    while j < len(rest):
        no, raw = rest[j]
        if BOUND_OPENER.match(raw):
            block, k = [], j
            while k < len(rest) and (rest[k][1].startswith("#") or blank(rest[k][1])):
                if rest[k][1].startswith("#"):
                    block.append(rest[k])
                k += 1
            fn = FUNC.match(rest[k][1]) if k < len(rest) else None
            if fn:
                out += [(key + "::" + fn.group(1), u) for u in units_of(block, findings, key)]
            else:
                findings.append((key, no, "@description block is not followed by a function line, so it is not published"))
            j = k
            continue
        if STRAY_TAG.match(raw):
            findings.append((key, no, "annotation outside a function's @description block is not published: " + raw.strip()))
        j += 1
    return out


class PageText(html.parser.HTMLParser):
    """Each H3 script and H4 function entry as an ordered list of blocks.

    A block is (region, kind, text): kind is "p", "li" or "pre", and region
    is "description" until a paragraph holding only a bold list label
    ("Args:", "Options:", "Exit codes:", "Stdout:") switches it to that
    label. That is the order the generator emits an entry in, so a unit can
    be matched against its own part of the entry rather than anywhere in it.
    """

    LABELS = {"Args:": "arg", "Options:": "option", "Exit codes:": "exitcode", "Stdout:": "stdout"}
    BLOCKS = ("p", "li", "pre")

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.entries = {}
        self.key, self.script, self.region = None, None, "description"
        self.heading, self.heading_text = None, []
        self.block, self.block_text = None, []
        self.in_strong, self.strong_text = False, []

    def handle_starttag(self, tag, attrs):
        if tag in ("h2", "h3", "h4"):
            self.heading, self.heading_text = tag, []
        elif tag in self.BLOCKS and self.block is None:
            self.block, self.block_text = tag, []
            self.strong_text = []
        elif tag == "strong":
            self.in_strong = True

    def handle_endtag(self, tag):
        if tag == "strong":
            self.in_strong = False
        if tag == self.heading:
            # toc's permalink adds a pilcrow to every heading.
            title = "".join(self.heading_text).replace("¶", "").strip()
            if tag == "h2":
                self.key = self.script = None
            elif tag == "h3":
                self.key = self.script = title
            else:
                fn = title[:-2] if title.endswith("()") else title
                self.key = (self.script or "") + "::" + fn
            if self.key is not None:
                self.entries.setdefault(self.key, [])
            self.region = "description"
            self.heading = None
        elif tag == self.block:
            text = "".join(self.block_text)
            # A label is the generator's bold paragraph; a description line
            # that merely reads "Exit codes:" is prose.
            label = "".join(self.strong_text).strip()
            if tag == "p" and label in self.LABELS and label == text.strip():
                self.region = self.LABELS[text.strip()]
            elif self.key is not None:
                self.entries[self.key].append((self.region, tag, text))
            self.block = None

    def handle_data(self, data):
        if self.heading:
            self.heading_text.append(data)
        elif self.block is not None:
            self.block_text.append(data)
            if self.in_strong:
                self.strong_text.append(data)


def fence_code_format(*args, **kwargs):
    from pymdownx.superfences import fence_code_format as real
    return real(*args, **kwargs)


def site_extensions(mkdocs_yml):
    """The extensions mkdocs.yml loads, configured as it configures them.

    Several of them change text, not just markup: inlinehilite, details and
    tabbed rewrite their own syntax, and snippets replaces a line with a
    file. So an extension this checker does not know is a could-not-run,
    not something to skip.
    """
    base = os.path.dirname(os.path.abspath(mkdocs_yml))
    known = {
        "admonition": {}, "attr_list": {}, "md_in_html": {}, "tables": {},
        "toc": {"permalink": True},
        "pymdownx.details": {},
        "pymdownx.highlight": {"anchor_linenums": True, "line_spans": "__span", "pygments_lang_class": True},
        "pymdownx.inlinehilite": {},
        "pymdownx.snippets": {"base_path": [base]},
        "pymdownx.tabbed": {"alternate_style": True},
        "pymdownx.superfences": {"custom_fences": [{"name": "mermaid", "class": "mermaid", "format": fence_code_format}]},
    }
    names, inside = [], False
    for line in read_lines(mkdocs_yml):
        if re.match(r"^markdown_extensions:[ \t]*$", line):
            inside = True
            continue
        if inside and re.match(r"^\S", line):
            break
        m = re.match(r"^  - ([A-Za-z0-9_.]+):?[ \t]*$", line) if inside else None
        if m:
            names.append(m.group(1))
    if not names:
        print(f"{PROG}: {mkdocs_yml} lists no markdown_extensions", file=sys.stderr)
        sys.exit(2)
    unknown = [n for n in names if n not in known]
    if unknown:
        print(f"{PROG}: {mkdocs_yml} loads {', '.join(unknown)}, which this checker does not configure", file=sys.stderr)
        sys.exit(2)
    return names, {n: known[n] for n in names}


def render(doc, mkdocs_yml):
    names, configs = site_extensions(mkdocs_yml)
    lines = read_lines(doc)
    try:
        begin = lines.index("<!-- BEGIN scripts-reference -->")
        end = lines.index("<!-- END scripts-reference -->", begin)
    except ValueError:
        print(f"{PROG}: {doc} lacks the scripts-reference BEGIN/END markers", file=sys.stderr)
        sys.exit(2)
    block = "\n".join(lines[begin + 1:end]).replace("{% raw %}", "").replace("{% endraw %}", "")
    html_out = markdown.markdown(block, extensions=names, extension_configs=configs)
    page = PageText()
    page.feed(html_out)
    page.close()
    return page.entries


CODE_SPAN = re.compile(r"(`+)(.+?)\1", re.S)


# A list marker standing alone as a word: the renderer shows it as a bullet
# or a number, not as text.
LIST_MARKER = re.compile(r"(?:(?<=\s)|^)(?:[-*+]|[0-9]+[.)])(?=\s)")


def prose(lines):
    """Header prose as the page shows it: a code span loses its backticks
    and the blanks at its edges. A backtick that opens no span stays."""
    return CODE_SPAN.sub(lambda m: m.group(2).strip(), " ".join(lines))


def normalize(text):
    # Text is compared as words, so line-join, indent and fence markers fall
    # away, and a list marker becomes a bullet. The same transform runs on
    # both sides.
    return re.sub(r"\s+", " ", LIST_MARKER.sub(" ", text)).strip()


def contains(have, want, start=0):
    """Offset just past `want` found as whole words in `have`, or -1."""
    at = (" " + have + " ").find(" " + want + " ", start)
    return -1 if at < 0 else at + len(want)


def run_spans(lines):
    """(start, end, colon_led) for every indented run; a blank line inside a
    run belongs to it. A run is a deliberate block when the last non-blank
    line before it ends in a colon."""
    spans, i = [], 0
    while i < len(lines):
        if not INDENTED.match(lines[i]):
            i += 1
            continue
        lead_in = next((x for x in reversed(lines[:i]) if not blank(x)), "")
        j = i
        while j < len(lines):
            if blank(lines[j]):
                k = j
                while k < len(lines) and blank(lines[k]):
                    k += 1
                if k < len(lines) and INDENTED.match(lines[k]):
                    j = k
                    continue
                break
            if not INDENTED.match(lines[j]):
                break
            j += 1
        spans.append((i, j, bool(re.search(r":[ \t]*$", lead_in))))
        i = j
    return spans


def colon_led_runs(unit):
    """Each deliberate block as the lines its fence must hold: a tab in the
    indent is two spaces and an odd indent rounds up to even, which is how
    the generator writes a fence."""
    lines = [unit.head] + unit.lines
    runs = []
    for start, end, fenced in run_spans(lines):
        if not fenced:
            continue
        run = []
        for line in lines[start:end]:
            if blank(line):
                continue
            lead = re.match(r"^[ \t]*", line).group(0)
            indent = lead.replace("\t", "  ")
            if len(indent) % 2:
                indent = " " + indent
            run.append(indent + line[len(lead):].rstrip())
        runs.append(run)
    return runs


def pre_lines(text):
    return [x.rstrip() for x in text.split("\n") if x.strip()]


def first_divergence(want, have):
    words = want.split(" ")
    lo, hi = 0, len(words)
    # Longest prefix still present; presence is monotone in prefix length.
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if contains(have, " ".join(words[:mid])) >= 0:
            lo = mid
        else:
            hi = mid - 1
    return lo, len(words), " ".join(words[lo:lo + 12])


def main(argv):
    if len(argv) < 2:
        print(f"usage: {PROG} DOC MKDOCS --entry F... --lib F...", file=sys.stderr)
        return 2
    doc, mkdocs_yml, files, mode = argv[1], argv[2] if len(argv) > 2 else "", [], None
    for arg in argv[3:]:
        if arg in ("--entry", "--lib"):
            mode = arg
        elif mode is None:
            print(f"{PROG}: file {arg} given before --entry or --lib", file=sys.stderr)
            return 2
        else:
            files.append((arg, mode == "--lib"))
    entries = render(doc, mkdocs_yml)

    findings, n_units, n_runs = [], 0, 0
    for path, library in files:
        unreached = []
        units = extract(path, library, unreached)
        findings += [f"{key}:{no}: {msg}" for key, no, msg in unreached]
        has_example = {key for key, unit in units if unit.tag == "example"}
        desc_from = {}  # key -> offset the next description unit must start at
        for key, unit in units:
            want = normalize(unit.expected())
            if not want:
                continue
            n_units += 1
            if key not in entries:
                findings.append(f"{key}: {unit.label()} (line {unit.line}) has no entry on the page")
                continue
            blocks = entries[key]
            # The generator writes the @example fence last, so when there is
            # one, the entry's last block is it and not description.
            example = blocks[-1] if key in has_example and blocks and blocks[-1][1] == "pre" else None
            desc_blocks = [b for b in blocks if b[0] == "description" and b is not example]
            where = f"{key}: {unit.label()} (line {unit.line})"
            if unit.tag in PageText.LABELS.values():
                items = [normalize(b[2]) for b in blocks if b[0] == unit.tag and b[1] == "li"]
                if want not in items:
                    got, total, frag = first_divergence(want, " | ".join(items))
                    if got == total:
                        findings.append(f"{where} is not one item of its list: its text appears only inside other text")
                    else:
                        findings.append(f"{where} is not one item of its list: published {got} of {total} words; dropped or altered from: {frag!r}")
                continue
            if unit.tag == "example":
                have = normalize(example[2]) if example else ""
                if want != have:
                    got, total, frag = first_divergence(want, have)
                    findings.append(f"{where} is not the entry's example block: published {got} of {total} words; dropped or altered from: {frag!r}")
                continue
            if unit.tag == "description":
                # Description units appear in source order, so each one is
                # searched for after the end of the one before it.
                have = normalize(" ".join(b[2] for b in desc_blocks))
                start = desc_from.get(key, 0)
                end = contains(have, want, start)
                if end < 0:
                    got, total, frag = first_divergence(want, have[start:])
                    findings.append(f"{where} published {got} of {total} words; dropped or altered from: {frag!r}")
                else:
                    desc_from[key] = end
                pres = [pre_lines(b[2]) for b in desc_blocks if b[1] == "pre"]
                for run in colon_led_runs(unit):
                    n_runs += 1
                    if run not in pres:
                        findings.append(f"{key}: indented block (line {unit.line} description) is not exactly one preformatted block on the page, indentation included, starting {run[0].strip()[:60]!r}")
                continue
            # Text under a non-rendering tag, or a line opening with an
            # unknown tag, is required anywhere in the entry.
            have = normalize(" ".join(b[2] for b in blocks))
            if contains(have, want) < 0:
                got, total, frag = first_divergence(want, have)
                findings.append(f"{where} published {got} of {total} words; dropped or altered from: {frag!r}")
    if n_units == 0:
        print(f"{PROG}: no annotation text found in {len(files)} file(s)", file=sys.stderr)
        return 2
    if findings:
        for f in findings:
            print(f"{PROG}: {f}", file=sys.stderr)
        print(f"{PROG}: {len(findings)} finding(s): script header text that docs/reference/scripts.md does not show as written. "
              "Fix the generator (scripts/_script_docs.awk, scripts/refresh-scripts-reference.sh) or rewrite the header, "
              "then regenerate.", file=sys.stderr)
        return 3
    print(f"check-scripts-reference-roundtrip: ok — {len(files)} file(s), {n_units} annotation unit(s), "
          f"{n_runs} indented block(s) published intact")
    return 0


if __name__ == "__main__":
    # An uncaught exception exits 1, which reads as "findings". A checker
    # that crashed has not checked anything, so it is a could-not-run.
    try:
        status = main(sys.argv)
    except Exception as err:  # noqa: BLE001
        print(f"{PROG}: the checker failed: {type(err).__name__}: {err}", file=sys.stderr)
        status = 2
    sys.exit(status)
