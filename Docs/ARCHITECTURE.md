# Architecture

How the code is organised and the decisions that are not obvious from reading it.
Build and measurement commands are in [BUILDING.md](BUILDING.md).

## Layout

```
Package.swift                  SwiftPM targets
CMakeLists.txt                 the core for C hosts and WebAssembly
Vendor/LibRaw/                 LibRaw 0.22.2, unmodified submodule
Sources/
  RawShim/                     C interface over LibRaw (C++, no Apple APIs)
  RawInputKit/                 the library (Swift)
  rawprobe/                    measurement tools (Swift, macOS command line)
Shaders/develop.wgsl           development kernel in WGSL
Conformance/                   test cases shared by the Metal and WGSL kernels
Bindings/                      rust/, web/, and a C smoke test
Tests/RawInputKitTests/        Swift Testing suites
Tests/*.json                   corpus list and measurement results
Examples/RawInputDemo/         SwiftUI app for iOS and macOS
Scripts/                       corpus download, coverage report, charts, device runs
```

```
rawprobe ─┐
          ├─▶ RawInputKit ─▶ RawShim ─▶ CLibRaw (Vendor/LibRaw)
demo app ─┘        │
                   └─▶ Core Image, Metal, ImageIO
```

- `CLibRaw` compiles LibRaw unchanged, with zlib (compressed DNG) and X3F (Sigma Foveon)
  enabled.
- `RawShim` is the only code that includes LibRaw headers. With LibRaw it forms the
  portable core that the Rust and WebAssembly builds also compile, so it must not use OS
  or GPU APIs. See [PORTING.md](PORTING.md).
- `RawInputKit` is the only Swift code that imports `RawShim`. No LibRaw type appears in
  its public API.

## Where to start

| File | Contents |
|---|---|
| `RawInputKit/RawInput.swift` | Public entry points and routing |
| `RawInputKit/AppleRawDecoder.swift` | The Apple route and the support check |
| `RawShim/include/RawShim.h` | The C interface: lifecycle, ownership, fields |
| `RawShim/RawShim.cpp` | Its implementation and LibRaw's pitfalls |
| `RawInputKit/FallbackRawDecoder.swift` | The two fallback paths |
| `RawInputKit/MetalDevelop.swift` | The GPU kernel |

Applied after decoding: `ExposureEstimate` (default brightness), `PreviewAgreement` (the
colour check) and `RawLook` (shared rendering).

## Opening a file

```
RawInput.open(url)
   │
   ├─ AppleSupport.canDecode ───── cached for this camera and mode, or render a small
   │                               region with Apple's engine and check for pixels
   │
   ├─ yes ─ AppleRawDecoder.decode ───────────────────────────────┐
   │                                                              ├─▶ RawImage
   └─ no ── FallbackRawDecoder.decode                             │
              LibRawFile(url).unpack()                            │
              ├─ rik_info.plain_bayer ─▶ MetalDevelop.develop ────┤   GPU path
              └─ otherwise ───────────▶ LibRaw dcraw_process ─────┘   CPU path

RawImage ─▶ rendered(look:)        exposure, then one lookup table
```

### Routing

Apple's API does not report whether it supports a file. Support depends on camera and
compression mode and changes with OS updates, and `CIRAWFilter` can return an image that
renders empty. `AppleRawDecoder.canDecode` therefore renders a 64-pixel square from the
middle of the frame.

The check adds 0.1 to 0.7 s on a Mac, because Apple's engine decompresses the sensor data
up to that region. `AppleSupport` caches a positive answer per camera model, decoding
routine and frame size. A negative answer is not cached, since it may come from one
damaged file.

### Fallback paths

LibRaw's CPU pipeline handles every sensor type but is single-threaded and takes seconds
per frame. Plain Bayer files need only black level, white level, white balance and a 3x3
matrix, so for those LibRaw decompresses and a GPU kernel develops.

`capture_bayer_state` in the core sets `plain_bayer` when every assumption of the kernel
holds, and `rik_get_develop_params` computes the kernel's parameters so the Metal and WGSL
kernels use the same values. Other files, and any GPU failure, go to the CPU path.

### Shared rendering

Both decoders return scene-linear data and `RawLook` turns it into a picture:

1. Exposure, from `ExposureEstimate.measure`, which reads the pixels and is the same for
   both routes. It is automatic exposure and would flatten a bracketed series.
2. The look: contrast curve, saturation, tints and fade in a 33-point 3D lookup table,
   applied with `CIColorCubeWithColorSpace`.

Apple's decoder must be opened with `appleRendering = .linear` for the two routes to match.
`RawImage.isSceneLinear` reports it.

### Colour check

LibRaw decodes some cameras with wrong colours, usually ones newer than its tables.
`PreviewAgreement` compares the fallback's result with the embedded preview by
chromaticity on a 24x16 grid. The distance is in `RawImage.previewDistance`, and
`isColorSuspect` is true above 0.15. The image is still returned so the caller can decide
what to do with it.

### Events, limits, cancellation

`RawDecodeOptions.eventHandler` receives a `RawEvent` when Apple rejects a file, when the
GPU path fails, when colour is suspect, and when a file has been opened.
`fallbackMemoryLimitMB` refuses a file whose header asks for too much memory. `isCancelled`
is polled between decoding stages.

## Conventions

**Output.** Both routes return an upright, linear-light `CIImage`. The fallback's is
scene-linear with sRGB primaries, clipped at 1. See the doc comment on `RawImage.image`.

**Coordinates.** LibRaw's sensor plane includes masked borders. Per-position data (colour
pattern, black levels) is indexed from the picture's top-left pixel as
`(row & 1) * 2 + (column & 1)`. The kernel adds the origin when it reads the texture.

**Orientation.** `FallbackRawDecoder` applies the camera's orientation once, at the end.
`RawInfo.width` and `height` describe the unrotated frame.

**Vertical flips.** Metal's first row is the top and Core Image's origin is the bottom, so
`MetalDevelop` flips its result. Bitmap data passed to Core Image is not flipped.

**Buffer lifetime.** Pointers from the core are valid until the handle closes. `LibRawFile`
exposes buffers only inside closures (`withMosaic`, `withDeveloped`, `withThumbnail`). Do
not add an accessor that returns a pointer.

**Parameter block.** `rik_develop_params`, `MetalDevelop.Parameters`, and `Params` in both
shaders are the same 128 bytes. Change all four together.

**LibRaw state.** A `LibRaw` object rewrites its own fields as calls are made. The core
captures what it needs at unpack time. `RawShim.cpp` lists which call makes which field
valid.

**Deferred rendering.** `CIContext.createCGImage` returns before rendering by default.
Code that measures or checks a render uses `RawMeasurement.renderFully` or passes
`deferred: false`.

**Untrusted input.** Sizes, margins and levels are validated in the core before they reach
the kernel. Data LibRaw reports as corrupt becomes `RawError.corruptData`. LibRaw does not
report a short read of an uncompressed format, so those files decode with empty rows.

## Tests

`swift test` runs everything. Suites skip themselves when their files are missing and print
how to fetch them. `Scripts/device-tests.sh` runs the same sources on a device, hosted in
the demo app.

| Suite | Needs | Covers |
|---|---|---|
| Metal kernel | a GPU | Demosaic, pattern indexing, origin, flips and clipping on synthetic mosaics, including the shared conformance cases |
| Exposure estimate, Metadata | nothing | Pure functions, including non-finite input |
| Looks | nothing | Curve properties, lookup-table layout, agreement with Core Image |
| Preview agreement | nothing | Flags a colour cast or a flipped picture, ignores brightness |
| Robustness | nothing (truncation uses the samples) | Missing, empty, random and truncated files |
| Bundled samples | `fetch-samples.sh`, 285 MB | Each sample fails on Apple and develops on the fallback; events, cancellation, memory limit |
| Decoder agreement | the same, plus `corpus.py fetch --only DMC-LX10_-_1_1` | Size, colour and crop agree between routes; texture output |

Outside `swift test`:

- `Examples/RawInputDemo/UITests` drives the demo in the simulator.
  `Scripts/record-demo.sh` records it for the README.
- `rawprobe fuzz FILE...` decodes damaged copies of files in child processes and keeps
  inputs that crash or hang in `fuzz-findings/`.
- `cargo test --features gpu` in `Bindings/rust`, and `node Bindings/web/test.mjs`.

CI runs the Swift tests, builds the demo for iOS, and builds and tests the Rust crate and
the WebAssembly module, on macOS and Linux.

`appleRejectsIt` fails when an OS update adds support for a sample's format. Replace the
sample with another from the fallback-only list in `Docs/coverage.md`.

## Tasks

### Inspect one file

```sh
swift run -c release rawprobe render FILE out.jpg            # automatic routing
swift run -c release rawprobe render FILE out.jpg fallback   # force a route
swift run -c release rawprobe compare FILE out.jpg           # both routes side by side
swift run -c release rawprobe looks FILE out.jpg             # both routes through the looks
```

### Debug a wrong-looking decode

1. `rawprobe render FILE out.jpg fallback` prints the path, size, exposure and preview
   distance.
2. On the GPU path, check black level, white level and white balance in `rik_info`. A pink
   or green haze means a wrong black level. Magenta highlights mean the white level is
   too high.
3. On the CPU path, compare with LibRaw's `dcraw_emu`.
4. For wrong framing, check `apply_camera_crop` and the file's `raw_inset_crops`.

### Send a camera to the CPU path

Add its condition to `needs_libraw` in `capture_bayer_state`, as for Phase One.

### Update LibRaw

```sh
cd Vendor/LibRaw && git fetch --tags && git checkout <tag>
```

Check the exclusions in `Package.swift` against LibRaw's `Makefile.devel`, run the tests,
rerun the probe and compare `Docs/coverage.md`. LibRaw must stay unmodified. See
`THIRD-PARTY-NOTICES.md`.

## Demo app

A gallery of embedded previews and a detail view with a decoder picker, a look picker and
an exposure slider.

- `Develop.swift` runs the library's blocking calls on its own dispatch queue.
- `DetailModel.swift` discards results that arrive after a newer request and renders one
  frame at a time with the latest slider value.

The Xcode project is generated from `project.yml` with XcodeGen and committed. A build
phase downloads the sample files.

## Not implemented

- Lens correction, noise reduction and highlight recovery on the fallback.
- Wide-gamut output. The fallback converts to sRGB primaries and clips at 1.
- Tiled development. The GPU path develops a frame into one texture, so very large frames
  are halved.
- X-Trans on the GPU.
- Nikon High Efficiency and JPEG XL DNG on the fallback. Apple's decoder opens both.
