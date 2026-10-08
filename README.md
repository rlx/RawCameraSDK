# RawInputKit

[![CI](https://github.com/rlx/RawCameraSDK/actions/workflows/ci.yml/badge.svg)](https://github.com/rlx/RawCameraSDK/actions/workflows/ci.yml)

A work sample. I took one problem, getting camera RAW files into an editor, and tried to
answer it with measurements instead of assumptions: how much does Apple's system decoder
already solve, what is left, and what does it cost to cover the rest?

It was written with VSCO's Studio Pro in mind. Studio Pro does not import RAW yet, while
VSCO's main app already edits RAW on iOS, so decoding is not the open question
there. What I looked at is the part around the decoder: which files it turns away, how a
second decoder can sit behind it without changing how pictures look, and how the result
reaches an engine that is not built on Core Image. My recommendation is one page:
[Docs/RECOMMENDATION.md](Docs/RECOMMENDATION.md).

## What I found

1. Apple's decoder opens 87% of 944 test files, and 93% of those shot since 2019. For most
   cameras, the right decoder is the one already on the device.
2. A fallback built on LibRaw and a Metal kernel opens most of the rest: 98% together.
   What it adds is mostly old or niche: Sigma Foveon, Samsung NX, some Phase One modes.
3. The two decoders' pictures look different by default. Taking scene-linear data from both
   and measuring exposure the same way brings them to a median colour difference of ΔE 3.
4. On an iPhone 16 Pro Max the fallback is as fast as Apple's decoder or faster on Bayer
   sensors up to 50 MP, and six to eight times slower on Fujifilm X-Trans.
5. The fallback is sometimes wrong without knowing it. It now checks each result against
   the camera's embedded preview and flags the ones that disagree: 15 of 822.

The numbers, charts and method are in [Docs/MEASUREMENTS.md](Docs/MEASUREMENTS.md).

![A walkthrough of the demo app: one file through both decoders and both looks, then a file only the fallback opens](Docs/walkthrough.gif)

## What is here

| Part | What it is |
|---|---|
| `Sources/RawInputKit` | The Swift library: one call that tries Apple's decoder and falls back to LibRaw |
| `Sources/RawShim` | The portable core's C interface over LibRaw; no Apple APIs |
| `Bindings/rust`, `Bindings/web` | The same core as a Rust crate (with the kernel in WGSL under wgpu) and as WebAssembly |
| `Sources/rawprobe` | The measuring tools: coverage probe, benchmark, comparisons, fuzzing |
| `Examples/RawInputDemo` | A SwiftUI app for iPhone and Mac, with eleven sample files |
| `Docs` | Measurements, architecture, the recommendation, and how to build everything |

```swift
import RawInputKit

let raw = try RawInput.open(url, options: .sceneLinear)   // Apple's decoder, or the fallback
raw.route                                                 // which one
let picture = raw.rendered(look: .neutral)                // one rendering step for both
let texture = try raw.makeTexture(device: device)         // or hand the data to a GPU engine
let thumbnail = try RawInput.preview(url)                 // the camera's embedded JPEG
```

## Coverage

944 files from 898 camera models, all CC0 samples from [raw.pixls.us](https://raw.pixls.us).
Every file counts once, so this is coverage of formats, not of what photographers shoot.

| | Files | Share |
|---|---|---|
| Apple's decoder opens it | 821 | 87% |
| Only the fallback opens it | 107 | 11% |
| Neither opens it | 16 | 2% |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Docs/coverage-by-brand-dark.svg">
  <img src="Docs/coverage-by-brand-light.svg" alt="Stacked bars per camera brand: files Apple's decoder opens, files only the fallback opens, files neither opens">
</picture>

Neither decoder is a superset of the other. Apple opens 14 files the fallback cannot,
among them Nikon High Efficiency and JPEG XL DNG. That is why the order is Apple first.

## How it works

```
RawInput.open(url)
   │
   ├─ Can Apple develop it?  Render a small region and see whether pixels come out.
   │                         A "yes" is remembered per camera and recording mode.
   │
   ├─ yes ─ CIRAWFilter ──────────────────────────────────┐
   │                                                      ├─▶ RawImage: linear CIImage, info, route
   └─ no ── portable core (C) ─ LibRaw decompresses       │
              ├─ plain Bayer ───── GPU kernel ────────────┤
              └─ everything else ─ LibRaw CPU pipeline ───┘
```

- Routing is by trying, not by camera name. Support depends on the compression mode, and
  `CIRAWFilter` can return an image that renders as nothing for a file it cannot develop.
- Plain Bayer files are developed on the GPU: black level, white balance, Hamilton-Adams
  demosaicing and the colour matrix in one kernel. It exists in Metal and in WGSL, and both
  are checked against the same sixteen conformance cases.
- Everything else goes through LibRaw's own pipeline: X-Trans, Foveon, monochrome sensors,
  Phase One backs.
- Sizes, margins and levels from the file are validated before they reach the GPU, there
  is a memory limit, and a decode can be cancelled.
- The library reports what it did: each file Apple turned away, each GPU failure, each
  result whose colour it doubts.

[Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) is the guide to the code.
[Docs/PORTING.md](Docs/PORTING.md) covers the Rust and WebAssembly builds.

## Building

Requires Xcode 27.

```sh
git clone --recurse-submodules https://github.com/rlx/RawCameraSDK.git && cd RawCameraSDK
swift build
Examples/RawInputDemo/Scripts/fetch-samples.sh    # sample files for the tests, 285 MB
swift test
open Examples/RawInputDemo/RawInputDemo.xcodeproj
```

The demo, device testing, the Rust and WebAssembly builds, and how to regenerate every
measurement are in [Docs/BUILDING.md](Docs/BUILDING.md).

## Limits

- The fallback has no lens correction, noise reduction or highlight recovery, and uses
  LibRaw's colour matrices where Apple uses its own. After the shared rendering step the
  two routes are close, not identical.
- Its output is clipped to sRGB primaries, which discards gamut a RAW file has.
- Default brightness is measured per picture. That is fine for viewing and wrong for a
  bracketed series; a product would use a calibrated baseline per camera.
- X-Trans and Foveon run on one CPU core and take seconds.
- Above 64 MP the fallback develops mosaic sensors at half size to stay within a phone's memory.
- Truncated files in uncompressed formats are not detected; they decode with empty rows.
- The colour check needs an embedded preview and reports instead of refusing.
- Measured on one phone, with 8 GB of memory. Smaller phones are untested.
- The Rust and WebAssembly bindings decode and develop; they do not have the looks, the
  colour check or cancellation. The WebAssembly build has been run under Node, not in a browser.

## Licence

RawInputKit is under the [MIT licence](LICENSE). It links LibRaw 0.22.2 under LibRaw's
CDDL-1.0 option, unmodified, as a submodule; see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). The sample images are CC0 and are
downloaded, not redistributed here.
