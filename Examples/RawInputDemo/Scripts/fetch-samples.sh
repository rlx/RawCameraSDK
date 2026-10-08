#!/bin/sh
# Downloads the sample RAW files listed in Samples/manifest.json into Samples/files and
# checks each against its SHA-256. The files (285 MB, CC0, from raw.pixls.us) are not in
# the repository. Runs as an Xcode build phase and by hand before `swift test`.
# Verification is remembered in Samples/files/.verified, so later builds skip hashing.
set -eu
cd "$(dirname "$0")/.."
mkdir -p Samples/files
stamp=Samples/files/.verified
list=$(mktemp)
trap 'rm -f "$list"' EXIT

# File name, checksum, URL per line. Written to a file so a failure here stops the script.
/usr/bin/python3 - > "$list" <<'PY'
import json, urllib.parse
for sample in json.load(open("Samples/manifest.json")):
    print(sample["file"], sample["sha256"], urllib.parse.quote(sample["url"], safe=":/"), sep="\t")
PY

up_to_date=yes
[ -f "$stamp" ] && [ "$stamp" -nt Samples/manifest.json ] || up_to_date=no
while IFS="$(printf '\t')" read -r file sha url; do
    [ -f "Samples/files/$file" ] && [ "$stamp" -nt "Samples/files/$file" ] || up_to_date=no
done < "$list"
[ "$up_to_date" = yes ] && exit 0

while IFS="$(printf '\t')" read -r file sha url; do
    target="Samples/files/$file"
    if [ -f "$target" ] && [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$sha" ]; then
        continue
    fi
    echo "Fetching $file"
    curl --fail --location --silent --show-error --output "$target.part" "$url"
    if [ "$(shasum -a 256 "$target.part" | cut -d' ' -f1)" != "$sha" ]; then
        rm -f "$target.part"
        echo "error: checksum mismatch for $file" >&2
        exit 1
    fi
    mv "$target.part" "$target"
done < "$list"
touch "$stamp"
