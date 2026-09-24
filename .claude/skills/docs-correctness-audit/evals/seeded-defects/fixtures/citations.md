# report

- .github/CONTRIBUTING.md:38 — a different file whose path ends in the seed's
- docs/data.md:10 — a different file whose name ends in the seed's
- docs/a+b(c).md:11 — the seed's own path, regex metacharacters and all
- docs/xxy.md:5 — matches the seed's path only if + is read as a regex
- docs/r.md:20-40 — a range that spans the seed's line
- docs/q.md:20-40 — a range that ends far from the seed's line
- (`docs/p.md:7`) — a citation wrapped in punctuation
- `docs/o.md:08` — a zero-padded line number
- ./docs/s.md:5 — a repo-relative path written with a leading ./
- docs/w[1]{2}\*?^$|.md:5 — the seed's own path, every ERE metacharacter literal
- docs/f.md:30 — a seed whose manifest line is written 30.0
