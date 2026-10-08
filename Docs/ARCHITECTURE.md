# Architecture

A guide for someone opening this repository for the first time. It explains how the code is
organised, the decisions that are not obvious from reading it, and how to do the jobs you
are most likely to be asked to do. The README covers what the project is for and what was
measured.

## The idea in one paragraph

Apple ships a RAW decoder (`CIRAWFilter`) that handles most cameras and is the best result
when it works. It does not open everything. RawInputKit puts a second decoder behind it,
built on LibRaw, and gives callers one function that tries Apple first and falls back when
it has to. The engineering is in three places: knowing reliably when Apple's decoder will
*not* work, developing LibRaw's sensor data into an image without shipping GPL code, and
proving with measurements which files each decoder really handles.

## Map of the repository

```
Package.swift                  four targets, described below
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
camera and mode), `LibRawFile` (lifetime-safe wrapper over the shim), `ExposureEstimate`
and `RawPreview`.

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
```

### Why routing decodes instead of looking the camera up

Whether Apple supports a file depends on the camera *and* the compression mode, changes
with each OS update, and is not something Apple's API reports. Worse, `CIRAWFilter` is lazy:
for a camera it knows in a mode it does not, it can return an image that only turns out to
be empty when rendered. So `AppleRawDecoder.canDecode` asks for real pixels: a 64-pixel
square from the middle of the frame.

That is not cheap. Apple's engine still decompresses the sensor data up to that region,
0.1 to 0.25 s on a Mac, and scaling the picture down instead saves nothing because the
engine demosaics everything before it shrinks. Paying that on every open would nearly
double the cost of the files Apple supports. `AppleSupport` therefore keys the answer on
camera model, LibRaw's decoding routine and frame size, tests the first file of each kind,
and reuses the answer for the rest of the process's life. Its header comment states what
that gives up.

### Why there are two fallback paths

LibRaw can do the whole job on the CPU, and for unusual sensors it should: its pipeline
knows per-camera corrections that took its authors two decades to collect. But it is
single-threaded and slow, and its better demosaic algorithms are GPL, which this project
cannot ship. Plain Bayer sensors are the bulk of real files and need nothing camera-specific
beyond numbers LibRaw hands over (black level, white level, white balance, a 3x3 matrix), so
for those LibRaw only decompresses and a Metal kernel does the rest.

The shim decides which path a file takes, in `capture_bayer_state`. A file is `metal_ready`
only if every assumption the kernel makes holds. When in doubt it is not, and the CPU path
runs. If the GPU itself fails, the CPU path runs then too.

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
dropped before they reach integer conversion; truncated data is reported as
`RawError.corruptData` instead of being developed into noise.

## Tests

`swift test` runs everything. Suites that need files skip themselves with a message saying
how to fetch them. `Scripts/device-tests.sh` runs the same sources on a physical device,
hosted in the demo app (the `RawInputDemoTests` target), since a device cannot run a
package's tests directly; `Fixtures.swift` explains where the files come from there.

| Suite | Needs | What it pins |
|---|---|---|
| Metal kernel | a GPU | Demosaic, pattern indexing, origin, flips and clipping, on hand-built mosaics with known answers |
| Exposure estimate, Metadata | nothing | Small pure functions, including the non-finite input that would otherwise crash |
| Robustness | nothing (truncation uses the samples) | Missing, empty, random and truncated files fail cleanly |
| Bundled samples | `fetch-samples.sh`, 270 MB | Each sample fails on Apple and develops on the fallback |
| Decoder agreement | `corpus.py fetch --only ILCE-9M3 DMC-LX10`, 30 MB | The two routes agree on size, colour and in-camera crop |

The kernel tests exist because real photographs cannot catch the bugs that matter there: an
image developed with the Bayer pattern off by one pixel, or upside down, still looks like a
photograph.

`appleRejectsIt` will start failing when an OS update teaches Apple's decoder one of the
sample formats. That is expected: swap the sample for another file from
`Docs/coverage.md`'s fallback-only list and update the README.

## How to

### Look at one file

```sh
swift run -c release rawprobe render FILE out.jpg            # as the app would route it
swift run -c release rawprobe render FILE out.jpg fallback   # force a route
swift run -c release rawprobe compare FILE out.jpg           # both routes side by side
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
5. Run the folder probe on the file and read its preview distance: above 0.15 means the
   result disagrees with the camera's own rendering.

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
  time in a loop that always renders the latest slider value. Its header comment states the
  two rules.

The Xcode project is generated from `project.yml` with XcodeGen and committed, so the tool
is only needed to change project settings. A build phase downloads the sample files.

## What is deliberately not here

- **A look.** No tone curve, lens correction, noise reduction or highlight recovery on the
  fallback. Its output is correct and flat.
- **Tiled development.** The GPU path develops a whole frame into one texture, which is why
  very large frames are halved. `CIImageProcessorKernel` is the route to lifting that.
- **A GPU X-Trans path.** Fujifilm's mosaic goes through LibRaw on the CPU, at seconds per
  frame. Apple opens almost all X-Trans files, so it rarely runs.
- **Runtime checking of the fallback's colour.** `rawprobe` compares results with the
  embedded preview; the library does not, so it can return a wrong-looking image for a
  camera LibRaw misreads. Moving `PreviewDistance` into the router is the next step.
- **Nikon High Efficiency and JPEG XL DNG.** Both need codecs LibRaw does not include.
  Apple's decoder opens them, so automatic routing handles them.
