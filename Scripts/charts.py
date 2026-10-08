#!/usr/bin/env python3
"""Draws the README charts from measured results, as light and dark SVG pairs in Docs/.

    Tests/probe-results.json   written by `rawprobe <folder> --json`   -> coverage, agreement
    Tests/bench-results.json   written by `rawprobe bench ... --json`  -> speed (Mac)
    Tests/device-results.json  written by `Scripts/device-bench.py`    -> speed-device
    Tests/match-results.json   written by `rawprobe match ... --json`  -> route-match

Plain SVG, no dependencies. GitHub shows the right variant through a <picture> element.
Colours are the first two slots of a colour-blind-validated categorical palette; the same
blue and orange mark the two decoders in the demo app.
"""
import json
import statistics
from collections import defaultdict
from pathlib import Path

from brands import brand

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "Docs"

THEMES = {
    "light": {"text": "#0b0b0b", "muted": "#52514e", "grid": "#e4e3df", "surface": "#ffffff",
              "apple": "#2a78d6", "fallback": "#eb6834", "neither": "#b5b4ac", "shared": "#1baf7a"},
    "dark": {"text": "#ffffff", "muted": "#c3c2b7", "grid": "#33332f", "surface": "#0d1117",
             "apple": "#3987e5", "fallback": "#d95926", "neither": "#6b6a64", "shared": "#199e70"},
}
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
BAR = 16  # bar thickness, px
GAP = 2   # surface gap between stacked segments, px


class Svg:
    def __init__(self, width, height, theme, label):
        self.theme = theme
        self.parts = [
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" '
            f'height="{height}" role="img" aria-label="{label}" font-family="{FONT}" font-size="13">'
        ]

    def text(self, x, y, content, anchor="start", color="text", weight=400, size=13):
        self.parts.append(
            f'<text x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}" fill="{self.theme[color]}" '
            f'font-weight="{weight}" font-size="{size}">{content}</text>')

    def line(self, x1, y1, x2, y2, color="grid", width=1):
        self.parts.append(
            f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
            f'stroke="{self.theme[color]}" stroke-width="{width}"/>')

    def bar(self, x, y, width, height, color, round_end=False, opacity=1.0):
        """A horizontal bar segment. Only the free end of a bar is rounded."""
        if width <= 0:
            return
        r = min(4, width) if round_end else 0
        path = (f"M{x:.1f},{y:.1f} h{width - r:.1f} a{r},{r} 0 0 1 {r},{r} v{height - 2 * r:.1f} "
                f"a{r},{r} 0 0 1 -{r},{r} h-{width - r:.1f} z")
        self.parts.append(f'<path d="{path}" fill="{self.theme[color]}" fill-opacity="{opacity}"/>')

    def dot(self, x, y, color):
        self.parts.append(
            f'<circle cx="{x:.1f}" cy="{y:.1f}" r="5" fill="{self.theme[color]}" '
            f'stroke="{self.theme["surface"]}" stroke-width="2"/>')

    def legend(self, x, y, entries):
        for color, label in entries:
            self.parts.append(f'<rect x="{x}" y="{y - 10}" width="12" height="12" rx="2" fill="{self.theme[color]}"/>')
            self.text(x + 18, y, label, color="muted")
            x += 34 + 6.4 * len(label)  # rough advance; SVG cannot measure text

    def save(self, name, mode):
        (DOCS / f"{name}-{mode}.svg").write_text("\n".join(self.parts + ["</svg>"]) + "\n")


def load(name):
    path = ROOT / "Tests" / name
    return json.loads(path.read_text()) if path.exists() else None


def coverage(rows, pool):
    """Stacked bars per brand: what Apple opens, what only the fallback adds, what nothing opens."""
    counts = defaultdict(lambda: {"apple": 0, "fallback": 0, "neither": 0})
    for row in rows:
        outcome = "apple" if row["apple"] else "fallback" if row["fallback"] else "neither"
        counts[brand(pool[row["file"]]["make"])][outcome] += 1
    ranked = sorted(counts.items(), key=lambda item: -sum(item[1].values()))
    shown, rest = ranked[:12], ranked[12:]
    other = {key: sum(c[key] for _, c in rest) for key in ("apple", "fallback", "neither")}
    shown.append((f"{len(rest)} other brands", other))

    left, right, top, row_height = 132, 96, 44, 30
    width, height = 760, top + row_height * len(shown) + 34
    largest = max(sum(c.values()) for _, c in shown)
    limit = -(-largest // 50) * 50  # round the axis up to a multiple of 50
    scale = (width - left - right) / limit

    for mode, theme in THEMES.items():
        svg = Svg(width, height, theme, "Files opened by Apple's decoder and by the fallback, per camera brand")
        svg.legend(left, 18, [("apple", "Apple's decoder opens it"),
                              ("fallback", "Only the fallback opens it"), ("neither", "Neither")])
        bottom = top + row_height * len(shown)
        for tick in range(0, limit + 1, 50):
            x = left + tick * scale
            svg.line(x, top - 6, x, bottom)
            suffix = " files" if tick == limit else ""
            svg.text(x, bottom + 18, f"{tick}{suffix}", anchor="middle", color="muted", size=12)
        for index, (maker, c) in enumerate(shown):
            y = top + index * row_height + (row_height - BAR) / 2
            svg.text(left - 10, y + BAR - 3.5, maker, anchor="end")
            x = left
            segments = [(key, c[key]) for key in ("apple", "fallback", "neither") if c[key]]
            for position, (key, count) in enumerate(segments):
                last = position == len(segments) - 1
                # Never let a one-file segment vanish: 3 px is the smallest visible bar.
                length = max(count * scale - (0 if last else GAP), 3)
                svg.bar(x, y, length, BAR, key, round_end=last)
                x += length + GAP
            total = sum(c.values())
            svg.text(x + 6, y + BAR - 3.5, f"{c['apple']} of {total}", color="muted", size=12)
        svg.save("coverage-by-brand", mode)


def agreement(rows):
    """How far each decoder's colour sits from the camera's own preview, on files both open."""
    shared = [r for r in rows if r["apple"] and r["fallback"]
              and r.get("applePreviewDistance") is not None and r.get("fallbackPreviewDistance") is not None]
    series = [("apple", "Apple's decoder", [r["applePreviewDistance"] for r in shared]),
              ("fallback", "Fallback (LibRaw + RawInputKit)", [r["fallbackPreviewDistance"] for r in shared])]

    left, right, top, row_height, limit = 232, 40, 26, 44, 0.20
    width, height = 760, top + row_height * len(series) + 44
    scale = (width - left - right) / limit

    for mode, theme in THEMES.items():
        svg = Svg(width, height, theme, "Colour distance from the camera's embedded preview, per decoder")
        bottom = top + row_height * len(series)
        for tick in (0, 0.05, 0.10, 0.15, 0.20):
            x = left + tick * scale
            svg.line(x, top, x, bottom)
            svg.text(x, bottom + 18, f"{tick:.2f}", anchor="middle", color="muted", size=12)
        svg.text(left + limit * scale / 2, bottom + 36,
                 "chromaticity distance from the embedded preview (0 = identical colour)",
                 anchor="middle", color="muted", size=12)
        range_rows(svg, series, left, top, row_height, scale, "median {:.3f}")
        svg.save("preview-agreement", mode)
    return len(shared)


def range_rows(svg, series, left, top, row_height, scale, label_format):
    """Rows of range bars: thin for the middle 90% of values, thick for the middle half, a
    dot at the median."""
    for index, (key, label, values) in enumerate(series):
        y = top + index * row_height + row_height / 2
        cuts = statistics.quantiles(values, n=20)  # 5% steps
        p5, p25, median, p75, p95 = cuts[0], cuts[4], cuts[9], cuts[14], cuts[18]
        svg.text(left - 12, y + 4.5, label, anchor="end")
        svg.bar(left + p5 * scale, y - 2, (p95 - p5) * scale, 4, key, opacity=0.35)
        svg.bar(left + p25 * scale, y - BAR / 2, (p75 - p25) * scale, BAR, key, opacity=0.6)
        svg.dot(left + median * scale, y, key)
        svg.text(left + p95 * scale + 8, y + 4.5, label_format.format(median), color="muted", size=12)


def route_match(rows):
    """How different the two decoders' pictures are, before and after the shared rendering."""
    series = [("neither", "Each decoder's own output", [r["ownOutput"] for r in rows]),
              ("shared", "Shared rendering, neutral look", [r["sharedNeutral"] for r in rows]),
              ("shared", "Shared rendering, film look", [r["sharedFilm"] for r in rows])]
    left, right, top, row_height, limit = 232, 40, 26, 44, 35
    width, height = 760, top + row_height * len(series) + 44
    scale = (width - left - right) / limit
    for mode, theme in THEMES.items():
        svg = Svg(width, height, theme, "Colour difference between the two decoders' pictures, before and after shared rendering")
        bottom = top + row_height * len(series)
        for tick in range(0, limit + 1, 5):
            x = left + tick * scale
            svg.line(x, top, x, bottom)
            svg.text(x, bottom + 18, tick, anchor="middle", color="muted", size=12)
        svg.text(left + limit * scale / 2, bottom + 36,
                 "colour difference between the two decoders, ΔE (lower = more alike)",
                 anchor="middle", color="muted", size=12)
        range_rows(svg, series, left, top, row_height, scale, "median {:.1f}")
        svg.save("route-match", mode)


def device_rows(results):
    """Reshapes device-bench rows (one per file and route) into the Mac benchmark's shape."""
    by_file = defaultdict(dict)
    for row in results:
        if row.get("group") == "shared" and row.get("totalSeconds"):
            by_file[row["file"]][row["route"]] = row
    rows = []
    for routes in by_file.values():
        # Apple's decoder asked for scene-linear output is the like-for-like comparison with
        # the fallback, which is always scene-linear.
        apple = routes.get("apple-linear") or routes.get("apple")
        if apple and "fallback" in routes:
            fallback = routes["fallback"]
            rows.append({
                "camera": fallback["camera"], "megapixels": fallback["megapixels"],
                "path": ("Metal" if "Metal" in fallback["decoder"] else "CPU")
                        + (", half size" if fallback["isHalfSize"] else ""),
                "appleSeconds": apple["totalSeconds"], "fallbackSeconds": fallback["totalSeconds"],
            })
    return rows


def speed(bench, name="speed"):
    """Seconds to a full-resolution rendered image, per file and decoder."""
    left, right, top, row_height = 252, 70, 44, 46
    width, height = 760, top + row_height * len(bench) + 40
    largest = max(max(b["appleSeconds"], b["fallbackSeconds"]) for b in bench)
    limit = max(1, -(-largest // 1))
    scale = (width - left - right) / limit

    for mode, theme in THEMES.items():
        svg = Svg(width, height, theme, "Seconds from file to full-resolution image, per decoder")
        svg.legend(left, 18, [("apple", "Apple's decoder"), ("fallback", "Fallback")])
        bottom = top + row_height * len(bench)
        step = 1 if limit <= 6 else 2
        for tick in range(0, int(limit) + 1, step):
            x = left + tick * scale
            svg.line(x, top - 6, x, bottom)
            svg.text(x, bottom + 18, f"{tick} s", anchor="middle", color="muted", size=12)
        for index, b in enumerate(bench):
            y = top + index * row_height + (row_height - 2 * BAR - GAP) / 2
            svg.text(left - 10, y + BAR - 2, b["camera"], anchor="end")
            svg.text(left - 10, y + BAR + 14, f"{b['megapixels']:.0f} MP · {b['path']}", anchor="end",
                     color="muted", size=12)
            for offset, key in ((0, "apple"), (BAR + GAP, "fallback")):
                seconds = b[f"{key}Seconds"]
                svg.bar(left, y + offset, max(seconds * scale, 3), BAR, key, round_end=True)
                svg.text(left + max(seconds * scale, 3) + 6, y + offset + BAR - 3.5, f"{seconds:.2f} s",
                         color="muted", size=12)
        svg.save(name, mode)


if __name__ == "__main__":
    DOCS.mkdir(exist_ok=True)
    probe = load("probe-results.json")
    if probe:
        pool = {entry["file"]: entry for entry in load("corpus-pool.json")}
        coverage(probe, pool)
        print(f"coverage and agreement charts ({agreement(probe)} files both decoders open)")
    bench = load("bench-results.json")
    if bench:
        speed(bench)
        print(f"speed chart ({len(bench)} files)")
    match = load("match-results.json")
    if match:
        route_match(match)
        print(f"route match chart ({len(match)} files)")
    device = load("device-results.json")
    if device:
        speed(device_rows(device), name="speed-device")
        print("device speed chart")
