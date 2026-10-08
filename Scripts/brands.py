"""One spelling per camera maker.

The archive records the maker as each camera wrote it ("Olympus", "OLYMPUS", "OM System"),
which would split a brand's rows.
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
    """The display name for a maker: an alias, or its own spelling with case variants folded."""
    key = " ".join(make.split()).casefold()
    if key in ALIASES:
        return ALIASES[key]
    # All-caps and all-lower names become title case. Mixed-case names (GoPro, KanDao) keep
    # the first spelling met.
    return _CANONICAL.setdefault(key, make.title() if make.isupper() or make.islower() else make)


# Names whose capitalisation title-casing would get wrong.
_CANONICAL = {
    "gopro": "GoPro", "dji": "DJI", "lg": "LG", "sjcam": "SJCAM", "gitup": "GitUp", "kandao": "KanDao",
    "htc": "HTC", "asus": "ASUS", "bq": "BQ", "madv": "MADV", "hmd global": "HMD Global",
}
