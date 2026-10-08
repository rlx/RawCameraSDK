# Measurements

Measured on an Apple silicon Mac (macOS 27.0.1) and an iPhone 16 Pro Max (iOS 27.0.1).
[BUILDING.md](BUILDING.md) has the commands to regenerate everything.

## Coverage

`rawprobe` ran both decoders over 944 files from 898 camera models, all CC0 samples from
[raw.pixls.us](https://raw.pixls.us): one file per camera in the archive, plus extra
compression modes for current bodies. Each file counts once regardless of how common the
camera is.

| | Files | Share |
|---|---|---|
| Apple's decoder opens it | 821 | 87% |
| Only the fallback opens it | 107 | 11% |
| Neither opens it | 16 | 2% |
| Opened by one or the other | 928 | 98% |

Of the 821 that Apple opens, the fallback also opens 807.

Of the 367 files with a capture date in 2019 or later, Apple opens 340 (93%). The cut is
by capture date, so it includes older cameras still in use, which account for most of the
misses.

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

The file-by-file lists are in [coverage.md](coverage.md).

On OS 27 Apple opened all 4 Nikon High Efficiency files and 36 of the 37 compressed
Fujifilm RAF files, two formats older articles list as unsupported.

Only the fallback opens (107 files):

- Sigma X3F from Foveon sensors (Apple opens 0 of 11), Kodak KDC (0 of 4) and DCR (1 of 5),
  Samsung SRW (3 of 20).
- Phase One IIQ S and Sv2 compression (9 of 14 Phase One files), one compressed RAF from
  the Fujifilm X-E3, one of two reduced-size files from the 2025 Sony RX1R III.
- Pentax K-3 Mark III Monochrome (2023), Olympus E-M10 Mark IIIs, DJI Osmo Action, older
  Fujifilm EXR and SuperCCD cameras.
- 20 CHDK firmware dumps from Canon compacts.

Only Apple opens (14 files): Nikon High Efficiency, JPEG XL and lossy-JPEG DNG, one Sony
a7 V file, two phone and hobby-camera files, and five files the fallback refused because
LibRaw reported corrupt data.

Neither opens 16 files: eight GoPro GPR files, two CHDK dumps, and six from action, dive
and drone cameras, a digital film back and a cinema camera.

## Output differences

Left: Apple's decoder. Right: the fallback. Top: the whole frame. Bottom: a 1:1 crop.

![Canon EOS R3: Apple's decoder and the fallback side by side](compare-canon-eos-r3.jpg)

*Canon EOS R3, Bayer sensor, fallback on the GPU path.*

![Fujifilm X-T5: Apple's decoder and the fallback side by side](compare-fujifilm-x-t5.jpg)

*Fujifilm X-T5, X-Trans sensor, fallback on the CPU path.*

Geometry and fine detail match. Apple also applies a tone curve, sharpening, noise
reduction and some lens corrections, such as the vignetting at the left of the Fujifilm
frame. The fallback's image is scene-linear with none of those, so it looks flatter and
slightly softer.

### Colour against the embedded preview

Most RAW files carry a preview rendered by the camera, which serves as a colour reference.
The chart shows each decoder's distance from it, ignoring brightness, for the 744 files
that both decoders open and that have a preview.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="preview-agreement-dark.svg">
  <img src="preview-agreement-light.svg" alt="Distribution of colour distance from the embedded preview: Apple's decoder median 0.027, fallback median 0.044">
</picture>

The thick bar spans the middle half of files, the thin bar the middle 90%, and the dot is
the median: 0.027 for Apple and 0.044 for the fallback. Results start to look wrong at
about 0.15.

8 of Apple's 754 results and 15 of the fallback's 822 are above 0.15. Seven files are
flagged for both decoders, so the preview is probably the outlier there. The clearest
fallback failures are cameras newer than LibRaw's tables. The Canon EOS R6 Mark III, for
example, gets the wrong black level and a pink haze. Apple opens 13 of the fallback's 15
flagged files, so automatic routing sends those to Apple.

The library runs this check on every fallback decode (`RawImage.previewDistance`,
`isColorSuspect`).

## Matching the two decoders

Colour difference between the two decoders' pictures, on 202 files that both open (every
fourth one):

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

ΔE is CIELAB (1976) between area averages on a 24 by 16 grid. A difference of about 1 is
just visible side by side, and above 10 is obvious. The measure covers colour and tone
and does not see sharpness, noise or local distortion.

The first row compares a picture with a tone curve to one without. In the second row
Apple's decoder returns linear data and exposure is measured the same way for both. That
brings the median to about 3, and 194 of 202 files end up closer than with the defaults.
Applying a look afterwards does not change the difference much. A ΔE of 3 is still visible
when flipping between the two pictures. The remainder comes from different colour
matrices and from Apple's lens corrections and noise reduction.

![Canon EOS R3 through both decoders: their own output, then a shared neutral look, then a shared film look](looks-canon-eos-r3.jpg)

The looks are a contrast curve, saturation, two tints and a fade. They exist to exercise
the rendering step and do not emulate film.

## Speed and memory

Times run from opening the file to a full-resolution render in 8-bit sRGB. Each
measurement is a separate process.

- "Apple" is Apple's decoder called directly with default rendering.
- "Apple, linear" requests scene-linear output. It is slower because this library then
  measures exposure with a second, reduced decode.
- Both exclude the library's check of whether Apple can open the file. The Mac table shows
  that separately.

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

"Next file" is the same decode repeated in the same process.

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

"Apple via `RawInput.open`" uses automatic routing in a fresh process and so includes the
support check. The check runs for the first file of each camera and recording mode.

### Observations

- On Bayer files up to 50 MP the fallback is faster than Apple's linear output on both
  machines. Against Apple's default rendering it ranges from equal (Nikon Z f on the Mac)
  to about three times faster. Apple does more work per pixel.
- At 102 MP the fallback is slower than Apple's default rendering. On the phone it also
  outputs a half-size 25 MP image where Apple renders all 102 MP.
- On X-Trans the fallback is six to sixteen times slower, because LibRaw's CPU pipeline is
  single-threaded.
- No run was terminated for memory on the phone.
- Apple's decoder uses much more memory on the Mac than on the phone for the same file.
- The first Panasonic S1R II decode in a process took 6 to 7 s on the phone and later ones
  under 2 s, in every launch. The time is spent setting up the decoder before any pixel is
  requested. I could not determine the cause.

Phone figures are single launches, so differences of a tenth of a second are within noise.
Peak memory includes the benchmark's output buffer at 4 bytes per pixel.

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

Only the first row includes the fallback's exposure measurement and colour check. The
other nine were measured before those were added and would now be about 0.05 to 0.15 s
slower. Across all files measured on the phone the embedded preview takes 24 to 78 ms.

## Damaged files

`rawprobe fuzz` decodes seeded, damaged copies of real files, each in a child process. Two
runs over eight sample files, 800 cases in a release build and 400 under AddressSanitizer,
produced no crashes or hangs.

This is mutation fuzzing of the project's own handling of sizes, margins and levels, and
is no substitute for coverage-guided fuzzing of LibRaw. A known gap: a truncated file in
an uncompressed format decodes with the missing rows empty, and the fallback returns it.
