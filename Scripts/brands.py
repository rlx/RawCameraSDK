"""One spelling per camera maker.

The archive records the maker as each camera wrote it, so the same company turns up as
"Olympus", "OLYMPUS" and "OM System", or "Gitup" and "GITUP". Counting brands or grouping
files by brand without folding those together overstates the number of brands and splits
their rows.
"""

# Companies that changed name, or that cameras spell in more than one way.
ALIASES = {
    "om system": "Olympus / OM",
    "om digital solutions": "Olympus / OM",
    "olympus": "Olympus / OM",
    "blackmagic design": "Blackmagic",
    "autel robotics": "Autel",
    "huawei": "Huawei",
}


def brand(make):
    """The display name for a maker: an alias if there is one, otherwise the maker's own
    spelling with shouted capitals toned down, so that case variants group together."""
    key = " ".join(make.split()).casefold()
    if key in ALIASES:
        return ALIASES[key]
    # All-caps and all-lower names become title case; mixed-case names (GoPro, KanDao) are
    # kept, with the first spelling met standing for its case variants.
    return _CANONICAL.setdefault(key, make.title() if make.isupper() or make.islower() else make)


# Names whose capitalisation title-casing would get wrong.
_CANONICAL = {
    "gopro": "GoPro", "dji": "DJI", "lg": "LG", "sjcam": "SJCAM", "gitup": "GitUp", "kandao": "KanDao",
    "htc": "HTC", "asus": "ASUS", "bq": "BQ", "madv": "MADV", "hmd global": "HMD Global",
}
