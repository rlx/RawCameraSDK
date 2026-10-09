# Architecture

How the code is organized and the decisions that are not obvious from reading it.
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
| `RawInputKit/RawSource.swift` | A file on disk or bytes in memory, and how each reaches the decoders |
| `RawInputKit/AppleRawDecoder.swift` | The Apple route and the support check |
| `RawShim/include/RawShim.h` | The C interface: lifecycle, ownership, fields |
| `RawShim/RawShim.cpp` | Its implementation and LibRaw's pitfalls |
| `RawInputKit/FallbackRawDecoder.swift` | The two fallback paths |
| `RawInputKit/MetalDevelop.swift` | The GPU kernel |

Applied after decoding: `ExposureEstimate` (default brightness), `PreviewAgreement` (the
color check) and `RawLook` (shared rendering).

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
up to that region. `AppleSupport` caches a positive answer per camera model, frame size
and storage mode. The storage mode (`rik_storage_mode`) is the decoding routine with the
compression code, bit depth and the makers' own compression fields, because one routine
can serve a lossless mode Apple supports and a lossy one it does not. A negative answer is
not cached, since it may come from one damaged file.

A damaged file of a cached kind therefore goes to Apple untested, and Apple's image is
lazy, so the library cannot see it render empty. `appleSupportCheck = .everyFile` trades
the cache for a test of each file.

### Files in memory

`RawInput.open(data:typeHint:)` exists because PhotoKit delivers bytes. LibRaw reads them
in place (`rik_open_buffer`), and `LibRawFile` keeps them alive. Apple's decoder needs the
exact type for TIFF-based formats that ImageIO reports as plain TIFF. With no hint,
`RawSource.memory` tries the registered RAW types, the camera maker's first, and keeps the
first one the decoder reads a frame size with. That needs no decoding. All types are
tried and not only the maker's, because a rebadged camera such as the Hasselblad Lunar
writes another maker's container. The answer is remembered per camera model.

### From the photo library

The demo's Photos button is the whole integration (`PhotoImport.swift`): a `PhotosPicker`
created with `preferredItemEncoding: .current`, so the file comes as stored and not as a
converted JPEG. `RawInput.rawTypeIdentifier(among:)` picks the RAW type out of what the item
offers, the item's data is requested as a RAW image, and both go to `open(data:typeHint:)`.
The picker runs out of process, so the app needs no photo library permission.

PhotoKit reports the exact type Apple's decoder needs for each of the sample formats, for
example `com.sony.arw-raw-image` and `com.samsung.raw-image`. That is measured, in
`PhotoLibraryTests.swift`, and is why passing the type through matters.

### Async and cancellation

The blocking functions are the implementation. The `async` forms of `open` run them on a
concurrent dispatch queue, since a decode blocks for up to seconds and must stay off the
cooperative pool. Task cancellation sets a flag that the fallback polls between stages.
The Apple route does no decoding at open time, so there the flag is only checked at the
end.

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

### Color check

LibRaw decodes some cameras with wrong colors, usually ones newer than its tables.
`PreviewAgreement` compares the fallback's result with the embedded preview by
chromaticity on a 24x16 grid. The distance is in `RawImage.previewDistance`, and
`isColorSuspect` is true above 0.15. The image is still returned so the caller can decide
what to do with it.

### Events, limits, cancellation

`RawDecodeOptions.eventHandler` receives a `RawEvent` when Apple rejects a file, when the
GPU path fails, when color is suspect, and when a file has been opened.
`isCancelled` is polled between decoding stages.

### Memory budget

A decode holds whole frames, so an unbounded import ends with the system killing the app.
`DecodeBudget` gives decoding a quarter of physical memory and derives two limits from it:

- `DecodeGate` admits one async decode per 4 GB of memory, between 1 and 4. The rest
  suspend in arrival order, holding no thread and no memory, and a task canceled while it
  waits leaves the queue. `RawInput.maximumConcurrentDecodes` changes the number.
- `fallbackMemoryLimitMB` defaults to the budget divided by that number. After unpacking,
  `WorkingMemory` adds up what the chosen path will hold at its peak: the sensor data, and
  either the mosaic texture and a float frame (GPU, about 12 bytes per pixel) or LibRaw's
  working image, its result and the RGBA copy (CPU, about 24). A file over the limit throws
  before it is developed. LibRaw's own cap on the sensor data uses the same number.

The blocking functions bypass the gate, since their caller owns the threads. Apple's route
allocates at render time, inside Core Image, and is outside both limits.

## Output contract

Every route returns an upright, linear-light `CIImage` in Core Image's working space,
extended linear sRGB. What differs:

| | Apple, `.linear` | Fallback, GPU path | Fallback, CPU path |
|---|---|---|---|
| Scene-linear | yes | yes | yes |
| Colors outside sRGB | kept | kept, as components below 0 | kept, through Rec. 2020 primaries |
| Highlights above sensor white | kept, above 1 | clipped at 1 | clipped at 1 |
| Lens correction, noise reduction | Apple's | none | none |
| Color matrices | Apple's | LibRaw's | LibRaw's |
| Backing store | decoded at render time | `rgba16Float` Metal texture | 16-bit bitmap |
| Pinned by | `RawImage.appleDecoderVersion` | `RawInput.fallbackVersion` | `RawInput.fallbackVersion` |

The CPU path's pixels are 16-bit unsigned integers, which cannot hold a negative
component. With sRGB primaries LibRaw would clip every color outside sRGB, so the library
asks it for Rec. 2020 (`rik_set_output_primaries`) and tags the bitmap accordingly.

`makeTexture(device:colorSpace:)` converts to the engine's linear space. With no color
space and an upright picture from the GPU path on the same device, it returns that path's
texture itself.

## Conventions

**Coordinates.** LibRaw's sensor plane includes masked borders. Per-position data (color
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
| Metal kernel | a GPU | Demosaic, pattern indexing, origin, flips, clipping and colors outside sRGB on synthetic mosaics, including the shared conformance cases |
| Exposure estimate, Metadata | nothing | Pure functions, including non-finite input |
| Photo library types | nothing | The RAW type is picked out of a RAW plus JPEG pair; every type PhotoKit reported is recognized |
| Photo library | the simulator, through `photo-library-tests.sh` | Each sample saved to Photos and read back through PhotoKit: bytes identical, the reported type, the same decoder and picture as from disk, with and without the type. Photos refuses X3F |
| Decode budget | nothing | The gate never exceeds its limit, drops a canceled waiter and admits more when the limit rises; the working-memory estimate |
| Looks | nothing | Curve properties, lookup-table layout, agreement with Core Image |
| Preview agreement | nothing | Flags a color cast or a flipped picture, ignores brightness |
| Robustness | nothing (truncation uses the samples) | Missing, empty, random and truncated files |
| Bundled samples | `fetch-samples.sh`, 285 MB | Each sample fails on Apple and develops on the fallback, from disk and from memory; events, cancellation by callback and by task, memory limit; the CPU path keeps colors that sRGB primaries clip |
| Decoder agreement | the same, plus `corpus.py fetch --only DMC-LX10_-_1_1` | Size, color and crop agree between routes; pinned decoder version; Apple's decoder on bytes in memory; texture output with and without a copy |

Outside `swift test`:

- `Examples/RawInputDemo/UITests` drives the demo in the simulator.
  `Scripts/record-demo.sh` records the walkthrough for the README.
- `Examples/RawInputDemo/Scripts/photo-library-tests.sh` runs the photo library tests in the
  simulator, where the library is disposable and access can be granted without a prompt:
  the PhotoKit suite above, then a UI test that picks every photo in the system picker and
  checks that the RAW files open from their bytes and the others are refused with a reason.
  It checks that the tests ran, since a missing permission makes them skip.
- `rawprobe fuzz FILE...` decodes damaged copies of files in child processes, from disk
  and from memory, and keeps inputs that crash or hang in `fuzz-findings/`. CI runs 60
  cases under AddressSanitizer on every push, with a new seed each time.
- `cargo test --features gpu` in `Bindings/rust`, and `node Bindings/web/test.mjs`.

CI runs the Swift tests and the fuzzer, builds the demo for iOS, and builds and tests the
Rust crate and the WebAssembly module, on macOS and Linux.

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
an exposure slider. Files come from the bundle, from the Files picker, or from the photo
library, and the last are opened from memory.

- `Develop.swift` decodes with the library's async `open` and runs the other blocking
  calls on its own dispatch queue.
- `DetailModel.swift` discards results that arrive after a newer request and renders one
  frame at a time with the latest slider value.

The Xcode project is generated from `project.yml` with XcodeGen and committed. A build
phase downloads the sample files.

## Not implemented

- Lens correction, noise reduction and highlight recovery on the fallback.
- Highlight recovery. The fallback clips at sensor white.
- Precompiled shaders. The kernel is compiled from source at first use, because
  `swift build` does not run the Metal compiler.
- Tiled development. The GPU path develops a frame into one texture, so very large frames
  are halved.
- X-Trans on the GPU.
- Nikon High Efficiency and JPEG XL DNG on the fallback. Apple's decoder opens both.
