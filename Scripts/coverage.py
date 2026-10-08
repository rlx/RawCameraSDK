#!/usr/bin/env python3
"""Turns Tests/probe-results.json (written by `rawprobe --json`) into Docs/coverage.md."""
import json
import platform
import statistics
from collections import defaultdict
from pathlib import Path

from brands import brand

ROOT = Path(__file__).resolve().parent.parent
# Above this chromaticity distance from the embedded preview, a decode is treated as
# suspect: it opened, but black level, white balance or geometry is probably wrong.
SUSPECT = 0.15

pool = {e["file"]: e for e in json.loads((ROOT / "Tests" / "corpus-pool.json").read_text())}
# Anything in the probed folder that is not part of the pool has no catalogue entry to
# describe it, so it is left out instead of guessed at.
rows = [r for r in json.loads((ROOT / "Tests" / "probe-results.json").read_text()) if r["file"] in pool]


def extension(row):
    return row["file"].rsplit(".", 1)[-1].upper()


def label(row):
    entry = pool[row["file"]]
    mode = f" ({entry['mode']})" if entry["mode"] else ""
    return f"{row['camera']}{mode}, {extension(row)}"


both = [r for r in rows if r["apple"] and r["fallback"]]
fallback_only = [r for r in rows if not r["apple"] and r["fallback"]]
apple_only = [r for r in rows if r["apple"] and not r["fallback"]]
neither = [r for r in rows if not r["apple"] and not r["fallback"]]
checked = [r for r in rows if r["fallback"] and r.get("fallbackPreviewDistance") is not None]
suspect = [r for r in checked if r["fallbackPreviewDistance"] > SUSPECT]
metal = [r["fallbackSeconds"] for r in rows if "Metal" in r["fallbackDecoder"]]
cpu = [r["fallbackSeconds"] for r in rows if "CPU" in r["fallbackDecoder"]]

out = [
    "# Decoder coverage",
    "",
    # Run this on the machine that ran the probe: the OS version decides Apple's column.
    f"Measured with `rawprobe` on macOS {platform.mac_ver()[0]} ({platform.machine()}), "
    f"over {len(rows)} CC0 files from raw.pixls.us covering "
    f"{len({(pool[r['file']]['make'], pool[r['file']]['model']) for r in rows})} camera models. "
    "Regenerate with `Scripts/corpus.py fetch`, `rawprobe Tests/Corpus --json Tests/probe-results.json`, "
    "`Scripts/coverage.py`.",
    "",
    "| Result | Files |",
    "|---|---|",
    f"| Both decoders open it | {len(both)} |",
    f"| Only the fallback opens it | {len(fallback_only)} |",
    f"| Only Apple opens it | {len(apple_only)} |",
    f"| Neither opens it | {len(neither)} |",
    "",
    f"Fallback decode time, median: {statistics.median(metal):.2f} s on the Metal path "
    f"({len(metal)} files), {statistics.median(cpu):.2f} s on the CPU path ({len(cpu)} files).",
    "",
    "\"Opens\" means pixels came out. It does not mean the colour is right, so each fallback "
    "result is also compared with the camera's embedded preview: "
    f"{len(suspect)} of {len(checked)} files with a preview differ enough to be suspect "
    "(listed at the end).",
    "",
    "## Only the fallback opens it",
    "",
    "| Format | Files | Cameras |",
    "|---|---|---|",
]
groups = defaultdict(list)
for row in fallback_only:
    groups[(brand(pool[row["file"]]["make"]), extension(row))].append(row)
for (make, ext), members in sorted(groups.items(), key=lambda item: (-len(item[1]), item[0])):
    cameras = sorted({r["camera"] for r in members})
    shown = ", ".join(cameras[:6]) + (f" and {len(cameras) - 6} more" if len(cameras) > 6 else "")
    out.append(f"| {make} {ext} | {len(members)} | {shown} |")

out += ["", "## Only Apple opens it", ""]
out += [f"- {label(r)}: `{r['routine']}`" for r in sorted(apple_only, key=label)]
out += ["", "## Neither opens it", ""]
out += [f"- {label(r)}: `{r['routine']}`" for r in sorted(neither, key=label)]
out += ["", "## Fallback opens it but the colour is suspect", ""]
out += [
    f"- {label(r)}: distance {r['fallbackPreviewDistance']:.2f}"
    + ("" if r["apple"] else " (Apple cannot open it either)")
    for r in sorted(suspect, key=lambda r: -r["fallbackPreviewDistance"])
]
(ROOT / "Docs" / "coverage.md").write_text("\n".join(out) + "\n")
print(f"{len(rows)} files: both {len(both)}, fallback only {len(fallback_only)}, "
      f"Apple only {len(apple_only)}, neither {len(neither)}, suspect {len(suspect)}/{len(checked)}")
