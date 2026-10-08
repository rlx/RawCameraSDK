#!/usr/bin/env python3
"""Times the decoders on a connected iPhone or iPad.

    Scripts/device-bench.py <device-udid> [--limit 15] [--runs 1]
    Scripts/device-bench.py <device-udid> --limit 0 --runs 3     the full set: 102 launches

Before running, build and install the demo app on the device (README, "On a device").
`xcrun devicectl list devices` shows the UDID.

Two sets of files are measured:

  - the ten samples bundled in the app, which only the fallback opens;
  - the files from the Mac benchmark (Tests/bench-results.json), which both decoders open.
    They are copied from Tests/Corpus into the app's Documents folder first.

Each measurement is one launch of the app in its headless benchmark mode (see
Examples/RawInputDemo/App/Benchmark.swift), so every run has its own process and its own
peak-memory figure, and a run the OS terminates for memory shows up as exactly that.

Every launch brings the app to the front of the phone for a moment, so the default is a
short session: at most 15 launches, one run each. Measurements are taken in order of how
much they tell you, and the list is cut where the limit falls:

  1. the shared files through both decoders   (the Apple-against-fallback comparison)
  2. the samples through the fallback         (the formats Apple cannot open)
  3. the samples through Apple's decoder      (confirms it still rejects them)

`--limit 0` removes the cap. The figures in the README came from `--limit 0 --runs 3`.

Writes Tests/device-results.json: one row per file and route, the median of the runs.
"""
import json
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "dev.rawinputkit.demo"
MARKER = "RAWBENCH "


def devicectl(device, subcommand, *arguments, timeout=300):
    """Runs `devicectl device <subcommand> --device <udid> <arguments>`."""
    return subprocess.run(
        ["xcrun", "devicectl", "device", *subcommand.split(), "--device", device, *arguments],
        capture_output=True, text=True, timeout=timeout)


def copy_to_documents(device, source, name):
    result = devicectl(
        device, "copy to", "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
        "--source", str(source), "--destination", f"Documents/{name}")
    if result.returncode != 0:
        sys.exit(f"could not copy {source.name} to the device:\n{result.stderr or result.stdout}")


def launch(device, name, route):
    """One measurement. Returns the app's result, or a row saying why there is none."""
    try:
        result = devicectl(
            device, "process launch", "--console", "--terminate-existing", BUNDLE_ID, "--",
            "-benchmarkFile", name, "-benchmarkRoute", route)
    except subprocess.TimeoutExpired:
        return {"file": name, "route": route, "error": "timed out"}
    for line in result.stdout.splitlines():
        if line.startswith(MARKER):
            return json.loads(line[len(MARKER):])
    # No result line: the process died first. On iOS that is almost always the memory limit.
    tail = (result.stdout + result.stderr).strip().splitlines()[-1:] or ["no output"]
    return {"file": name, "route": route, "error": f"terminated before finishing ({tail[0]})"}


def measure(device, name, route, runs):
    samples = [launch(device, name, route) for _ in range(runs)]
    finished = sorted((s for s in samples if s.get("totalSeconds")), key=lambda s: s["totalSeconds"])
    # A file Apple cannot open fails identically every time; any one run describes it.
    row = dict(finished[len(finished) // 2] if finished else samples[-1])
    row["runs"] = runs
    row["completedRuns"] = len(finished)
    if finished:
        row["peakMegabytes"] = statistics.median(s["peakMegabytes"] for s in finished)
    return row


def take_option(arguments, flag, default):
    """Removes `flag <number>` from the arguments and returns the number."""
    if flag not in arguments:
        return default
    index = arguments.index(flag)
    if index + 1 >= len(arguments) or not arguments[index + 1].isdigit():
        sys.exit(f"{flag} needs a number\n{__doc__}")
    value = int(arguments[index + 1])
    del arguments[index:index + 2]
    return value


def main():
    arguments = sys.argv[1:]
    limit = take_option(arguments, "--limit", 15)
    runs = max(1, take_option(arguments, "--runs", 1))
    if len(arguments) != 1:
        sys.exit(__doc__)
    device = arguments[0]

    samples = json.loads((ROOT / "Examples/RawInputDemo/Samples/manifest.json").read_text())
    shared = json.loads((ROOT / "Tests/bench-results.json").read_text())

    shared_files = []
    for index, entry in enumerate(shared):
        source = ROOT / "Tests" / "Corpus" / entry["file"]
        if not source.exists():
            print(f"skipping {entry['file']}: not in Tests/Corpus")
            continue
        # A short, shell-safe name; archive file names are full of spaces and brackets.
        shared_files.append((entry["camera"], source, f"shared-{index}{source.suffix.lower()}"))

    # In order of value; see the module comment.
    plan = [(name, "shared", route) for _, _, name in shared_files for route in ("apple", "fallback")]
    plan += [(sample["file"], "samples", "fallback") for sample in samples]
    plan += [(sample["file"], "samples", "apple") for sample in samples]
    if limit:
        affordable = max(1, limit // runs)
        if affordable < len(plan):
            print(f"limited to {affordable * runs} launches: {affordable} of {len(plan)} measurements")
        plan = plan[:affordable]

    needed = {name for name, group, _ in plan if group == "shared"}
    for camera, source, name in shared_files:
        if name in needed:
            print(f"copying {camera} to the device")
            copy_to_documents(device, source, name)

    rows = []
    for name, group, route in plan:
        row = measure(device, name, route, runs)
        row["group"] = group
        rows.append(row)
        outcome = row.get("error") or f"{row['totalSeconds']:.2f} s, {row['peakMegabytes']:.0f} MB peak"
        print(f"{row.get('camera') or name} [{route}]: {outcome}", flush=True)

    (ROOT / "Tests" / "device-results.json").write_text(json.dumps(rows, indent=1, sort_keys=True) + "\n")
    print(f"{len(rows)} rows -> Tests/device-results.json")


if __name__ == "__main__":
    main()
