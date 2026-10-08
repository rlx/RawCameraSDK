# RAW in Studio Pro: a recommendation

A one-page answer to "what should VSCO build, and in what order?", written from the outside.
Everything marked *measured* comes from this repository and can be rerun. Everything about
VSCO's internals is an assumption, listed at the end so it can be corrected.

## The situation

Studio Pro imports JPEG and HEIC. RAW is on the public roadmap, tethering is JPEG-only, and
the audience is working photographers, who shoot RAW. VSCO's own guide tells them to export
JPEGs from another app first; every month the gap stays open, that is the workflow.

## Recommendation

**1. Ship RAW on Apple's decoder now.** I would expect weeks, not months.
`CIRAWFilter` opened 821 of 944 test files (87%), including nearly every recent mainstream
body in the set and formats forums say it cannot open: all 4 Nikon High Efficiency files
and 36 of 37 Fujifilm compressed ones. *Measured.* It costs nothing to license and Apple
maintains it. My expectation, which VSCO's import data would confirm or correct, is that
this covers most of Studio Pro's users; it is also the decoder RAW tethering would need.

**2. Own the rendering, not the decoding.** This is the part that is VSCO.
Ask Apple's decoder for scene-linear output and apply VSCO's tone curve and presets on top,
in VSCO's engine. Do not ship Apple's default look: it is not VSCO's, and it would make RAW
files look different from the same photographer's JPEGs run through the same preset. This
repository shows the shape of it: one rendering step after the decoder, the same for every
source.

**3. Do not build a fallback decoder yet. Instrument first.**
The files Apple cannot open are real but mostly old or niche: Sigma Foveon, Samsung NX,
Phase One in two compression modes, a monochrome Pentax, hacked-firmware dumps from Canon
compacts. *Measured.* There are exceptions that matter more, such as a reduced-size mode of
the 2025 Sony RX1R III. Before spending on any of them,
log (with consent) the make, model and failure of every RAW import that Apple's decoder
rejects. A month of that tells you whether the number is 0.2% of imports or 5%.

**4. If the number justifies it, the fallback is a bounded project, and this is it.**
LibRaw under its CDDL licence, behind a C boundary, with a GPU kernel for Bayer sensors.
It raises coverage from 87% to 98% of the test set. *Measured.* The costs are known:

| Cost | Size |
|---|---|
| Build to production quality | My estimate: one engineer for roughly three months. This prototype is the first few weeks of it. |
| Rendering parity with Apple's route | Median colour difference of ΔE 3 after a shared look, down from 11. *Measured.* Good enough for a gallery; closing the rest means lens corrections and noise reduction. |
| Speed | On an iPhone 16 Pro Max, as fast as Apple's decoder or faster on Bayer files up to 50 MP, slower at 102 MP, and about nine times slower on X-Trans. *Measured, one phone.* |
| Maintenance | Track LibRaw releases and re-verify per camera. Not free, not large. |
| Correctness risk | LibRaw decodes some new cameras wrongly instead of failing. The library checks each result against the camera's embedded preview and flags disagreement. *Measured: 15 of 822 flagged.* |
| Legal | CDDL permits static linking in a closed-source app. Needs counsel's sign-off. |

## What I would not do

- **Wait for a complete in-house RAW engine before shipping anything.** Decoding is a
  commodity on Apple platforms. The engine's value is the look and the edit, and both can
  sit on top of Apple's decoder today.
- **Write decoders.** There are about 1,300 camera models. LibRaw's authors have spent
  twenty years on them. Wrap it or do without.
- **Promise "all RAW formats".** Nikon High Efficiency needs a licensed codec, and GoPro's
  format needs a further SDK. Say which cameras are supported and publish the list; this
  repository's probe generates it.

## What changes on Android

Everything. As far as I know Android has no system RAW decoder beyond DNG, so there the fallback is not a
gap-filler, it is the feature. If Studio Pro is headed to Android, the case for building
the LibRaw-based decoder gets much stronger. The decoding half of this project would carry
over: it is LibRaw behind a C boundary, which is the main reason that boundary is C and not
Swift. The GPU development kernel is Metal and would need writing again for Android.

## Assumptions to correct

- That Studio Pro's engine can take a linear image from `CIRAWFilter` as its input on iOS
  and macOS. If it must own decoding for cross-platform consistency, step 4 moves up.
- That the look matters more to VSCO's users than the last 11% of cameras. I believe it,
  but VSCO has the import data and I do not.
- That three months of one engineer is affordable. If not, step 3's data decides.
- Timings come from one phone (iPhone 16 Pro Max) and one Mac. Older, smaller-memory
  phones are untested.
