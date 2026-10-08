# Third-party notices

## LibRaw

RawInputKit's fallback decoder is [LibRaw](https://www.libraw.org) 0.22.2,
Copyright © 2008–2026 LibRaw LLC.

LibRaw is dual-licensed. This project uses it under the Common Development and
Distribution License, version 1.0 (CDDL-1.0). The license text is in [`Vendor/LibRaw/LICENSE.CDDL`](Vendor/LibRaw/LICENSE.CDDL).

- The source is included unmodified as a git submodule at `Vendor/LibRaw`, pinned to the
  `0.22.2` tag of <https://github.com/LibRaw/LibRaw>. No LibRaw file has been changed.
- RawInputKit's code is in separate files and calls LibRaw's public API through
  `Sources/RawShim`.
- An app that ships RawInputKit must keep this notice and tell its users where to get the
  LibRaw source, including any changes made to LibRaw's files.

LibRaw bundles code under other terms, listed in
[`Vendor/LibRaw/COPYRIGHT`](Vendor/LibRaw/COPYRIGHT): the DCB and FBDD demosaic routines
and the X3F (Foveon) decoder are BSD-style licensed.

This describes the project's setup and is not legal advice.

## Sample images

The RAW files used by the demo app and the tests come from
[raw.pixls.us](https://raw.pixls.us) and are released by their photographers under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). They are downloaded at
build time and are not part of this repository.
