# RAW in Studio Pro: a recommendation

A one-page answer to "what should VSCO build, and in what order?", written from the outside.
Everything marked *measured* comes from this repository and can be rerun. Everything about
VSCO's internals is an assumption, listed at the end so it can be corrected.

## The situation

Studio Pro imports JPEG and HEIC. RAW is on the public roadmap, tethering is JPEG-only, and
the audience is working photographers, who shoot RAW. Reviews name the gap. Every month it
stays open is a month a wedding photographer exports JPEGs from another app first.

## Recommendation

**1. Ship RAW on Apple's decoder now.** Weeks, not months.
`CIRAWFilter` opened 821 of 944 test files (87%) and every current mainstream body tested,
including the formats forums say it cannot: Fujifilm compressed, Nikon High Efficiency,
Sony a7 V compressed. *Measured.* It costs nothing to license and Apple maintains it. This
closes the gap for nearly all of Studio Pro's users and unblocks RAW tethering.

**2. Own the rendering, not the decoding.** This is the part that is VSCO.
Ask Apple's decoder for scene-linear output and apply VSCO's tone curve and presets on top,
in VSCO's engine. Do not ship Apple's default look: it is not VSCO's, and it would make RAW
files look different from the same photographer's JPEGs run through the same preset. This
repository shows the shape of it: one rendering step after the decoder, the same for every
source.

**3. Do not build a fallback decoder yet. Instrument first.**
The files Apple cannot open are real but old or niche: Sigma Foveon, Samsung NX, Phase One
Sensor+, a monochrome Pentax, some compact cameras. *Measured.* Before spending on them,
log (with consent) the make, model and failure of every RAW import that Apple's decoder
rejects. A month of that tells you whether the number is 0.2% of imports or 5%.

**4. If the number justifies it, the fallback is a bounded project, and this is it.**
LibRaw under its CDDL licence, behind a C boundary, with a GPU kernel for Bayer sensors.
It raises coverage from 87% to 98% of the test set. *Measured.* The costs are known:

| Cost | Size |
|---|---|
| Build to production quality | My estimate: one engineer, roughly a quarter. This prototype is the first few weeks of it. |
| Rendering parity with Apple's route | Median colour difference of ΔE 3 after a shared look, down from 11. *Measured.* Good enough for a gallery; closing the rest means lens corrections and noise reduction. |
| Speed | Faster than Apple on Bayer files on an iPhone 16 Pro Max; about six times slower on X-Trans. *Measured.* |
| Maintenance | Track LibRaw releases (about one a year) and re-verify per camera. Not free, not large. |
| Correctness risk | LibRaw decodes some new cameras wrongly instead of failing. The library now checks each result against the camera's embedded preview and flags disagreement. *Measured: 22 of 885.* |
| Legal | CDDL permits static linking in a closed-source app. Needs counsel's sign-off. |

## What I would not do

- **Wait for a complete in-house RAW engine before shipping anything.** Decoding is a
  commodity on Apple platforms. The engine's value is the look and the edit, and both can
  sit on top of Apple's decoder today.
- **Write decoders.** There are about 1,300 camera models. LibRaw's authors have spent
  twenty years on them. Wrap it or do without.
- **Promise "all RAW formats".** Nikon High Efficiency needs a licensed codec. GoPro needs
  another. Say which cameras are supported and publish the list; this repository's probe
  generates it.

## What changes on Android

Everything. As far as I know Android has no system RAW decoder beyond DNG, so there the fallback is not a
gap-filler, it is the feature. If Studio Pro is headed to Android, the case for building
the LibRaw-based decoder gets much stronger, and the same C core serves both platforms.
That is the main reason to keep the decoder behind a C boundary instead of a Swift one.

## Assumptions to correct

- That Studio Pro's engine can take a linear image from `CIRAWFilter` as its input on iOS
  and macOS. If it must own decoding for cross-platform consistency, step 4 moves up.
- That the look matters more to VSCO's users than the last 11% of cameras. I believe it,
  but VSCO has the import data and I do not.
- That a quarter of one engineer is affordable. If not, step 3's data decides.
- Timings come from one phone (iPhone 16 Pro Max) and one Mac. Older, smaller-memory
  phones are untested.
