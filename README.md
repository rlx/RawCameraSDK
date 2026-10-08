# RawInputKit

One call that opens a camera RAW file on iOS and macOS. Apple's decoder handles the file
when it can; when it can't, LibRaw decodes it and a Metal kernel develops it. Either way the
caller gets a linear `CIImage` ready for an editor.

```swift
import RawInputKit

let raw = try RawInput.open(url)          // CIImage: linear light, rotated upright
raw.route                                 // .apple or .fallback
raw.decoder                               // "Apple RAW 8", "LibRaw 0.22.2 + Metal"
let thumbnail = try RawInput.preview(url) // the camera's embedded JPEG; no sensor decode
```

| Ten files Apple can't open | The fallback develops one | Apple's decoder, same file |
|---|---|---|
| ![Gallery of ten RAW files](Docs/gallery.png) | ![Sigma dp0 Quattro developed by the fallback](Docs/detail-fallback.png) | ![Apple's decoder cannot open the file](Docs/detail-apple.png) |

**Contents:** [Build and run](#build-and-run) · [Why](#why-this-for-vsco) ·
[What Apple opens and what it doesn't](#what-apple-opens-and-what-it-doesnt) ·
[Apple against the fallback](#apple-against-the-fallback-is-there-a-difference) ·
[How it works](#how-it-works) · [Limits](#limits) · [Licence](#licence)

New to the code? Start with [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md).

## Build and run

Requirements: macOS with Xcode 27 (Swift 6). iOS 17 or macOS 14 to run. No other tools.

```sh
git clone --recurse-submodules https://github.com/rlx/RawInputKit.git
cd RawInputKit
```

LibRaw is a git submodule. If you cloned without `--recurse-submodules`, run
`git submodule update --init`.

### The library

```sh
swift build
```

To use it in another project, add the package and import `RawInputKit`:

```swift
.package(url: "https://github.com/rlx/RawInputKit.git", branch: "main")
```

### The demo app

Open `Examples/RawInputDemo/RawInputDemo.xcodeproj` and run the `RawInputDemo` scheme on an
iPhone simulator or "My Mac". The first build downloads ten sample files (270 MB) and
verifies their checksums.

To run on a phone, select the `RawInputDemo` target, choose your team under
Signing & Capabilities, and run. The phone needs Developer Mode switched on
(Settings → Privacy & Security).

The app opens on ten files Apple's decoder rejects. Open one and switch the decoder between
Automatic, Apple and Fallback; the exposure slider works on the linear image. Import adds
your own files from Files or a card reader.

### The tests

```sh
Examples/RawInputDemo/Scripts/fetch-samples.sh        # the ten samples, 270 MB
Scripts/corpus.py fetch --only ILCE-9M3 DMC-LX10      # two reference files, 30 MB
swift test
```

32 tests in 6 suites. Without the downloads, the suites that need files are skipped and the
rest still run. On the iPhone simulator:

```sh
xcodebuild test -scheme RawInputKit-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### On a device

`xcrun devicectl list devices` gives the device's UDID. The team ID is the ten-character
code of the Apple developer team that signs the build; a free personal team works.

```sh
# The same 32 tests, on the device.
Scripts/device-tests.sh <device-udid> <team-id>

# Timings and peak memory. 15 app launches by default;
# the second form is the full set behind the tables below, 102 launches.
Scripts/device-bench.py <device-udid>
Scripts/device-bench.py <device-udid> --limit 0 --runs 3
```

The tests run inside the demo app, because a device cannot run a Swift package's tests
directly. The benchmark needs the Release build of the demo installed first:

```sh
xcodebuild -project Examples/RawInputDemo/RawInputDemo.xcodeproj -scheme RawInputDemo \
    -configuration Release -destination 'id=<device-udid>' -derivedDataPath .build/device \
    DEVELOPMENT_TEAM=<team-id> -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-udid> \
    .build/device/Build/Products/Release-iphoneos/RawInputDemo.app
```

### The measurements

Everything in the next two sections can be regenerated. The full archive is 19 GB.

```sh
Scripts/corpus.py fetch
swift run -c release rawprobe Tests/Corpus --json Tests/probe-results.json   # about 6 minutes
Scripts/coverage.py && Scripts/charts.py
```

`rawprobe` also looks at single files:

```sh
swift run -c release rawprobe render  FILE out.jpg [apple|fallback]   # develop one file
swift run -c release rawprobe compare FILE out.jpg                    # both decoders side by side
swift run -c release rawprobe bench   FILE...                         # time and memory per decoder
```

## Why this, for VSCO

VSCO Studio Pro imports JPEG and HEIC only. VSCO's own guide (22 September 2026) says "RAW
support is confirmed on the product roadmap" and tells RAW shooters to export JPEGs first;
the 1.3.0 release notes add tethering with "JPEG support only for now".
Sources: [Getting started with Studio Pro](https://www.vsco.co/learn/getting-started-vsco-studio-pro),
[App Store listing](https://apps.apple.com/us/app/vsco-studio-pro-photo-editor/id6759939220).

A RAW input stage is the piece between a file on a card and pixels an editor can grade. This
project is that stage, built to answer three questions with measurements:

1. How much does Apple's decoder already cover?
2. What is left over, and can a fallback fill it inside a closed-source App Store app?
3. What does the fallback cost in image quality, speed and memory?

## What Apple opens and what it doesn't

`rawprobe` ran both decoders over **944 files from 898 camera models**, all CC0 samples from
[raw.pixls.us](https://raw.pixls.us): one file for every camera in the archive, plus extra
compression modes for current bodies. Measured on macOS 27.0.1, Apple silicon. Apple
publishes a single camera list for iOS, iPadOS and macOS 27, and the ten bundled samples
were re-checked on an iPhone 16 Pro Max running iOS 27.0.1: Apple's decoder rejects all ten
there as well.

| | Files | Share |
|---|---|---|
| Apple's decoder opens it | 821 | 87% |
| Only the fallback opens it | 107 | 11% |
| Neither opens it | 16 | 2% |
| **Opened by RawInputKit** | **928** | **98%** |

Of the 821 that Apple opens, the fallback also opens 807.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Docs/coverage-by-brand-dark.svg">
  <img src="Docs/coverage-by-brand-light.svg" alt="Stacked bars per camera brand: files Apple's decoder opens, files only the fallback opens, files neither opens">
</picture>

| Brand | Files | Apple opens | | Only the fallback | Neither |
|---|---|---|---|---|---|
| Canon | 185 | 161 | 87% | 22 | 2 |
| Panasonic | 111 | 108 | 97% | 3 | 0 |
| Sony | 109 | 108 | 99% | 1 | 0 |
| Nikon | 95 | 92 | 97% | 3 | 0 |
| Fujifilm | 89 | 77 | 87% | 12 | 0 |
| Olympus / OM | 70 | 63 | 90% | 7 | 0 |
| Samsung | 42 | 25 | 60% | 17 | 0 |
| Pentax | 36 | 35 | 97% | 1 | 0 |
| Leica | 23 | 23 | 100% | 0 | 0 |
| Huawei | 17 | 17 | 100% | 0 | 0 |
| Phase One | 14 | 5 | 36% | 9 | 0 |
| Sigma | 13 | 2 | 15% | 11 | 0 |
| 51 other brands | 140 | 105 | 75% | 21 | 14 |

The complete lists, file by file, are in [Docs/coverage.md](Docs/coverage.md).

**Apple covers current cameras better than its reputation.** Forum posts and older articles
report gaps in Fujifilm compressed RAF, Nikon High Efficiency, Sony a7 V compressed and OM
System High Res Shot. On OS 27, Apple opened every one of those in the test set. For
mainstream bodies, RAW support is a few lines of `CIRAWFilter`.

**What Apple does not open** falls into three groups:

- *Whole formats it never supported:* Sigma X3F (Foveon sensors), Samsung SRW (most of the NX
  line), Kodak DCR and KDC, Canon compacts that write CRW.
- *Particular modes of brands it does support:* Phase One Sensor+ IIQ, and a compressed file
  from the Fujifilm X-E3.
- *Individual bodies:* Pentax K-3 Mark III Monochrome (2023), Olympus E-M10 Mark IIIs,
  DJI Osmo Action, and older Fujifilm EXR and SuperCCD cameras.

**What the fallback does not open** that Apple does (14 files): Nikon High Efficiency, which
uses a patented codec; JPEG XL and lossy-JPEG DNG; one Sony a7 V mode; two phone and
hobby-camera files; and five files where LibRaw reported corrupt data and RawInputKit refused
to return a partly garbled image.
Neither decoder is a superset of the other, which is why the order is Apple first.

**Neither opens** 16 files: GoPro GPR, and raw dumps from action cameras and a cinema camera.

## Apple against the fallback: is there a difference?

Yes, in look, in speed and in how far each can be trusted. Compared on files both open.

### They look different

Left: Apple's decoder. Right: the fallback. Top: the whole frame. Bottom: a 1:1 crop.

![Canon EOS R3: Apple's decoder and the fallback side by side](Docs/compare-canon-eos-r3.jpg)

*Canon EOS R3, Bayer sensor, fallback on the GPU path.*

![Fujifilm X-T5: Apple's decoder and the fallback side by side](Docs/compare-fujifilm-x-t5.jpg)

*Fujifilm X-T5, X-Trans sensor, fallback on the CPU path.*

Geometry and fine detail match. The look does not: Apple applies a tone curve, sharpening,
noise reduction and lens corrections (note the vignetting at the left edge of the Fujifilm
frame, corrected on Apple's side only). The fallback's image is scene-linear with nothing
added, so it is flatter and a little softer. That is by design, since an editor applies its
own look, but it means the two routes cannot be mixed in one gallery without a shared
rendering step on top.

### Their colours are close, Apple's closer

Every RAW file carries a preview the camera rendered, which makes it a reference for whether
a decode got the colours right. For the 807 files both decoders open, this is how far each
lands from that preview, ignoring brightness:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Docs/preview-agreement-dark.svg">
  <img src="Docs/preview-agreement-light.svg" alt="Distribution of colour distance from the embedded preview: Apple's decoder median 0.025, fallback median 0.044">
</picture>

Thick bar: the middle half of files. Thin bar: the middle 90%. Dot: the median, 0.025 for
Apple and 0.044 for the fallback. Both sit well under 0.15, where a result starts to look
wrong.

The same comparison flags results worth a second look, above 0.15: 8 of Apple's 821 and 22 of
the fallback's 885. Seven files are flagged for both decoders, which points at an unusual
preview more than at a bad decode. The clear fallback failures are cameras newer than
LibRaw's tables: it reads the Canon EOS R6 Mark III with the wrong black level and the
picture comes out with a pink haze. LibRaw "supporting 1,274 cameras" is an upper bound, not
a guarantee. Apple opens 20 of the fallback's 22 flagged files, so automatic routing never
sends those to the fallback.

### The GPU path is fast; the CPU path is not

Time from file to a fully rendered, full-resolution image: open the file, then render every
pixel to 8-bit sRGB, as an export would. Median of three runs, each in a fresh process.

**On an iPhone 16 Pro Max, iOS 27.0.1:**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Docs/speed-device-dark.svg">
  <img src="Docs/speed-device-light.svg" alt="Seconds to a rendered image per file on an iPhone 16 Pro Max, Apple's decoder against the fallback">
</picture>

| File | Fallback path | Apple | Fallback | Apple peak memory | Fallback peak memory |
|---|---|---|---|---|---|
| Sony a9 III, 10 MP crop mode | GPU | 0.49 s | 0.14 s | 487 MB | 239 MB |
| Canon EOS R3, 24 MP | GPU | 1.19 s | 0.36 s | 925 MB | 509 MB |
| Nikon Z f, 24 MP | GPU | 0.67 s | 0.45 s | 546 MB | 509 MB |
| Panasonic S1R II, 44 MP | GPU | 6.87 s | 0.63 s | 683 MB | 884 MB |
| Sony a1, 50 MP | GPU | 1.17 s | 0.47 s | 707 MB | 902 MB |
| Fujifilm X-T5, 40 MP | CPU (X-Trans) | 1.47 s | 9.14 s | 726 MB | 1,128 MB |
| Fujifilm GFX100 II, 102 MP | GPU, half size | 3.15 s | 3.05 s | 1,310 MB | 827 MB |

**On an Apple silicon Mac, macOS 27.0.1:**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Docs/speed-dark.svg">
  <img src="Docs/speed-light.svg" alt="Seconds to a rendered image per file on a Mac, Apple's decoder against the fallback">
</picture>

| File | Fallback path | Apple | Fallback | Apple peak memory | Fallback peak memory |
|---|---|---|---|---|---|
| Sony a9 III, 10 MP crop mode | GPU | 0.48 s | 0.11 s | 1,285 MB | 190 MB |
| Canon EOS R3, 24 MP | GPU | 0.91 s | 0.34 s | 2,161 MB | 443 MB |
| Nikon Z f, 24 MP | GPU | 0.52 s | 0.40 s | 1,713 MB | 441 MB |
| Panasonic S1R II, 44 MP | GPU | 1.83 s | 0.66 s | 3,681 MB | 773 MB |
| Sony a1, 50 MP | GPU | 0.99 s | 0.36 s | 3,688 MB | 865 MB |
| Fujifilm X-T5, 40 MP | CPU (X-Trans) | 0.95 s | 11.22 s | 2,521 MB | 1,097 MB |
| Fujifilm GFX100 II, 102 MP | GPU | 2.20 s | 3.59 s | 5,756 MB | 1,761 MB |

What the numbers say:

- **On Bayer files the fallback's GPU path is quicker than Apple's decoder** on both
  machines, typically two to three times, though Apple does more per pixel (noise
  reduction, lens correction, tone mapping).
- **On X-Trans the fallback is six to twelve times slower.** It runs LibRaw's
  single-threaded CPU pipeline. Apple opens almost every X-Trans file, so this path is rare.
- **The phone keeps up with the Mac on the fallback.** The work is one GPU pass and
  single-threaded decompression, and an iPhone's cores are as fast as a Mac's at that.
- **Nothing was terminated for memory on the phone,** including the 102 MP frame. There the
  fallback develops at half size (51 → 25 MP output), which is what keeps it at 827 MB.
  Apple's decoder renders the full 102 MP in 1.3 GB.
- **Apple's decoder uses far more memory on the Mac** than on the phone for the same file:
  it scales its working set to the machine.
- **One outlier is unexplained:** Apple's decoder takes 6.9 s on the Panasonic S1R II file on
  the phone, in all three runs, against 1.8 s on the Mac. I have not found out why.

Peak memory includes the benchmark's own output buffer, 4 bytes per pixel.

The ten bundled samples on the same iPhone, fallback only since Apple's decoder rejects them
there too:

| Sample | Path | Embedded preview | File to rendered image | Peak memory |
|---|---|---|---|---|
| Samsung NX1, 28 MP | GPU | 56 ms | 0.51 s | 551 MB |
| Samsung NX300, 20 MP | GPU | 44 ms | 0.37 s | 436 MB |
| Fujifilm X-E3, 24 MP | CPU | 26 ms | 5.15 s | 697 MB |
| Olympus E-M10 Mark IIIs, 12 MP | GPU | 30 ms | 0.39 s | 281 MB |
| Panasonic DC-FZ45, 18 MP | GPU | 34 ms | 0.23 s | 384 MB |
| Sigma dp0 Quattro, 20 MP | CPU | 57 ms | 1.03 s | 784 MB |
| Pentax K-3 Mark III Monochrome, 26 MP | CPU | 52 ms | 0.60 s | 641 MB |
| Phase One IQ180, 20 MP | CPU | 44 ms | 1.47 s | 617 MB |
| Canon PowerShot S100V, 12 MP | GPU | 29 ms | 0.30 s | 271 MB |
| DJI Osmo Action, 12 MP | GPU | 28 ms | 0.14 s | 266 MB |

The embedded preview takes 24 to 74 ms across every file measured on the phone, which is
what makes a gallery usable before anything is developed.

### Summary

| | Apple's decoder | The fallback |
|---|---|---|
| Files opened, of 944 | 821 | 914 |
| Look | Finished: tone curve, sharpening, lens corrections | Neutral and flat; the editor's job |
| Colour distance from the camera's preview, median | 0.025 | 0.044 |
| Results flagged against the camera's preview | 8 of 821 | 22 of 885 |
| Speed on Bayer files up to 50 MP, iPhone 16 Pro Max | 0.5 to 6.9 s | 0.1 to 0.6 s |
| Speed on X-Trans, 40 MP, iPhone 16 Pro Max | 1.5 s | 9.1 s |
| New cameras | Arrive with OS updates | Arrive with LibRaw releases, and can decode wrongly before then |
| Cost to ship | None | LibRaw under CDDL, about 1 MB of code, a look to build |

## How it works

```
RawInput.open(url)
   │
   ├─ Can Apple develop it?  Decode a 256 px version and see whether pixels come out.
   │
   ├─ yes ─ CIRAWFilter ──────────────────────────────────┐
   │                                                      ├─▶ RawImage: linear CIImage, info, route
   └─ no ── RawShim (C boundary) ─ LibRaw decompresses    │
              ├─ plain Bayer ───── Metal compute kernel ──┤
              └─ everything else ─ LibRaw CPU pipeline ───┘
```

- **Routing is by probe, not by camera name.** Support depends on the compression mode, which
  Apple's camera list does not record, and `CIRAWFilter` is lazy: for an unsupported file it
  can return an image that renders as nothing. The router asks Apple's engine for a small
  region of real pixels. That costs a good part of a decode, so the answer is remembered per
  camera and recording mode and the next file of the same kind skips the test.
- **Bayer files are developed on the GPU.** One Metal kernel does black level, white balance,
  edge-directed (Hamilton-Adams) demosaicing and the camera-to-sRGB matrix, into 16-bit
  float. The better-known demosaic algorithms are GPL and are not used.
- **Everything else uses LibRaw's own pipeline:** X-Trans, Foveon, monochrome sensors, and
  Phase One backs, which need per-sensor corrections only LibRaw applies.
- **In-camera crops are honoured,** so a file shot at 1:1 comes out square on both routes.
- **Malformed files are refused, not developed.** Sizes and levels are validated before they
  reach the GPU, and truncated data is an error instead of a half-garbled image.
- **A C seam.** Swift reaches LibRaw only through `Sources/RawShim/include/RawShim.h`. No C++
  type crosses it, so the same core could sit under a Rust or C++ engine.

[Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) has the code map, the conventions, and how-to
notes for debugging a decode, updating LibRaw and regenerating the numbers.

## The ten bundled samples

Each fails in Apple's decoder and develops on the fallback; a test asserts both, on the Mac,
the simulator and the phone.

| Sample | Format | Fallback path |
|---|---|---|
| Samsung NX1 | SRW, 28 MP | GPU |
| Samsung NX300 | SRW, 20 MP | GPU |
| Fujifilm X-E3 | RAF compressed, X-Trans, 24 MP | CPU |
| Olympus E-M10 Mark IIIs | ORF, 16:9 in-camera crop, 12 MP | GPU |
| Panasonic DC-FZ45 | RW2, 18 MP | GPU |
| Sigma dp0 Quattro | X3F, Foveon, 20 MP | CPU |
| Pentax K-3 Mark III Monochrome | PEF, monochrome sensor, 26 MP | CPU |
| Phase One IQ180 | IIQ Sensor+, 20 MP | CPU |
| Canon PowerShot S100V | CR2, 12 MP | GPU |
| DJI Osmo Action | DNG, 12 MP | GPU |

These are what the measurements turned up, not the cameras people buy today: the current
best-sellers all open in Apple's decoder.

## Limits

- **No look on the fallback.** No tone curve, lens correction, noise reduction or highlight
  recovery. Matching Apple's rendering is the largest piece of work between this and a product.
- **X-Trans and Foveon are slow,** seconds per frame on one CPU core.
- **The library does not check the fallback's colour at run time.** `rawprobe` does, against
  the embedded preview; moving that check into the router is the next step.
- **Large frames are halved.** Above 64 MP the fallback develops Bayer files at half size to
  stay within an iPhone's memory. Other sensor types are not reduced.
- **Measured on one phone,** an iPhone 16 Pro Max with 8 GB of memory. Older phones with
  less memory are where the 64 MP half-size threshold will matter, and they are untested.
- **RAW 9,** Apple's newer decoder, is offered on the test machine for DNG only. The
  `appleDecoderVersion = .newest` option selects it; nothing else here exercises it.
- LibRaw's sources compile with deprecation warnings that SwiftPM offers no safe way to
  silence. RawInputKit's own code compiles without warnings.

## Licence

RawInputKit is under the [MIT licence](LICENSE).

It links LibRaw 0.22.2, used under LibRaw's CDDL-1.0 option, which permits static linking
into a closed-source App Store app without the relinking obligation of the LGPL. LibRaw is
included unmodified as a submodule. Details in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Get a lawyer's confirmation before
shipping a product on this.

The sample images are CC0, from raw.pixls.us, and are downloaded, not redistributed here.
