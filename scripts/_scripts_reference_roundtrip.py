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
# check cannot run: python-markdown or PyYAML is not importable, the page
# or its markers are missing, mkdocs.yml's markdown extensions cannot be
# read, loaded or render the page, the config inherits another, a header
# is not UTF-8 or cannot be read, the files named hold no annotation at
# all, or the checker raises an uncaught exception. Findings use 3, not 1, because
# Python itself exits 1 on a syntax error or an uncaught exception, and the
# wrapper must not read either as findings.

import html.parser
import importlib
import os
import re
import sys

# Python puts this script's own directory first on the import path, so an
# extension or `!!python/name:` in mkdocs.yml could otherwise import a file
# sitting beside the checker. Imports resolve from installed packages only.
# Compared as real paths: Python resolves symlinks in the entry it adds.
_HERE = os.path.dirname(os.path.realpath(__file__))
sys.path[:] = [p for p in sys.path if os.path.realpath(p or os.curdir) != _HERE]

try:
    import markdown
    import yaml
except ImportError as err:
    print(f"scripts-reference-roundtrip: python-markdown or PyYAML is not importable ({err.name} is missing)", file=sys.stderr)
    sys.exit(2)

PROG = "scripts-reference-roundtrip"

# The tags the generator renders or declares. A line opening with any other
# `@word` is header text, and it has to publish like any other text.
RENDERED = ("description", "arg", "option", "example", "exitcode", "stdout")
DECLARED = ("generates-block", "generates")
KNOWN = RENDERED + DECLARED
# An annotation is `# @tag`, one blank after the hash, which is the house
# style. A comment that indents an `@tag` further is prose about the tag,
# and the page must show it as written.
TAG_LINE = re.compile(r"^# @[A-Za-z]")
# Several tags may share a line when two or more blanks separate them.
TAG_SPLIT = re.compile(r"[ \t]{2,}(?=@(?:%s)(?![A-Za-z-]))" % "|".join(KNOWN))
TAG = re.compile(r"^@([A-Za-z-]+)[ \t]*(.*)$", re.S)
SHELLCHECK = re.compile(r"^#[ \t]+shellcheck[ \t]")
FUNC = re.compile(r"^(?:function[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(\)")
STRAY_TAG = re.compile(r"^# @(?:%s)(?:[ \t]|$)" % "|".join(RENDERED))
BOUND_OPENER = re.compile(r"^# @description(?![A-Za-z-])")
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
            return prose([name]) + " — " + prose([rest] + self.lines)
        if self.tag in DECLARED:
            return prose(self.lines)
        if self.tag == "example":
            return "\n".join(self.example_lines())
        if self.tag == "description":
            # A fenced run is shown as written; everything around it is
            # prose, where a list item's marker renders as a bullet.
            lines = [self.head] + self.lines
            out, i = [], 0
            for start, end, fenced in run_spans(lines):
                if not fenced:
                    continue
                out.append(prose(optional_markers(lines[i:start])))
                out.append(" ".join(lines[start:end]))
                i = end
            out.append(prose(optional_markers(lines[i:])))
            return " ".join(out)
        return prose([self.head] + self.lines)

    def example_lines(self):
        """The lines an @example's fence must hold: its body as written,
        with the blank lines at either edge dropped as the fence drops them.
        Text on the tag line itself is required too; the generator does not
        print it, so a header that puts text there is reported."""
        lines = ([self.head] if self.head.strip() else []) + self.lines
        while lines and blank(lines[-1]):
            lines.pop()
        while lines and blank(lines[0]):
            lines.pop(0)
        # python-markdown expands a tab to the next four-column stop.
        return [x.rstrip().expandtabs(4) for x in lines]

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
            text = raw[2:]
            for seg in TAG_SPLIT.split(text):
                m = TAG.match(seg)
                if m and m.group(1) == "example" and any(u.tag == "example" for u in units):
                    # A second @example continues the first: the generator
                    # renders every example line in one fence.
                    cur = next(u for u in units if u.tag == "example")
                    if m.group(2).strip():
                        cur.lines.append(m.group(2))
                elif m and m.group(1) in KNOWN:
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


class SiteLoader(yaml.SafeLoader):
    """mkdocs.yml's own loader rules: `!!python/name:` imports the object it
    names, as mkdocs does; any other custom tag reads as nothing, since only
    markdown_extensions is used."""


def _python_name(loader, suffix, node):
    module, _, attr = suffix.rpartition(".")
    return getattr(importlib.import_module(module), attr)


def _env(loader, node):
    """mkdocs's `!ENV`: a variable name, or a list of names whose last item
    is the default when the list holds more than one. The first set variable
    is read as a plain YAML scalar, so `true` is a boolean."""
    default = None
    if isinstance(node, yaml.ScalarNode):
        names = [loader.construct_scalar(node)]
    else:
        children = list(node.value)
        if len(children) > 1:
            default = loader.construct_object(children.pop())
        names = [loader.construct_scalar(c) for c in children]
    for name in names:
        if name in os.environ:
            value = os.environ[name]
            tag = loader.resolve(yaml.ScalarNode, value, (True, False))
            return loader.construct_object(yaml.ScalarNode(tag, value))
    return default


SiteLoader.add_multi_constructor("tag:yaml.org,2002:python/name:", _python_name)
SiteLoader.add_constructor("!ENV", _env)
SiteLoader.add_multi_constructor("!", lambda loader, suffix, node: None)


def site_extensions(mkdocs_yml):
    """The extensions and configs mkdocs.yml loads, read as mkdocs reads
    them. Several rewrite text, not just markup — inlinehilite, details and
    tabbed rewrite their own syntax, and snippets replaces a line with a
    file — so an extension list that cannot be read is a could-not-run."""
    try:
        with open(mkdocs_yml, encoding="utf-8") as fh:
            config = yaml.load(fh, Loader=SiteLoader)
    except (OSError, yaml.YAMLError, ImportError, AttributeError) as err:
        print(f"{PROG}: cannot read the markdown extensions in {mkdocs_yml}: {err}", file=sys.stderr)
        sys.exit(2)
    if isinstance(config, dict) and "INHERIT" in config:
        print(f"{PROG}: {mkdocs_yml} inherits another config (INHERIT), which this checker does not follow", file=sys.stderr)
        sys.exit(2)
    entries = config.get("markdown_extensions") if isinstance(config, dict) else None
    if not isinstance(entries, list) or not entries:
        print(f"{PROG}: {mkdocs_yml} lists no markdown_extensions", file=sys.stderr)
        sys.exit(2)
    names, configs = [], {}
    for entry in entries:
        if isinstance(entry, str):
            names.append(entry)
        elif isinstance(entry, dict) and len(entry) == 1:
            name, conf = next(iter(entry.items()))
            names.append(name)
            configs[name] = conf or {}
        else:
            print(f"{PROG}: {mkdocs_yml} has a markdown_extensions entry this checker cannot read: {entry!r}", file=sys.stderr)
            sys.exit(2)
    # mkdocs always loads these, ahead of the configured list, and drops a
    # later repeat of any name, as its own reduce_list does.
    names = list(dict.fromkeys(["toc", "tables", "fenced_code"] + names))
    return names, configs


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
    try:
        html_out = markdown.markdown(block, extensions=names, extension_configs=configs)
    except Exception as err:  # noqa: BLE001
        print(f"{PROG}: the site's Markdown extensions could not render the page: {type(err).__name__}: {err}", file=sys.stderr)
        sys.exit(2)
    page = PageText()
    page.feed(html_out)
    page.close()
    return page.entries


CODE_SPAN = re.compile(r"(`+)(.+?)\1", re.S)


# A token that stands where a list item's marker would. The page is
# formatted by mdformat, which reads lists by CommonMark's rules, before
# python-markdown renders it by its own, so whether a given line becomes a
# list item is not predicted here: its marker may show as text or as a
# bullet, and both match.
OPTIONAL = "\x01"
MARKER = re.compile(r"^([ \t]*)((?:[-*+]|[0-9]+[.)]))(?=[ \t]+\S)")


def optional_markers(lines):
    return [MARKER.sub(lambda m: m.group(1) + OPTIONAL + m.group(2), line) for line in lines]


def shown(text):
    """Text for a diagnostic, without the optional-marker flags."""
    return text.replace(OPTIONAL, "")


def prose(lines):
    """Header prose as the page shows it: a code span loses its backticks
    and the blanks at its edges. A backtick that opens no span stays. A code
    span never crosses a blank line, so each paragraph is read on its own."""
    paragraphs, cur = [], []
    for line in lines:
        if blank(line):
            paragraphs.append(cur)
            cur = []
        else:
            cur.append(line)
    paragraphs.append(cur)
    return " ".join(CODE_SPAN.sub(lambda m: m.group(2).strip(), " ".join(p)) for p in paragraphs if p)


def normalize(text):
    # Text is compared as words, so line-join, indent and fence markers fall
    # away. The same transform runs on both sides.
    return re.sub(r"\s+", " ", text).strip()


def contains(have, want, start=0):
    """Offset just past `want` found as whole words in `have`, or -1. A
    word flagged as an optional list marker may be absent."""
    pattern = " " + "".join(
        f"(?:{re.escape(w[1:])} )?" if w.startswith(OPTIONAL) else re.escape(w) + " "
        for w in want.split(" ") if w)
    m = re.compile(pattern).search(" " + have + " ", start)
    return -1 if m is None else m.end() - 1


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
                run.append("")
                continue
            lead = re.match(r"^[ \t]*", line).group(0)
            indent = lead.replace("\t", "  ")
            if len(indent) % 2:
                indent = " " + indent
            # The generator writes the rest of the line as is, and
            # python-markdown expands its tabs to four-column stops.
            run.append((indent + line[len(lead):].rstrip()).expandtabs(4))
        runs.append(run)
    return runs


def pre_lines(text):
    """A fence's lines, interior blank lines kept, edge blank lines dropped."""
    lines = [x.rstrip() for x in text.split("\n")]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return lines


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
    return lo, len(words), shown(" ".join(words[lo:lo + 12]))


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
    # Rendered first, so a missing marker or an unreadable config is still
    # a could-not-run when the scan set is empty.
    entries = render(doc, mkdocs_yml)
    if not files and os.environ.get("LINT_ALLOW_EMPTY_SCAN"):
        # The scan set is empty and the caller said that is deliberate.
        print("check-scripts-reference-roundtrip: ok — 0 file(s), 0 annotation unit(s), 0 indented block(s) published intact")
        return 0

    findings, n_units, n_runs = [], 0, 0
    for path, library in files:
        unreached = []
        units = extract(path, library, unreached)
        findings += [f"{key}:{no}: {msg}" for key, no, msg in unreached]
        has_example = {key for key, unit in units if unit.tag == "example"}
        desc_from = {}  # key -> offset the next description unit must start at
        # Each list item and each description fence is matched at most once,
        # so two units cannot share one item, and fences match in order.
        items_left, pre_from = {}, {}
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
                items = items_left.setdefault((key, unit.tag), [normalize(b[2]) for b in blocks if b[0] == unit.tag and b[1] == "li"])
                if want in items:
                    items.remove(want)
                else:
                    got, total, frag = first_divergence(want, " | ".join(items))
                    if got == total:
                        findings.append(f"{where} is not one item of its list: its text appears only inside other text")
                    else:
                        findings.append(f"{where} is not one item of its list: published {got} of {total} words; dropped or altered from: {frag!r}")
                continue
            if unit.tag == "example":
                # A fence shows its lines exactly, so they are compared as
                # lines, not as words.
                if (pre_lines(example[2]) if example else []) != unit.example_lines():
                    got, total, frag = first_divergence(want, normalize(example[2]) if example else "")
                    if got == total:
                        findings.append(f"{where} is not the entry's example block: its lines or indentation differ")
                    else:
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
                    at = pre_from.get(key, 0)
                    hit = next((k for k in range(at, len(pres)) if pres[k] == run), -1)
                    if hit >= 0:
                        pre_from[key] = hit + 1
                    else:
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
