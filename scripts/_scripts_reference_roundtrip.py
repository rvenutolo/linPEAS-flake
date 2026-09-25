# scripts/_scripts_reference_roundtrip.py
#
# The checker behind scripts/check-scripts-reference-roundtrip.sh, which
# enumerates the files and passes them here. It reads every script header
# on its own terms, renders the committed docs/reference/scripts.md the way
# the site builds it, and asserts that each piece of header text is visible
# in its script's entry. It shares no code with scripts/_script_docs.awk on
# purpose: a checker that parsed headers with the generator's own parser
# would agree with every text that parser drops.
#
# Usage: python3 _scripts_reference_roundtrip.py DOC --entry F... --lib F...
# Exit 0 when every unit is published intact, 1 on any finding, 2 when the
# check cannot run: the page or its markers are missing, a header is not
# UTF-8, or the files named hold no annotation at all.

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
        """The text a reader must be able to see for this unit."""
        if self.tag in ("arg", "option", "exitcode"):
            parts = self.head.split(None, 1)
            name = parts[0] if parts else ""
            rest = parts[1] if len(parts) > 1 else ""
            return name + " — " + " ".join([rest] + self.lines)
        if self.tag in DECLARED:
            return " ".join(self.lines)
        return " ".join([self.head] + self.lines)

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
            if text and not text.startswith("scripts/") and not raw.startswith("#!"):
                findings.append((rel, no, "header text before the first tag is not published: " + text))
            continue
        if cur.closes_on_blank() and blank(body):
            # A blank comment line closes the annotation; what follows is
            # a further paragraph of the description.
            cur = Unit("description", "", no)
            cur.resumed = True
            units.append(cur)
            continue
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
    """Visible text and preformatted blocks, per H3 script and H4 function."""

    BLOCK = {"p", "li", "pre", "div", "ul", "ol", "br", "tr", "td", "th", "blockquote"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.text, self.pre = {}, {}
        self.key, self.script, self.buf = None, None, []
        self.heading, self.heading_text = None, []
        self.in_pre, self.pre_buf = False, []

    def flush(self):
        if self.key is not None:
            self.text[self.key] = self.text.get(self.key, "") + "".join(self.buf)
        self.buf = []

    def handle_starttag(self, tag, attrs):
        if tag in ("h2", "h3", "h4"):
            self.flush()
            self.heading, self.heading_text = tag, []
        elif tag == "pre":
            self.in_pre, self.pre_buf = True, []
            self.buf.append(" ")
        elif tag in self.BLOCK:
            self.buf.append(" ")

    def handle_endtag(self, tag):
        if tag == self.heading:
            title = "".join(self.heading_text).strip()
            if tag == "h2":
                self.key = self.script = None
            elif tag == "h3":
                self.key = self.script = title
            else:
                fn = title[:-2] if title.endswith("()") else title
                self.key = (self.script or "") + "::" + fn
            self.heading = None
        elif tag == "pre":
            self.in_pre = False
            self.pre.setdefault(self.key, []).append("".join(self.pre_buf))
            self.buf.append(" ")
        elif tag in self.BLOCK:
            self.buf.append(" ")

    def handle_data(self, data):
        if self.heading:
            self.heading_text.append(data)
            return
        self.buf.append(data)
        if self.in_pre:
            self.pre_buf.append(data)


def render(doc):
    lines = read_lines(doc)
    try:
        begin = lines.index("<!-- BEGIN scripts-reference -->")
        end = lines.index("<!-- END scripts-reference -->", begin)
    except ValueError:
        print(f"{PROG}: {doc} lacks the scripts-reference BEGIN/END markers", file=sys.stderr)
        sys.exit(2)
    block = "\n".join(lines[begin + 1:end]).replace("{% raw %}", "").replace("{% endraw %}", "")
    # The site's own renderer and the extensions that shape this page's
    # text. mkdocs.yml also loads highlighting and TOC extensions, which
    # add markup but no text.
    html_out = markdown.markdown(block, extensions=["tables", "attr_list", "md_in_html", "admonition", "pymdownx.superfences"])
    page = PageText()
    page.feed(html_out)
    page.close()
    page.flush()
    return page.text, page.pre


CODE_SPAN = re.compile(r"(`+)(.+?)\1", re.S)


def normalize(text):
    # A renderer trims the blanks at a code span's edges and drops its
    # backticks; text is compared as words, so line-join, indent and fence
    # markers fall away. The same transform runs on both sides.
    text = CODE_SPAN.sub(lambda m: m.group(2).strip(), text)
    return re.sub(r"\s+", " ", text.replace("`", "")).strip()


def colon_led_runs(unit):
    """Indented runs whose lead-in line ends in a colon: deliberate blocks."""
    lines = [unit.head] + unit.lines
    runs, i = [], 0
    while i < len(lines):
        if not INDENTED.match(lines[i]):
            i += 1
            continue
        lead_in = next((x for x in reversed(lines[:i]) if not blank(x)), "")
        run, j = [], i
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
            run.append(lines[j].strip())
            j += 1
        if re.search(r":[ \t]*$", lead_in):
            runs.append(run)
        i = j
    return runs


def in_one_pre(run, pres):
    for pre in pres:
        have = [x.strip() for x in pre.split("\n") if x.strip()]
        for k in range(len(have) - len(run) + 1):
            if have[k:k + len(run)] == run:
                return True
    return False


def first_divergence(want, have):
    words = want.split(" ")
    lo, hi = 0, len(words)
    # Longest prefix still present; presence is monotone in prefix length.
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if " ".join(words[:mid]) in have:
            lo = mid
        else:
            hi = mid - 1
    return lo, len(words), " ".join(words[lo:lo + 12])


def main(argv):
    if len(argv) < 2:
        print(f"usage: {PROG} DOC --entry F... --lib F...", file=sys.stderr)
        return 2
    doc, files, mode = argv[1], [], None
    for arg in argv[2:]:
        if arg in ("--entry", "--lib"):
            mode = arg
        elif mode is None:
            print(f"{PROG}: file {arg} given before --entry or --lib", file=sys.stderr)
            return 2
        else:
            files.append((arg, mode == "--lib"))
    text, pres = render(doc)

    findings, n_units, n_runs = [], 0, 0
    for path, library in files:
        unreached = []
        units = extract(path, library, unreached)
        findings += [f"{key}:{no}: {msg}" for key, no, msg in unreached]
        for key, unit in units:
            want = normalize(unit.expected())
            if not want:
                continue
            n_units += 1
            if key not in text:
                findings.append(f"{key}: {unit.label()} (line {unit.line}) has no entry on the page")
                continue
            have = normalize(text[key])
            if want not in have:
                got, total, frag = first_divergence(want, have)
                findings.append(f"{key}: {unit.label()} (line {unit.line}) published {got} of {total} words; dropped or altered from: {frag!r}")
            if unit.tag == "description":
                for run in colon_led_runs(unit):
                    n_runs += 1
                    if not in_one_pre(run, pres.get(key, [])):
                        findings.append(f"{key}: indented block (line {unit.line} description) is not one preformatted block on the page, starting {run[0][:60]!r}")
    if n_units == 0:
        print(f"{PROG}: no annotation text found in {len(files)} file(s)", file=sys.stderr)
        return 2
    if findings:
        for f in findings:
            print(f"{PROG}: {f}", file=sys.stderr)
        print(f"{PROG}: {len(findings)} finding(s): script header text that docs/reference/scripts.md does not show as written. "
              "Fix the generator (scripts/_script_docs.awk, scripts/refresh-scripts-reference.sh) or rewrite the header, "
              "then regenerate.", file=sys.stderr)
        return 1
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
