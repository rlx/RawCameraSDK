# RAW in Studio Pro: a recommendation

This is what I would propose if I were on the team, written from outside it. Figures marked
*measured* come from this repository and can be rerun. I have no knowledge of VSCO's
internals; the assumptions I am making are listed at the end.

## Where things stand

Two public facts frame the question.

- Studio Pro imports JPEG and HEIC. Its guide (22 September 2026) says RAW "is confirmed on
  the product roadmap" and asks RAW shooters to export JPEGs first; tethering in 1.3.0 is
  JPEG-only. ([Guide](https://www.vsco.co/learn/getting-started-vsco-studio-pro),
  [App Store](https://apps.apple.com/us/app/vsco-studio-pro-photo-editor/id6759939220))
- VSCO's main app already edits RAW on supported iOS devices.
  ([Photo editor FAQ](https://www.vsco.co/features/photo-editor))

So decoding RAW is not new to VSCO. The open question is how RAW reaches the new editor,
and my guess is that the hard part is the new engine and not the decoder: the data has to
arrive in the engine's working space, look the same on iOS and macOS, and keep looking the
same when a photographer reopens an edit next year.

## What I measured

| Question | Answer |
|---|---|
| How much does Apple's decoder cover? | 821 of 944 test files (87%), and more of the recent ones: see the README |
| What does a LibRaw fallback add? | 107 more files, 98% in total |
| Do the two decoders' pictures match? | Not out of the box. Through one shared rendering step, to a median ΔE of about 3 |
| What does the fallback cost in speed? | Comparable to Apple on Bayer sensors, several times slower on X-Trans |
| Is the fallback always right? | No. It flags 15 of 822 of its own results as probably wrong |

## What I would do

**1. Use Apple's decoder in Studio Pro.** It opens nearly every recent mainstream camera in
the test set, including formats older forum posts say it cannot (all 4 Nikon High
Efficiency files, 36 of 37 Fujifilm compressed). It costs nothing to license and Apple
maintains it. I expect this covers most Studio Pro users, but that is VSCO's data to check,
not mine.

**2. Take scene-linear data from it, not Apple's rendering.** `CIRAWFilter` with its tone
curve and gamut mapping off returns data proportional to the scene. The look then belongs to
VSCO's engine, and a RAW file and a JPEG from the same shoot go through the same presets.
Two costs to know about, both *measured* on an iPhone 16 Pro Max:

- Apple's decoder has a first-use cost per camera model, and for one it is large: 6 to 7 s
  for the first Panasonic S1R II file in a process, about 1 s for the next. Warm it up off
  the main thread.
- This library measures each picture's exposure with a second, reduced decode when asked
  for linear output, which added 0.1 to 1.2 s depending on the file. A product would replace
  that with a
  per-camera baseline and pay nothing.

**3. Hand the engine a texture, not a `CIImage`.** A GPU engine wants the pixels in a
texture it owns, in a stated colour space. `RawImage.makeTexture(device:)` in this
repository does that hand-off (16-bit float, extended linear sRGB, top row first) and is
tested on both decoders. As I understand wgpu, a Metal texture can be wrapped for it
through its HAL, so this is the seam where a Rust engine would connect; I have not built
that part.

**4. Pin the decoder version with each edit.** Apple revises its RAW engine with OS
releases (`CIRAWFilter.decoderVersion`, `supportedDecoderVersions`). An edit saved against
version 8 should reopen against version 8 for as long as the OS offers it, or the same
sliders give a different picture after an update. The fallback needs the same treatment:
`RawInput.fallbackVersion` is there to be stored.

**5. Count before building a fallback.** The files Apple cannot open are mostly old or
niche: Sigma Foveon, Samsung NX, Phase One in two compression modes, a monochrome Pentax,
hacked-firmware dumps. There are exceptions, such as a reduced-size mode of the 2025 Sony
RX1R III. Whether any of this matters to Studio Pro's users is an empirical question.
The library reports every file Apple turns away, with camera and compression scheme
(`RawEvent.appleRejected`). A few weeks of that, with consent, says whether the number is
0.2% of imports or 5%.

**6. If the count justifies it, the fallback is a bounded project.** This repository is its
first stage. What remains, as I would plan it:

| Work | My estimate |
|---|---|
| Harden the decode boundary: sanitizer-backed fuzzing in CI, detection of truncated uncompressed files, a format allowlist | 2 to 3 weeks |
| Rendering parity with Apple's route: lens corrections from embedded metadata, noise reduction, highlight handling, a calibrated baseline exposure in place of auto-exposure | 4 to 6 weeks |
| Wide-gamut output and a path into the engine that does not pass through Core Image | 1 to 2 weeks |
| Per-camera verification in CI and a process for taking LibRaw updates | 1 to 2 weeks |

That is roughly three months for one engineer, plus a continuing cost: each LibRaw release has
to be re-verified per camera, because LibRaw can decode a new camera wrongly instead of
refusing it. The licence position (LibRaw under CDDL, statically linked) needs counsel's
sign-off. Note that CDDL does not forbid patching LibRaw; it requires publishing the
patched files, so a security fix ahead of upstream is possible.

## Alternatives I considered

| Option | Why not, or when |
|---|---|
| Write decoders in-house | About 1,300 camera models and twenty years of accumulated quirks. Not a good use of a small team. |
| RawSpeed | LGPL only, which is awkward to satisfy in a statically linked App Store app, and it decodes without developing. |
| A Rust decoder (rawler, rawloader) | The natural fit for a Rust engine, and worth a serious look. When I checked they were LGPL and covered fewer cameras than LibRaw; I have not evaluated them beyond that. |
| Adobe's DNG SDK | Opens DNG only. Useful if VSCO were willing to ask users to convert, which defeats the purpose. |
| License a codec for Nikon High Efficiency | Only needed if the fallback must cover it. Apple's decoder already does. |

## What I would not do

- Wait for a complete in-house RAW pipeline before shipping RAW in Studio Pro.
- Promise "all RAW formats". Some need licensed codecs. Publish the list of supported
  cameras instead; the probe in this repository generates it.
- Ship the fallback without its colour check. A tinted picture presented as correct is worse
  than "this camera is not supported yet".

## Android

As far as I know Android has no system RAW decoder beyond DNG, so there the fallback would
not be a gap-filler, it would be the feature. The decoding half of this project would carry
over, since it is LibRaw behind a C boundary. The GPU development kernel is Metal and would
need writing again, or porting to the engine's shader language.

## Assumptions to correct

- That Studio Pro's engine can accept a linear image or texture from `CIRAWFilter` on iOS
  and macOS. If it must own decoding for consistency across platforms, step 6 moves up.
- That the main app's RAW support is built on Apple's decoder. VSCO's FAQ ties it to
  specific iOS devices, which suggests so, but I do not know.
- That the look matters more to VSCO's users than the last tenth of cameras.
- That three months of one engineer is available for the fallback if the data asks for it.
- The timings come from one phone and one Mac. Phones with 4 GB or less are untested.
