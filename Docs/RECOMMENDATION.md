# RAW in Studio Pro: a recommendation

Written from outside VSCO. Figures marked *measured* come from this repository and can be
rerun. My assumptions are listed at the end.

## Summary

Ship RAW in Studio Pro on Apple's decoder, with scene-linear output and the decoder version
stored in each edit. Record which files Apple rejects. Build a second decoder only if that
record shows demand, because its costs are permanent and its benefit is mostly old cameras.

## Background

- Studio Pro imports JPEG and HEIC. Its guide (22 September 2026) says RAW "is confirmed on
  the product roadmap", and tethering in 1.3.0 is JPEG-only.
  ([Guide](https://www.vsco.co/learn/getting-started-vsco-studio-pro),
  [App Store](https://apps.apple.com/us/app/vsco-studio-pro-photo-editor/id6759939220))
- VSCO's main app already edits RAW on supported iOS devices.
  ([Photo editor FAQ](https://www.vsco.co/features/photo-editor))

VSCO already decodes RAW, so I assume the open work is getting RAW into the new engine: in
its working color space, matching across iOS and macOS, and stable when an edit is
reopened after an OS update.

## Measurements

| Question | Result |
|---|---|
| Coverage of Apple's decoder | 821 of 944 test files (87%); 93% of those shot since 2019 |
| Added by a LibRaw fallback | 107 files, for 98% in total |
| Agreement between the two | Median ΔE about 3 from scene-linear data with a common exposure measurement |
| Fallback speed | Comparable to Apple on Bayer sensors, several times slower on X-Trans |
| Fallback correctness | 15 of 822 results flagged as probably wrong color |

Details are in [MEASUREMENTS.md](MEASUREMENTS.md).

## Proposal

**1. Use Apple's decoder in Studio Pro.** It opens nearly every recent mainstream camera
in the test set, including all 4 Nikon High Efficiency files and 36 of 37 compressed
Fujifilm files. Apple maintains it and there is nothing to license.

**2. Request scene-linear output.** With the tone curve and gamut mapping off,
`CIRAWFilter` returns data proportional to the scene. VSCO's engine then applies the look,
and RAW and JPEG files from one shoot go through the same presets. Two costs, *measured* on
an iPhone 16 Pro Max:

- The first file from a camera model can be slow: 6 to 7 s for a Panasonic S1R II, under
  2 s for the next. Warm the decoder up off the main thread.
- This library measures exposure with a second, reduced decode, which adds 0.1 to 1.7 s.
  A per-camera baseline would remove that.

**3. Pass the engine a texture.** `RawImage.makeTexture(device:colorSpace:)` produces a
16-bit float Metal texture, top row first, from either decoder, in whichever linear space
the engine works in. Colors outside sRGB are kept. When the fallback's GPU kernel
developed the file on the same device, its texture is handed over without a copy. wgpu can
wrap a Metal texture through its HAL, which is where a Rust engine would connect. I have
not built that connection.

**4. Store the decoder version with each edit.** Apple revises its RAW engine across OS
releases (`CIRAWFilter.decoderVersion`, `supportedDecoderVersions`). Reopening an edit
with the version it was made on keeps the picture the same. The library reports the
version in `RawImage.appleDecoderVersion` and reopens with it through
`appleDecoderVersion = .pinned(...)`. If a later OS has dropped that version the open fails
with the list of versions still offered, so the app can tell the user the picture will
change instead of changing it silently. `RawInput.fallbackVersion` serves the same purpose
for the fallback.

Photos come from the library as bytes, not files. `RawInput.open(data:typeHint:)` takes
them directly. Pass PhotoKit's type identifier: without it Apple's decoder renders Sony,
Samsung and Pentax files empty, which I found only by testing it. *Measured* in the
simulator: PhotoKit reports the exact type the decoder needs for all ten sample formats
that Photos will store, and each opens on the same decoder as from disk.

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
3. A path to the engine that bypasses Core Image for files the CPU pipeline develops.
4. Per-camera verification in CI and a process for LibRaw updates.

## What a fallback costs to own

| Cost | Size |
|---|---|
| Binary | 0.85 MB for LibRaw and 0.15 MB for the Swift library, *measured* in the demo's arm64 Release build after dead-code stripping |
| Memory | Up to 1.3 GB peak for a 40 MP X-Trans file, *measured* on a phone with 8 GB. The library bounds decoding to a quarter of the device's memory, by an estimate and for the fallback only. Untested on phones with 4 GB or less |
| Security | A large C++ parser reading untrusted files in the app's process. The mutation fuzzing here found nothing in 1,200 cases, which is not evidence of safety. A product needs coverage-guided fuzzing, and ideally decoding in an extension process |
| Upkeep | Each LibRaw release needs every camera re-verified, because LibRaw can decode a new camera with wrong colors. Someone has to own that and the supported-camera list |
| Consistency | Two decoders mean two renderings of the same camera. A user who updates iOS can find a file moved from the fallback to Apple, with a different picture, unless edits store the route as well as the version |
| Legal | Static linking under CDDL needs legal review. CDDL allows patching LibRaw as long as the patched files are published |

## What would change this recommendation

- The rejection record shows a share of imports large enough to justify the costs above.
- Studio Pro must render a file identically on iOS, Android and the web. Then the engine
  has to own decoding everywhere and Apple's decoder cannot be the main route.
- Apple removes a decoder version or a format that existing edits depend on.

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
- Shipping the fallback without its color check.

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
