# RawInputKit

[![CI](https://github.com/rlx/RawCameraSDK/actions/workflows/ci.yml/badge.svg)](https://github.com/rlx/RawCameraSDK/actions/workflows/ci.yml)

RawInputKit opens camera RAW files on iOS and macOS. It uses Apple's system decoder when
that can develop the file and falls back to LibRaw when it can't. The repository is named
RawCameraSDK. The Swift package and module in it are RawInputKit.

This is a work sample. I wanted to know how much of RAW support Apple's decoder already
covers, what it leaves out, and what it takes to cover that. I had VSCO's Studio Pro in
mind while building it. Studio Pro does not import RAW yet, although VSCO's main app
already edits RAW on iOS, so I looked at the work around the decoder more than at decoding:
which files Apple turns away, how a second decoder can sit behind it and still produce
matching pictures, and how the data gets to an engine that isn't built on Core Image.

## What I would do

Ship RAW on Apple's decoder alone, ask it for scene-linear output, and store the decoder
version with each edit. Do not build a second decoder yet. Log which files Apple turns
away first, and build the fallback only if that log shows real demand.

I built the fallback anyway, to find out what it costs and what it buys. It buys 11% of
the test files, most of them from cameras that are old or rare. It costs 0.85 MB of
binary, a C++ parser of untrusted files inside the app, and a color check on every camera
each time LibRaw is updated.

Three things would change my mind: the rejection log showing a share of imports that
justifies those costs, a requirement that iOS, Android and the web render the same file
identically, or Apple dropping a format people still shoot.
[Docs/RECOMMENDATION.md](Docs/RECOMMENDATION.md) has the full argument.

## Findings

1. Apple's decoder opens 87% of 944 test files, and 93% of the ones shot since 2019.
2. With a fallback on LibRaw and a Metal kernel the total is 98%. Most of what the
   fallback adds is old or niche, such as Sigma Foveon, Samsung NX and some Phase One modes.
3. By default the two decoders produce different-looking pictures. If both are asked for
   scene-linear data and exposure is measured the same way, the median difference between
   them is about ΔE 3. That is color and tone averaged over areas of the frame. It says
   nothing about sharpness or noise.
4. On an iPhone 16 Pro Max the fallback is at least as fast as Apple's decoder on Bayer
   sensors up to 50 MP. On Fujifilm X-Trans it is six to nine times slower.
5. The fallback sometimes decodes a file with the wrong colors. It compares each result
   with the camera's embedded preview and flagged 15 of 822.

Numbers, charts and method are in [Docs/MEASUREMENTS.md](Docs/MEASUREMENTS.md).

![A walkthrough of the demo app: one file through both decoders and both looks, then a file only the fallback opens](Docs/walkthrough.gif)

## Contents

| Path | Contents |
|---|---|
| `Sources/RawInputKit` | The Swift library |
| `Sources/RawShim` | C interface over LibRaw. Together they are the portable core, with no Apple APIs |
| `Bindings/rust`, `Bindings/web` | Experimental: the core as a Rust crate (kernel in WGSL, run through wgpu) and as WebAssembly. They decode and develop, and nothing more |
| `Sources/rawprobe` | Command-line tools for the measurements: coverage, benchmark, comparisons, fuzzing |
| `Examples/RawInputDemo` | SwiftUI demo for iPhone and Mac with eleven sample files |
| `Docs` | Measurements, architecture, recommendation, build instructions |

```swift
import RawInputKit

let raw = try await RawInput.open(url, options: .sceneLinear)  // Apple's decoder or the fallback
raw.route                                                      // which one was used
let picture = raw.rendered(look: .neutral)                     // same rendering for both
let texture = try raw.makeTexture(device: device)              // for an engine that works in Metal
let thumbnail = try RawInput.preview(url)                      // the camera's embedded JPEG

// From PhotoKit, which delivers bytes and a type:
let raw = try await RawInput.open(data: data, typeHint: resource.uniformTypeIdentifier)

// Reopening an edit with the decoder version it was made on:
edit.decoderVersion = raw.appleDecoderVersion                  // "8"
options.appleDecoderVersion = .pinned(edit.decoderVersion)
```

`open` is also available as a blocking call. The `async` form decodes on a background
queue and stops when its task is canceled.

## Coverage

The test set is 944 files from 898 camera models, all CC0 samples from
[raw.pixls.us](https://raw.pixls.us). Each file counts once regardless of how common the
camera is, so the percentages describe formats and don't reflect what people shoot today.

| | Files | Share |
|---|---|---|
| Apple's decoder opens it | 821 | 87% |
| Only the fallback opens it | 107 | 11% |
| Neither opens it | 16 | 2% |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Docs/coverage-by-brand-dark.svg">
  <img src="Docs/coverage-by-brand-light.svg" alt="Stacked bars per camera brand: files Apple's decoder opens, files only the fallback opens, files neither opens">
</picture>

Apple also opens 14 files that the fallback cannot, including Nikon High Efficiency and
JPEG XL DNG, so the library tries Apple first.

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

- Whether Apple supports a file depends on the compression mode as well as the camera, and
  `CIRAWFilter` can return an image that renders empty for a file it can't develop. The
  library checks by rendering a small region.
- Plain Bayer files are developed on the GPU in one kernel: black level, white balance,
  Hamilton-Adams demosaicing, color matrix. The kernel is written in Metal and in WGSL,
  and the same sixteen conformance cases run against both.
- X-Trans, Foveon, monochrome sensors and Phase One backs go through LibRaw's own pipeline.
- Every route keeps the camera's colors outside sRGB. The image is in extended linear
  sRGB, where those colors have components below zero, and `makeTexture` can deliver any
  linear space, such as Display P3.
- Sizes, margins and levels read from the file are validated before use. There is a memory
  limit, and a decode can be canceled. CI decodes damaged files under AddressSanitizer on
  every push.
- An event handler receives the files Apple rejected, GPU failures and results with
  suspect color.

[Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) describes the code.
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

[Docs/BUILDING.md](Docs/BUILDING.md) has the rest: the demo, running on a device, the Rust
and WebAssembly builds, and regenerating the measurements.

## Limitations

- The fallback has no lens correction, noise reduction or highlight recovery, and it uses
  LibRaw's color matrices where Apple uses its own. With shared rendering the two decoders
  come close but do not match exactly.
- The fallback clips highlights at sensor white. Apple's decoder keeps values above it.
- Apple's decoder cannot identify Sony, Samsung, Pentax and some Nikon files from bytes in
  memory. Without a type hint the library finds the type by trial, which takes up to a
  second for the first file of a camera model and a millisecond after that. Pass the type
  PhotoKit reports to avoid it. Phase One files in a TIFF container open from disk on
  Apple's decoder but not from memory under any type, so from memory they use the fallback.
- A support answer is cached per camera and storage mode, so a damaged file from a
  supported camera reaches Apple's decoder untested and can render empty.
  `appleSupportCheck = .everyFile` tests each file, at 0.1 to 0.7 s apiece.
- Default brightness is measured per picture. That works for viewing but would flatten a
  bracketed series. A product would use a calibrated baseline per camera.
- X-Trans and Foveon files run on a single CPU core and take seconds.
- Above 64 MP the fallback develops mosaic sensors at half size to limit memory on phones.
- A truncated file in an uncompressed format is not detected and decodes with empty rows.
- The color check needs an embedded preview. It reports a suspect result and still
  returns the image.
- Timings come from one phone with 8 GB of memory. Smaller phones are untested.
- The Rust and WebAssembly bindings are experiments in how far the core carries. They
  decode and develop but lack the looks, the color check and cancellation, and their CPU
  output is still clipped to sRGB. The WebAssembly build was tested under Node and not in a
  browser.

## License

RawInputKit is released under the [MIT license](LICENSE). It links LibRaw 0.22.2,
unmodified, under LibRaw's CDDL-1.0 option. See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). The sample images are CC0. They are
downloaded during the build and are not part of this repository.
