#!/usr/bin/env python3
"""Candidate pool of CC0 RAW samples from raw.pixls.us.

    corpus.py pool                   rebuild Tests/corpus-pool.json from the live catalogue
    corpus.py fetch                  download and SHA-256 verify the pool into Tests/Corpus (19 GB)
    corpus.py fetch --only A B ...   only files whose name contains one of the given strings

The pool is wider than what ends up in the demo app: it is what
`rawprobe` runs over to find out which files Apple's decoder rejects.
"""
import hashlib
import json
import re
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POOL = ROOT / "Tests" / "corpus-pool.json"
CORPUS = ROOT / "Tests" / "Corpus"
CATALOGUE = "https://raw.pixls.us/json/getrepository.php?set=all"
MAX_MB = 72

# (make, model regex, mode regex, extension regex, how many of the smallest to keep per model,
#  optional False to allow several files with the same mode label)
RULES = [
    # Newest bodies: the lag window between a camera shipping and OS support.
    ("Sony", r"ILCE-7M5", r"", r"", 6),
    ("Sony", r"ILCE-1M2|ILCE-9M3|ILME-FX2|DSC-RX1RM3|ZV-E10M2|ILCE-6400A", r"", r"", 2),
    ("Canon", r"EOS R5 Mark II|EOS R6 Mark III", r"", r"", 4),
    ("Canon", r"EOS R50 V|EOS R100|PowerShot V1|EOS R10$", r"", r"", 1),
    ("Nikon", r"Z6_3|Z5_2|Z50_2", r"3:2", r"", 3),
    ("Fujifilm", r"X-E5|X-T30 III|X-M5|X-T50|X100VI|GFX100RF", r"", r"", 3),
    ("Panasonic", r"DC-S1RM2|DC-S1M2$|DC-S9|DC-GH7|DC-S5M2|DC-G97", r"", r"", 2),
    # OM files all carry the same mode label; High Res Shot only shows up as a larger file.
    ("OM System", r"OM-1 Mark II|OM-3", r"", r"", 5, False),
    # Compression modes and reduced-size RAW.
    ("Sony", r"ILCE-7CR|ILCE-7RM5", r"compress", r"", 4),
    ("Fujifilm", r"X-T5|X-H2S|X-S20|GFX50S II", r"compress", r"", 2),
    ("Canon", r"EOS 5D Mark IV|EOS 6D Mark II|EOS 80D|EOS 5D Mark III|EOS 7D Mark II", r"sRAW", r"", 2),
    ("Canon", r"EOS R5$", r"dual", r"", 1),
    ("Nikon", r"Z 8|Z 9|Z f$|Z fc|D6$", r"", r"", 3),
    # Multi-shot and unusual sensors.
    ("Olympus", r"E-M1MarkIII|E-M5 Mark II|E-M1MarkII", r"", r"ORI", 1),
    ("Sony", r".*", r"", r"ARQ", 1),
    ("Pentax", r"K-1|K-3|KP|K-70", r"", r"", 1),
    ("Sigma", r".*", r"", r"X3F", 1),
    ("Sigma", r"fp", r"14bit|12bit", r"DNG", 2),
    # Cameras that only ever shoot DNG, phones and drones.
    ("Ricoh", r"GR III", r"", r"", 1),
    ("DJI", r"FC4382|FC9287|FC7303", r"", r"", 1),
    ("Google", r"Pixel 8 Pro|Pixel 7 Pro", r"", r"", 1),
    ("Samsung", r"SM-S901E|NX1$|NX500", r"", r"", 2),
    ("Apple", r"iPhone 12 Pro", r"", r"", 1),
    ("Leica", r"M10-R|Q \(Typ 116\)|D-Lux 7|SL2", r"", r"", 1),
    ("Hasselblad", r"L2D-20c|CFV-50c|H5D-40", r"", r"", 1),
    ("Phase One", r"P40\+|IQ180", r"", r"", 1),
    ("GoPro", r"HERO11 Black", r"", r"", 1),
]


def catalogue():
    with urllib.request.urlopen(CATALOGUE, timeout=60) as response:
        rows = json.load(response)["data"]
    link = re.compile(
        r"href='([^']+)'>([^<]+)</a>.*?sha256 Checksum'>([0-9a-f]{64})</span>&nbsp;\(([\d.]+)MB\)"
    )
    for row in rows:
        match = link.search(row[7])
        if not match or "zero" not in row[5]:  # CC0 only
            continue
        yield {
            "make": row[0],
            "model": row[1],
            "mode": row[2],
            "added": row[6],
            "url": match.group(1),
            "name": match.group(2),
            "sha256": match.group(3),
            "mb": float(match.group(4)),
        }


def build_pool():
    entries = [e for e in catalogue() if e["mb"] <= MAX_MB]
    chosen = {}
    for make, model, mode, ext, keep, *rest in RULES:
        distinct = rest[0] if rest else True
        groups = {}
        for e in entries:
            if e["make"] != make or not re.search(model, e["model"]):
                continue
            if mode and not re.search(mode, e["mode"], re.I):
                continue
            if ext and not re.search(rf"\.({ext})$", e["name"], re.I):
                continue
            groups.setdefault(e["model"], []).append(e)
        for group in groups.values():
            # Smallest first, but never two files of the same mode and extension.
            seen = set()
            for e in sorted(group, key=lambda e: e["mb"]):
                key = (e["mode"], e["name"].rsplit(".", 1)[-1].lower()) if distinct else e["sha256"]
                if key in seen or len(seen) >= keep:
                    continue
                seen.add(key)
                chosen[e["sha256"]] = e
    # Sweep: the smallest file of every other camera in the archive, so the probe
    # answers "which cameras" as well as "which modes".
    covered = {(e["make"], e["model"]) for e in chosen.values()}
    smallest = {}
    for e in entries:
        key = (e["make"], e["model"])
        if key not in covered and (key not in smallest or e["mb"] < smallest[key]["mb"]):
            smallest[key] = e
    chosen.update((e["sha256"], e) for e in smallest.values())
    pool = sorted(chosen.values(), key=lambda e: (e["make"], e["model"], e["mb"]))
    for e in pool:
        e["file"] = f"{e['sha256'][:8]}-{re.sub(r'[^A-Za-z0-9.()-]+', '_', e['name'])}"
    POOL.write_text(json.dumps(pool, indent=1) + "\n")
    print(f"{len(pool)} files, {sum(e['mb'] for e in pool) / 1024:.2f} GB -> {POOL.relative_to(ROOT)}")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_one(entry):
    target = CORPUS / entry["file"]
    if target.exists() and sha256(target) == entry["sha256"]:
        return "cached", entry
    url = urllib.parse.quote(entry["url"], safe=":/")
    partial = target.with_suffix(target.suffix + ".part")
    try:
        with urllib.request.urlopen(url, timeout=300) as response, open(partial, "wb") as out:
            while chunk := response.read(1 << 20):
                out.write(chunk)
    except Exception as error:  # one bad link must not stop the rest
        partial.unlink(missing_ok=True)
        return f"failed: {error}", entry
    if sha256(partial) != entry["sha256"]:
        partial.unlink()
        return "failed: checksum mismatch", entry
    partial.rename(target)
    return "fetched", entry


def fetch(only=()):
    pool = json.loads(POOL.read_text())
    if only:
        pool = [e for e in pool if any(fragment in e["file"] for fragment in only)]
        if not pool:
            sys.exit(f"no file in the pool matches {' / '.join(only)}")
    CORPUS.mkdir(parents=True, exist_ok=True)
    failures = 0
    with ThreadPoolExecutor(max_workers=6) as workers:
        for status, entry in workers.map(fetch_one, pool):
            if status.startswith("failed"):
                failures += 1
                print(f"{status}: {entry['file']}", flush=True)
    print(f"{len(pool) - failures}/{len(pool)} files present in {CORPUS.relative_to(ROOT)}")
    return 1 if failures else 0


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "pool":
        build_pool()
    elif command == "fetch":
        only = sys.argv[3:] if sys.argv[2:3] == ["--only"] else ()
        sys.exit(fetch(only))
    else:
        sys.exit(__doc__)
