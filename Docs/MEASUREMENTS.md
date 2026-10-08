# Measurements

Everything here can be regenerated; [BUILDING.md](BUILDING.md) has the commands. The Mac is
Apple silicon on macOS 27.0.1, the phone an iPhone 16 Pro Max on iOS 27.0.1.

## What each decoder opens

`rawprobe` ran both decoders over 944 files from 898 camera models, all CC0 samples from
[raw.pixls.us](https://raw.pixls.us): one file for every camera in the archive, plus extra
compression modes for current bodies. Every file counts once, so a 2003 compact weighs the
same as this year's flagship. This is coverage of formats, not of what photographers shoot.

| | Files | Share |
|---|---|---|
| Apple's decoder opens it | 821 | 87% |
| Only the fallback opens it | 107 | 11% |
| Neither opens it | 16 | 2% |
| Opened by one or the other | 928 | 98% |

Of the 821 that Apple opens, the fallback also opens 807.

Restricting the set to pictures taken in 2019 or later (367 files with a readable
capture date), Apple opens 340, or 93%. That is by capture date, not by when the camera
was released, and most of the misses in that group are older cameras still in use.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="coverage-by-brand-dark.svg">
  <img src="coverage-by-brand-light.svg" alt="Stacked bars per camera brand: files Apple's decoder opens, files only the fallback opens, files neither opens">
</picture>

| Brand | Files | Apple opens | | Only the fallback | Neither |
|---|---|---|---|---|---|
| Canon | 185 | 161 | 87% | 22 | 2 |
| Panasonic | 111 | 108 | 97% | 3 | 0 |
| Sony | 109 | 108 | 99% | 1 | 0 |
| Nikon | 95 | 92 | 97% | 3 | 0 |
| Fujifilm | 89 | 77 | 87% | 12 | 0 |
| Olympus / OM | 72 | 65 | 90% | 7 | 0 |
| Samsung | 42 | 25 | 60% | 17 | 0 |
| Pentax | 36 | 35 | 97% | 1 | 0 |
| Leica | 23 | 23 | 100% | 0 | 0 |
| Huawei | 17 | 17 | 100% | 0 | 0 |
| Phase One | 14 | 5 | 36% | 9 | 0 |
| Sigma | 13 | 2 | 15% | 11 | 0 |
| 42 other brands | 138 | 103 | 75% | 21 | 14 |

The complete lists, file by file, are in [coverage.md](coverage.md).

Apple covers current cameras better than forum posts and older articles suggest. They
report that it cannot open Nikon High Efficiency or Fujifilm compressed RAF; on OS 27 it
opened all 4 High Efficiency files and 36 of the 37 compressed RAF files in the set.

What Apple does not open (107 files the fallback does):

- Formats it has almost never supported: Sigma X3F from Foveon sensors (0 of 11 open),
  Kodak KDC (0 of 4) and DCR (1 of 5), and Samsung SRW, most of the NX line (3 of 20).
- Particular modes of brands it does support: most Phase One files in IIQ S and Sv2
  compression (9 of 14 Phase One files fail), one compressed RAF from the Fujifilm X-E3, and
  one of two reduced-size files from the Sony RX1R III, a 2025 camera.
- Individual bodies: Pentax K-3 Mark III Monochrome (2023), Olympus E-M10 Mark IIIs,
  DJI Osmo Action, and older Fujifilm EXR and SuperCCD cameras.
- Raw dumps from hacked firmware: 20 files from Canon compacts running CHDK.

What the fallback does not open that Apple does (14 files): Nikon High Efficiency, which
uses a patented codec; JPEG XL and lossy-JPEG DNG; one Sony a7 V file; two phone and
hobby-camera files; and five files where LibRaw reported corrupt data and the library
refused to return a partly garbled image. Neither decoder is a superset of the other.

Neither opens 16 files: eight GoPro GPR files, two more CHDK dumps, and six from action,
dive and drone cameras, a digital film back and a cinema camera.

## How the two decoders' output differs

Left: Apple's decoder. Right: the fallback. Top: the whole frame. Bottom: a 1:1 crop.

![Canon EOS R3: Apple's decoder and the fallback side by side](compare-canon-eos-r3.jpg)

*Canon EOS R3, Bayer sensor, fallback on the GPU path.*

![Fujifilm X-T5: Apple's decoder and the fallback side by side](compare-fujifilm-x-t5.jpg)

*Fujifilm X-T5, X-Trans sensor, fallback on the CPU path.*

Geometry and fine detail match. The look does not. Apple applies a tone curve, sharpening,
noise reduction and, for some lenses, corrections (the vignetting at the left of the
Fujifilm frame is corrected on Apple's side only). The fallback's image is scene-linear with
nothing added, so it is flatter and a little softer.

### Colour, against the camera's own preview

Almost every RAW file carries a preview the camera rendered, which makes it a reference for
whether a decode got the colours right. For the 744 files both decoders open and that carry
one, this is how far each lands from it, ignoring brightness:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="preview-agreement-dark.svg">
  <img src="preview-agreement-light.svg" alt="Distribution of colour distance from the embedded preview: Apple's decoder median 0.027, fallback median 0.044">
</picture>

Thick bar: the middle half of files. Thin bar: the middle 90%. Dot: the median, 0.027 for
Apple and 0.044 for the fallback. Both are well under 0.15, where a result starts to look
wrong.

Above 0.15 there are 8 of Apple's 754 results and 15 of the fallback's 822. Seven files are
flagged for both decoders, which points at the preview being the odd one out. The clear
fallback failures are cameras newer than LibRaw's tables: it reads the Canon EOS R6 Mark III
with the wrong black level and the picture comes out with a pink haze. Apple opens 13 of
the fallback's 15 flagged files, so automatic routing never sends those to the fallback.

The library runs this check on every fallback decode and reports the result
(`RawImage.previewDistance`, `isColorSuspect`).

## Bringing the two together

A gallery that mixed Apple's finished pictures with the fallback's flat ones would show two
kinds of photograph. The way out is to take scene-linear data from both decoders and render
it once, the same way.

Measured on 202 files both decoders open (every fourth one), as the colour difference
between the two routes' pictures:

| Compared | Median ΔE |
|---|---|
| Each decoder's default output | 10.7 |
| Both scene-linear, exposure measured the same way, no look | 2.9 |
| Both through the shared neutral look | 3.2 |
| Both through the shared film look | 2.9 |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="route-match-dark.svg">
  <img src="route-match-light.svg" alt="Colour difference between the two decoders, before and after shared rendering">
</picture>

ΔE here is CIELAB (1976) between area averages on a 24 by 16 grid. About 1 is the smallest
difference visible side by side; above 10 the colours are plainly different. It measures
colour and tone across the frame and is blind to sharpness, noise and local distortion.

The first row is not a fair baseline: one picture has a tone curve and the other does not.
The second row is the real finding. Asking Apple's decoder for linear data and measuring
exposure identically on both brings the routes to within about 3, on 194 of 202 files
closer than their defaults. The look applied afterwards keeps them there; it does not bring
them closer. A difference of 3 is still visible if you flip between the two. What remains
is different colour matrices, and Apple's lens corrections and noise reduction.

![Canon EOS R3 through both decoders: their own output, then a shared neutral look, then a shared film look](looks-canon-eos-r3.jpg)

The looks are a contrast curve, saturation, two tints and a fade, enough to exercise the
rendering step. They are not film emulation.

## Speed and memory

Time from file to a fully rendered, full-resolution image: open the file, then render every
pixel to 8-bit sRGB, as an export would. Each measurement is its own process.

- "Apple" is Apple's decoder called directly, at its default rendering.
- "Apple, linear" asks it for scene-linear output, which is the configuration a caller
  doing its own rendering uses. It costs more because this library measures the picture's
  exposure with a second, reduced decode.
- Neither includes the library's check of whether Apple can open the file; the Mac table
  shows that separately.

### iPhone 16 Pro Max (one launch per figure)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="speed-device-dark.svg">
  <img src="speed-device-light.svg" alt="Seconds to a rendered image per file on an iPhone 16 Pro Max, Apple's decoder asked for linear output against the fallback">
</picture>

| File | Fallback path | Apple | Apple, linear | Fallback | Apple linear, next file | Fallback, next file | Apple linear peak | Fallback peak |
|---|---|---|---|---|---|---|---|---|
| Sony a9 III, 10 MP crop mode | GPU | 0.45 s | 0.53 s | 0.18 s | 0.36 s | 0.12 s | 742 MB | 315 MB |
| Canon EOS R3, 24 MP | GPU | 1.45 s | 1.78 s | 0.41 s | 1.11 s | 0.34 s | 912 MB | 524 MB |
| Nikon Z f, 24 MP | GPU | 0.60 s | 0.80 s | 0.50 s | 0.61 s | 0.44 s | 867 MB | 529 MB |
| Panasonic S1R II, 44 MP | GPU | 6.36 s | 7.03 s | 0.74 s | 1.74 s | 0.73 s | 681 MB | 810 MB |
| Sony a1, 50 MP | GPU | 1.13 s | 1.58 s | 0.58 s | 1.33 s | 0.54 s | 744 MB | 910 MB |
| Fujifilm X-T5, 40 MP | CPU (X-Trans) | 1.09 s | 1.56 s | 9.02 s | 1.38 s | 9.07 s | 721 MB | 1,267 MB |
| Fujifilm GFX100 II, 102 MP | GPU, half size | 2.21 s | 3.40 s | 3.08 s | 4.86 s | 2.97 s | 1,311 MB | 811 MB |

"Next file" is the same decode done a second time in the same process.

### Mac (median of three launches)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="speed-dark.svg">
  <img src="speed-light.svg" alt="Seconds to a rendered image per file on a Mac, Apple's decoder against the fallback">
</picture>

| File | Fallback path | Apple | Apple, linear | Apple via `RawInput.open` | Fallback | Apple peak | Fallback peak |
|---|---|---|---|---|---|---|---|
| Sony a9 III, 10 MP crop mode | GPU | 0.38 s | 0.52 s | 0.48 s | 0.14 s | 1,279 MB | 375 MB |
| Canon EOS R3, 24 MP | GPU | 0.60 s | 0.91 s | 0.87 s | 0.40 s | 2,149 MB | 689 MB |
| Nikon Z f, 24 MP | GPU | 0.44 s | 0.58 s | 0.55 s | 0.46 s | 1,706 MB | 702 MB |
| Panasonic S1R II, 44 MP | GPU | 1.14 s | 1.89 s | 1.86 s | 0.72 s | 3,674 MB | 1,388 MB |
| Sony a1, 50 MP | GPU | 0.90 s | 1.33 s | 1.00 s | 0.49 s | 3,632 MB | 1,345 MB |
| Fujifilm X-T5, 40 MP | CPU (X-Trans) | 0.67 s | 1.01 s | 0.95 s | 11.01 s | 2,510 MB | 1,673 MB |
| Fujifilm GFX100 II, 102 MP | GPU | 1.57 s | 2.28 s | 2.19 s | 3.80 s | 6,041 MB | 2,839 MB |

"Apple via `RawInput.open`" is default rendering with automatic routing in a fresh process,
so it includes the support check. That check is paid for the first file of each camera and
recording mode and then remembered.

### Reading the numbers

- On Bayer files up to 50 MP the fallback is quicker than Apple's decoder asked for linear
  output, on both machines. Against Apple's default rendering it ranges from a tie
  (Nikon Z f on the Mac) to about three times quicker. Apple does more per pixel, and part
  of the linear path's cost is this library's own exposure measurement.
- At 102 MP the fallback is slower than Apple's default rendering on both machines, and on
  the phone it produces a quarter of the pixels (a half-size 25 MP image) while Apple
  renders all 102 MP.
- On X-Trans the fallback is six to sixteen times slower. It runs LibRaw's single-threaded
  CPU pipeline.
- Nothing was terminated for memory on the phone.
- Apple's decoder uses far more memory on the Mac than on the phone for the same file.
- Apple's decoder has a first-use cost per camera, and for one it is large: the first
  Panasonic S1R II decode in a process took 6 to 7 s on the phone and the next under 2 s,
  in every launch that measured it. The time goes in setting the decoder up, before any
  pixel is requested. I could not see what it is doing.

The phone figures are single launches, so a tenth of a second between two rows means
little. Peak memory includes the benchmark's own output buffer, 4 bytes per pixel.

### The ten samples only the fallback opens, on the phone

| Sample | Path | Embedded preview | File to rendered image | Peak memory |
|---|---|---|---|---|
| Samsung NX1, 28 MP | GPU | 53 ms | 0.66 s | 582 MB |
| Samsung NX300, 20 MP | GPU | 44 ms | 0.37 s | 436 MB |
| Fujifilm X-E3, 24 MP | CPU | 26 ms | 5.15 s | 697 MB |
| Olympus E-M10 Mark IIIs, 12 MP | GPU | 30 ms | 0.39 s | 281 MB |
| Panasonic DC-FZ45, 18 MP | GPU | 34 ms | 0.23 s | 384 MB |
| Sigma dp0 Quattro, 20 MP | CPU | 57 ms | 1.03 s | 784 MB |
| Pentax K-3 Mark III Monochrome, 26 MP | CPU | 52 ms | 0.60 s | 641 MB |
| Phase One IQ180, 20 MP | CPU | 44 ms | 1.47 s | 617 MB |
| Canon PowerShot S100V, 12 MP | GPU | 29 ms | 0.30 s | 271 MB |
| DJI Osmo Action, 12 MP | GPU | 28 ms | 0.14 s | 266 MB |

Only the first row was measured after the fallback gained its exposure measurement and
colour check; the other nine predate them and would each be roughly 0.05 to 0.15 s slower
now. The embedded preview takes 24 to 78 ms across every file measured on the phone.

## Damaged files

`rawprobe fuzz` decodes seeded, damaged copies of real files, each in a child process.
Two campaigns were run over eight of the sample files with the same seed: 800 cases in a
release build, and 400 in a build with AddressSanitizer, which turns an out-of-bounds
read or a use after free into a crash. Neither produced a crash or a hang.

This is shallow mutation fuzzing of this project's handling of sizes, margins and levels.
It is not coverage-guided fuzzing of LibRaw. One known gap: LibRaw reports corrupt data for
compressed formats, and those files are refused, but for uncompressed formats it reads what
is there and leaves the rest of the frame empty, and the fallback returns that image.
