# RAW in Studio Pro: a recommendation

Written from outside VSCO. Figures marked *measured* come from this repository and can be
rerun. My assumptions are listed at the end.

## Background

- Studio Pro imports JPEG and HEIC. Its guide (22 September 2026) says RAW "is confirmed on
  the product roadmap", and tethering in 1.3.0 is JPEG-only.
  ([Guide](https://www.vsco.co/learn/getting-started-vsco-studio-pro),
  [App Store](https://apps.apple.com/us/app/vsco-studio-pro-photo-editor/id6759939220))
- VSCO's main app already edits RAW on supported iOS devices.
  ([Photo editor FAQ](https://www.vsco.co/features/photo-editor))

VSCO already decodes RAW, so I assume the open work is getting RAW into the new engine: in
its working colour space, matching across iOS and macOS, and stable when an edit is
reopened after an OS update.

## Measurements

| Question | Result |
|---|---|
| Coverage of Apple's decoder | 821 of 944 test files (87%); 93% of those shot since 2019 |
| Added by a LibRaw fallback | 107 files, for 98% in total |
| Agreement between the two | Median ΔE about 3 from scene-linear data with a common exposure measurement |
| Fallback speed | Comparable to Apple on Bayer sensors, several times slower on X-Trans |
| Fallback correctness | 15 of 822 results flagged as probably wrong colour |

Details are in [MEASUREMENTS.md](MEASUREMENTS.md).

## Proposal

**1. Use Apple's decoder in Studio Pro.** It opens nearly every recent mainstream camera
in the test set, including all 4 Nikon High Efficiency files and 36 of 37 compressed
Fujifilm files. Apple maintains it and there is nothing to license.

**2. Request scene-linear output.** With the tone curve and gamut mapping off,
`CIRAWFilter` returns data proportional to the scene. VSCO's engine then applies the look,
and RAW and JPEG files from one shoot go through the same presets. Two costs, *measured* on
an iPhone 16 Pro Max:

- The first file from a camera model can be slow: 6 to 7 s for a Panasonic S1R II, about
  1 s for the next. Warm the decoder up off the main thread.
- This library measures exposure with a second, reduced decode, which adds 0.1 to 1.2 s.
  A per-camera baseline would remove that.

**3. Pass the engine a texture.** `RawImage.makeTexture(device:)` produces a 16-bit float
Metal texture in extended linear sRGB, top row first, from either decoder. wgpu can wrap a
Metal texture through its HAL, which is where a Rust engine would connect. I have not built
that connection.

**4. Store the decoder version with each edit.** Apple revises its RAW engine across OS
releases (`CIRAWFilter.decoderVersion`, `supportedDecoderVersions`). Reopening an edit
with the version it was made on keeps the picture the same. `RawInput.fallbackVersion`
serves the same purpose for the fallback.

**5. Measure demand before building a fallback.** The files Apple rejects are mostly old
or niche: Sigma Foveon, Samsung NX, two Phase One compression modes, a monochrome Pentax.
A few are recent, such as a reduced-size mode of the 2025 Sony RX1R III. The library
reports each rejected file with its camera and compression scheme
(`RawEvent.appleRejected`). Collected with consent, that shows how many imports are
affected.

**6. If demand is there, extend the fallback.** Remaining work, in order:

1. Harden the decode boundary: sanitizer fuzzing in CI, detection of truncated
   uncompressed files, a format allowlist.
2. Rendering parity with Apple: lens corrections from metadata, noise reduction, highlight
   handling, calibrated baseline exposure. This is the largest item.
3. Wide-gamut output and a path to the engine that bypasses Core Image.
4. Per-camera verification in CI and a process for LibRaw updates.

Each LibRaw release needs re-verifying per camera, because LibRaw can decode a new camera
with wrong colours. Static linking under CDDL needs legal review. CDDL allows patching
LibRaw as long as the patched files are published.

## Alternatives

| Option | Assessment |
|---|---|
| In-house decoders | About 1,300 camera models to support and maintain. |
| RawSpeed | LGPL, hard to satisfy in a statically linked App Store app. Decodes but does not develop. |
| Rust decoders (rawler, rawloader) | A natural fit for a Rust engine. When I checked they were LGPL and supported fewer cameras than LibRaw. Not evaluated further. |
| Adobe DNG SDK | DNG only, so users would have to convert first. |
| Licensed Nikon High Efficiency codec | Not needed while Apple's decoder handles those files. |

## Not recommended

- Holding RAW in Studio Pro until an in-house pipeline is complete.
- Promising "all RAW formats". Some need licensed codecs. Publish the supported-camera
  list, which the probe in this repository generates.
- Shipping the fallback without its colour check.

## Android

Android has no system RAW decoder beyond DNG, as far as I know, so the fallback would be
the whole feature there. The LibRaw core and its C interface carry over. The Metal kernel
does not, but the WGSL version may.

## Assumptions

- Studio Pro's engine can take a linear image or texture from `CIRAWFilter` on iOS and
  macOS. If it has to own decoding for cross-platform consistency, step 6 comes first.
- The main app's RAW support uses Apple's decoder. The FAQ ties it to specific iOS
  devices, which suggests so.
- Timings come from one phone and one Mac. Phones with 4 GB or less are untested.
