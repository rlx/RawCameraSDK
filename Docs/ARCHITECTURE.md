# Architecture

A guide for someone opening this repository for the first time. It explains how the code is
organised, the decisions that are not obvious from reading it, and how to do the jobs you
are most likely to be asked to do. The README covers what the project is for and what was
measured; [RECOMMENDATION.md](RECOMMENDATION.md) says what I would do with the findings.

## The idea in one paragraph

Apple ships a RAW decoder (`CIRAWFilter`) that handles most cameras and is the best result
when it works. It does not open everything. RawInputKit puts a second decoder behind it,
built on LibRaw, and gives callers one function that tries Apple first and falls back when
it has to. The engineering is in three places: knowing reliably when Apple's decoder will
*not* work, developing LibRaw's sensor data into an image quickly, and proving with
measurements which files each decoder really handles.

## Map of the repository

```
Package.swift                  five targets, described below
Vendor/LibRaw/                 LibRaw 0.22.2, unmodified, a git submodule
Sources/
  RawShim/                     C boundary over LibRaw            (C++, about 300 lines)
  RawInputKit/                 the library                       (Swift)
  rawprobe/                    measuring tools                   (Swift, macOS command line)
Tests/RawInputKitTests/        Swift Testing suites
Tests/corpus-pool.json         the 944 archive files the probe runs over
Tests/probe-results.json       what the probe found; input to the docs and charts
Tests/bench-results.json       speed and memory measurements
Examples/RawInputDemo/         SwiftUI app for iOS and macOS
Scripts/                       corpus download, coverage report, charts
Docs/                          this file, coverage.md, charts and screenshots
```

### Targets and what depends on what

```
rawprobe ─┐
          ├─▶ RawInputKit ─▶ RawShim ─▶ CLibRaw (Vendor/LibRaw)
demo app ─┘        │
                   └─▶ Core Image, Metal, ImageIO
```

- **CLibRaw** compiles LibRaw's sources as they are. Three placeholder files are excluded
  and two features switched on (zlib for compressed DNG, X3F for Sigma Foveon); see
  `Package.swift`.
- **RawShim** is the only code that includes LibRaw headers.
- **RawInputKit** is the only code that imports RawShim. Nothing from LibRaw or the shim
  appears in its public API.

## Reading order

If you read these six files in this order, you have read the product:

| File | What it holds |
|---|---|
| `RawInputKit/RawInput.swift` | The public entry points and the routing decision |
| `RawInputKit/AppleRawDecoder.swift` | The Apple route, and the probe that decides routing |
| `RawShim/include/RawShim.h` | The contract with LibRaw: lifecycle, ownership, field meanings |
| `RawShim/RawShim.cpp` | How that contract is met, and LibRaw's traps |
| `RawInputKit/FallbackRawDecoder.swift` | The two fallback paths and how a file is assigned to one |
| `RawInputKit/MetalDevelop.swift` | The GPU kernel: levels, demosaic, colour |

The rest of the library is supporting types: `RawImage`, `RawInfo`, `RawDecodeOptions`,
`RawError` (the public vocabulary), `AppleSupport` (remembers the routing decision per
camera and mode), `LibRawFile` (lifetime-safe wrapper over the shim), `RawPreview`, and
three pieces that sit *after* the decoders: `ExposureEstimate` (default brightness),
`PreviewAgreement` (is the fallback's colour believable?) and `RawLook` (the shared
rendering step).

## What happens when a file is opened

```
RawInput.open(url)
   │
   ├─ AppleSupport.canDecode ───── known for this camera and mode? else render a small
   │                               region with Apple's engine: did pixels come out?
   │
   ├─ yes ─ AppleRawDecoder.decode ───────────────────────────────┐
   │          a configured CIRAWFilter; lazy                      │
   │                                                              ├─▶ RawImage
   └─ no ── FallbackRawDecoder.decode                             │
              LibRawFile(url).unpack()   decompress sensor data   │
              ├─ rik_info.metal_ready ─▶ MetalDevelop.develop ────┤   GPU path
              └─ otherwise ───────────▶ LibRaw dcraw_process ─────┘   CPU path

RawImage ─▶ rendered(look:) ─▶ a picture     exposure, then one lookup table; identical
                                             for both routes
```

### Why routing decodes instead of looking the camera up

Whether Apple supports a file depends on the camera *and* the compression mode, changes
with each OS update, and is not something Apple's API reports. Worse, `CIRAWFilter` is lazy:
for a camera it knows in a mode it does not, it can return an image that only turns out to
be empty when rendered. So `AppleRawDecoder.canDecode` asks for real pixels: a 64-pixel
square from the middle of the frame.

That is not cheap. Apple's engine still decompresses the sensor data up to that region, and
scaling the picture down instead saves nothing because the engine demosaics everything
before it shrinks. Measured on a Mac in a fresh process, opening through the check takes
0.1 to 0.7 s longer than calling Apple's decoder directly. Paying that on every open would
add a large fraction to the cost of the files Apple supports. `AppleSupport` therefore keys the answer on
camera model, LibRaw's decoding routine and frame size, tests the first file of each kind,
and reuses the answer for the rest of the process's life. Its header comment states what
that gives up.

### Why there are two fallback paths

LibRaw can do the whole job on the CPU, and for unusual sensors it should: its pipeline
knows per-camera corrections that took its authors two decades to collect. But it is
single-threaded, and seconds per frame where a GPU needs tenths. (The best-known demosaic
algorithms, AMaZE and RCD, are GPL and are in neither LibRaw's shipped tree nor this
project.) Plain Bayer sensors are the bulk of real files and need nothing camera-specific
beyond numbers LibRaw hands over (black level, white level, white balance, a 3x3 matrix), so
for those LibRaw only decompresses and a Metal kernel does the rest.

The shim decides which path a file takes, in `capture_bayer_state`. A file is `metal_ready`
only if every assumption the kernel makes holds. When in doubt it is not, and the CPU path
runs. If the GPU itself fails, the CPU path runs then too.

### Why rendering is a separate step after both decoders

A decoder should stop at scene-linear data, and nobody should be shown scene-linear data.
If each route turned it into a picture its own way (Apple with Apple's tone curve, the
fallback with something else), a gallery would contain two visibly different kinds of
photograph, sorted by which decoder happened to open each file.

So everything that shapes the picture happens in one place, `RawLook`, after the decoders:

1. **Exposure**, measured from the pixels by `ExposureEstimate.measure`, the same function
   for both routes. Each decoder has its own idea of where sensor white sits, so neither's
   calibration constants are comparable with the other's; the picture is.
2. **The look**: a contrast curve, saturation, tints and fade, baked into a 33-point 3D
   lookup table and applied with `CIColorCubeWithColorSpace`.

To get matching pictures from both routes, Apple's decoder has to be asked for scene-linear
output (`appleRendering = .linear`); `RawImage.isSceneLinear` says whether an image is.
`rawprobe match` measures the result: across 202 files the median colour difference
between the routes falls from ΔE 10.7 on their own outputs to 3.2 after a shared look.
What remains is real (different colour matrices, Apple's lens corrections and noise
reduction) and is the next thing to work on if the routes must be indistinguishable.

### How the fallback knows when it is wrong

LibRaw decodes some cameras incorrectly instead of refusing them, typically ones newer
than its tables: the file opens, pixels come out, and the picture has a colour cast. The
fallback therefore compares its result with the preview the camera embedded in the same
file (`PreviewAgreement`), on a 24x16 grid, by chromaticity only. The distance goes into
`RawImage.previewDistance`; above 0.15, `isColorSuspect` is true.

It reports instead of refusing, because the right response belongs to the caller: a viewer
should badge the picture, an importer might reject it, and a tinted picture can still be
better than none. The demo badges it.

## Conventions worth knowing before you change anything

**The output contract.** Both routes return an upright, linear-light `CIImage`. The fallback
is scene-linear with sRGB primaries, highlights clipped at 1, no tone curve. Apple's carries
Apple's look. They are interchangeable as *inputs to an editor*, not visually identical; the
doc comment on `RawImage.image` spells out the differences, including what backs each image.

**Coordinates.** LibRaw's sensor plane includes masked borders. The *picture* is a rectangle
inside it. Everything indexed "per mosaic position" (colour pattern, black levels) is
relative to the picture's top-left pixel: `(row & 1) * 2 + (column & 1)`. The kernel adds
the origin only when it reads the texture.

**Orientation.** Neither fallback path rotates. `FallbackRawDecoder` applies the camera's
orientation once, at the end, with `CIImage.oriented`. `RawInfo.width/height` describe the
unrotated frame.

**Vertical flips.** A Metal texture's first row is the top; Core Image's origin is the
bottom. `MetalDevelop` flips its result. Bitmap data handed to Core Image is already read
top-first and is not flipped. `KernelTests.topOfPictureIsTopOfImage` pins this.

**Buffer lifetime.** Pointers from the shim are valid until the handle closes, and Swift may
destroy an object after its last use, before the end of scope. `LibRawFile` therefore only
exposes buffers inside closures (`withMosaic`, `withDeveloped`, `withThumbnail`). Do not add
an accessor that returns a pointer.

**The shader's parameter struct.** `MetalDevelop.Parameters` in Swift and `Params` in the
shader source are the same bytes. Change them together; `parameterLayoutMatchesShader`
fails if the Swift side moves.

**LibRaw's mutable state.** A `LibRaw` object rewrites its own fields as calls are made
(`dcraw_process` changes width, height and flip). The shim captures what it needs at unpack
time. The comment at the top of `RawShim.cpp` lists which call makes which field valid.

**Core Image is lazy, twice over.** A `CIImage` does nothing until rendered, and
`CIContext.createCGImage` by default returns before rendering too, doing the work when the
image's pixels are first read. Anything that needs to *know* a render happened, such as a
measurement or a check for an empty result, renders into a bitmap it owns
(`rawprobe/FullRender.swift`) or passes `deferred: false`. An early version of the
benchmark got this wrong and reported Apple's decoder as several times faster than it is.

**Hostile input.** RAW files come from cards, downloads and other people. Every size, margin
and level that reaches the kernel is validated in the shim first; non-finite values are
dropped before they reach integer conversion; data LibRaw reports as corrupt becomes
`RawError.corruptData` instead of being developed into noise. LibRaw does not report a
short read of an uncompressed format, so those truncated files still decode, with the
missing rows empty. Catching that needs a datastream that notices short reads.

## Tests

`swift test` runs everything. Suites that need files that are not there skip themselves
with a message saying how to fetch them. `Scripts/device-tests.sh` runs the same sources on a physical device,
hosted in the demo app (the `RawInputDemoTests` target), since a device cannot run a
package's tests directly; `Fixtures.swift` explains where the files come from there.

| Suite | Needs | What it pins |
|---|---|---|
| Metal kernel | a GPU | Demosaic, pattern indexing, origin, flips and clipping, on hand-built mosaics with known answers |
| Exposure estimate, Metadata | nothing | Small pure functions, including the non-finite input that would otherwise crash |
| Looks | nothing | The look's maths (monotonic, neutral greys stay neutral), its lookup-table layout, and that Core Image applies what the maths says |
| Preview agreement | nothing | A colour cast or a flipped picture is flagged; a brightness change alone is not |
| Robustness | nothing (truncation uses the samples) | Missing, empty and random files are refused with an error; truncated files do not crash (whether they are refused depends on the format, see the README's limits) |
| Bundled samples | `fetch-samples.sh`, 285 MB | Each of the ten fails on Apple, develops on the fallback, and passes the fallback's own colour check |
| Decoder agreement | the same, plus `corpus.py fetch --only DMC-LX10_-_1_1`, 22 MB | The two routes agree on size, colour and in-camera crop, and come closer together after a shared look |

The kernel tests exist because real photographs cannot catch the bugs that matter there: an
image developed with the Bayer pattern off by one pixel, or upside down, still looks like a
photograph.

Two more kinds of test live outside `swift test`:

- **The UI walkthrough** (`Examples/RawInputDemo/UITests`) drives the demo through its
  whole story in the simulator. `Scripts/record-demo.sh` records it; that is where the
  README's GIF comes from.
- **Fuzzing.** `rawprobe fuzz FILE...` decodes seeded, damaged copies of real files, each
  in a child process, and keeps any input that crashes or hangs in `fuzz-findings/`. It is
  cheap mutation fuzzing aimed at our own handling of sizes, margins and levels, not a
  replacement for coverage-guided fuzzing of LibRaw.

CI (`.github/workflows/ci.yml`) builds the package, runs `swift test` with the sample
files (but not the crop-test file, so that one test skips), and builds the demo for iOS, on
GitHub's Xcode 27 image, for pushes to `main` and pull requests.

`appleRejectsIt` will start failing when an OS update teaches Apple's decoder one of the
sample formats. That is expected: swap the sample for another file from
`Docs/coverage.md`'s fallback-only list and update the README.

## How to

### Look at one file

```sh
swift run -c release rawprobe render FILE out.jpg            # as the app would route it
swift run -c release rawprobe render FILE out.jpg fallback   # force a route
swift run -c release rawprobe compare FILE out.jpg           # both routes side by side
swift run -c release rawprobe looks FILE out.jpg             # both routes through the shared looks
```

### Debug a decode that looks wrong

1. `rawprobe render FILE out.jpg fallback` prints the path taken ("+ Metal" or "CPU"), the
   size and the suggested exposure.
2. Wrong colours on the **Metal** path: almost always black level, white level or white
   balance. Print the `rik_info` from `FallbackRawDecoder.decode`. A pink or green haze over
   the whole frame is a wrong black level, usually because the camera is newer than LibRaw's
   tables. Magenta highlights are a white level set too high.
3. Wrong colours on the **CPU** path are LibRaw's. Compare with LibRaw's own
   `dcraw_emu` to confirm, then decide whether the file should be refused.
4. Wrong framing: check `apply_camera_crop` in the shim and the file's `raw_inset_crops`.
5. Read `RawImage.previewDistance` (the demo shows a warning, the probe prints it): above
   0.15 means the result disagrees with the camera's own rendering.

### Move a camera from the Metal path to the CPU path

Add its condition to `needs_libraw` in `capture_bayer_state`, with a comment saying what
correction it needs. That is how Phase One files are handled.

### Update LibRaw

```sh
cd Vendor/LibRaw && git fetch --tags && git checkout <tag>
```

Then check `Package.swift`'s exclusions against LibRaw's `Makefile.devel` (placeholder files
are named `*_ph.cpp`), run `swift test`, rerun the probe and compare `Docs/coverage.md`
before and after. LibRaw must stay unmodified: the licence position in
`THIRD-PARTY-NOTICES.md` depends on it.

### Regenerate the numbers, tables and charts

```sh
Scripts/corpus.py fetch                                                    # 19 GB, once
swift run -c release rawprobe Tests/Corpus --json Tests/probe-results.json # about 6 minutes
swift run -c release rawprobe bench FILES... --json Tests/bench-results.json
swift run -c release rawprobe match FILES... --json Tests/match-results.json
Scripts/coverage.py     # Docs/coverage.md
Scripts/charts.py       # Docs/*.svg
```

Apple's column depends on the OS the probe runs on. Rerun it after a major OS release.

For device numbers, install the Release build of the demo and run
`Scripts/device-bench.py <udid>` (15 app launches by default; `--limit 0 --runs 3` for
the full set). It writes `Tests/device-results.json`, which
`Scripts/charts.py` also reads. The demo has a headless mode for this
(`App/Benchmark.swift`): one file, one route, one line of JSON, exit.

## The demo app

`Examples/RawInputDemo` is deliberately small: a gallery of embedded previews and a detail
view with a decoder picker and an exposure slider. Two files carry its logic.

- `Develop.swift` moves RawInputKit's blocking calls onto a dispatch queue of their own, so
  multi-second decodes do not occupy Swift's cooperative thread pool.
- `DetailModel.swift` keeps the screen truthful when results arrive out of order. Decodes
  are tagged with a generation and dropped if a newer one has started; renders run one at a
  time in a loop that always renders the latest slider value and look. Its header comment
  states the two rules.

The detail view has two pickers. The first chooses the decoder. The second chooses what
happens after it: "Decoder" shows the decoder's own output, "Neutral" and "Film" apply a
shared `RawLook`. One bundled file opens in both decoders, so the effect can be seen by
flipping the first picker under each setting of the second.

The Xcode project is generated from `project.yml` with XcodeGen and committed, so the tool
is only needed to change project settings. A build phase downloads the sample files.

## What is deliberately not here

- **A finished look.** `RawLook` is a tone curve and a simple style, enough to make the two
  routes interchangeable. There is no lens correction, noise reduction or highlight recovery
  on the fallback, and those are most of what still separates it from Apple's route.
- **Tiled development.** The GPU path develops a whole frame into one texture, which is why
  very large frames are halved. `CIImageProcessorKernel` is the route to lifting that.
- **A GPU X-Trans path.** Fujifilm's mosaic goes through LibRaw on the CPU, at seconds per
  frame. Apple opens almost all X-Trans files, so it rarely runs.
- **Nikon High Efficiency and JPEG XL DNG.** Both need codecs LibRaw does not include.
  Apple's decoder opens them, so automatic routing handles them.
