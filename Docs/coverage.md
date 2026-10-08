# Decoder coverage

Measured with `rawprobe` on macOS 27.0.1 (arm64), over 944 CC0 files from raw.pixls.us covering 898 camera models. Regenerate with `Scripts/corpus.py fetch`, `rawprobe Tests/Corpus --json Tests/probe-results.json`, `Scripts/coverage.py`.

| Result | Files |
|---|---|
| Both decoders open it | 807 |
| Only the fallback opens it | 107 |
| Only Apple opens it | 14 |
| Neither opens it | 16 |

Fallback decode time, median: 0.18 s on the Metal path (784 files), 1.29 s on the CPU path (130 files).

"Opens" means pixels came out. It does not mean the colour is right, so each fallback result is also compared with the camera's embedded preview: 22 of 885 files with a preview differ enough to be suspect (listed at the end).

## Only the fallback opens it

| Format | Files | Cameras |
|---|---|---|
| Canon CRW | 18 | Canon IXUS 160, Canon PowerShot A3300 IS, Canon PowerShot A620, Canon PowerShot A640, Canon PowerShot A720 IS, Canon PowerShot D10 and 7 more |
| Samsung SRW | 17 | Samsung EK-GN120, Samsung EX1, Samsung NX mini, Samsung NX1, Samsung NX1000, Samsung NX1100 and 10 more |
| Fujifilm RAF | 12 | Fujifilm DBP for GX680, Fujifilm HS30EXR, Fujifilm HS33EXR, Fujifilm S100FS, Fujifilm S200EXR, Fujifilm S5000 and 6 more |
| Sigma X3F | 11 | Sigma DP1, Sigma DP1 Merrill, Sigma DP2 Merrill, Sigma DP3 Merrill, Sigma SD1 Merrill, Sigma SD14 and 5 more |
| Phase One IIQ | 9 | Phase One H 25, Phase One IQ180, Phase One IQ3 100MP, Phase One P20+, Phase One P25+, Phase One P40+ and 3 more |
| Olympus ORF | 7 | Olympus C5060WZ, Olympus E-10, Olympus E-M10MarkIIIS, Olympus SP510UZ, Olympus SP550UZ, Olympus SP565UZ and 1 more |
| Canon CR2 | 4 | Canon PowerShot S100V, Canon PowerShot SX110 IS, Canon PowerShot SX30 IS, Canon PowerShot SX40 HS |
| Kodak DCR | 4 | Kodak DCS Pro 14N, Kodak DCS Pro 14nx, Kodak DCS Pro SLR/c, Kodak DCS760C |
| Kodak KDC | 4 | Kodak EasyShare Z981, Kodak EasyShare Z990, Kodak P712 ZOOM, Kodak P880 ZOOM |
| Nikon NEF | 3 | Nikon COOLSCAN IV ED, Nikon COOLSCAN V ED, Nikon E5700 |
| GITUP RAW | 2 | GITUP GIT2 16:9, GITUP GIT2P 16:9 |
| Panasonic RW2 | 2 | Panasonic DC-FZ45, Panasonic DMC-FX150 |
| DJI DNG | 1 | DJI Osmo Action |
| Gitup RAW | 1 | Samsung WB550 |
| Leaf IIQ | 1 | Leaf Credo 40 |
| Leaf MOS | 1 | Leaf Aptus 22 |
| Minolta MDC | 1 | Minolta RD175 |
| Minolta MRW | 1 | Minolta DiMAGE 5 |
| Panasonic RAW | 1 | Panasonic DMC-FZ8 |
| Pentax PEF | 1 | Pentax K-3 Mark III Monochrome |
| SJCAM RAW | 1 | GITUP GIT2 16:9 |
| SJCam RAW | 1 | Kodak 12MP |
| Sinarback STI | 1 | Sinarback eVolution 75, Sinar p3 / f3 |
| Sony ARW | 1 | Sony DSC-RX1RM3 |
| Xiaomi DNG | 1 | Xiaomi HM NOTE 1LTE |
| Xiaomi RAW | 1 | GITUP GIT2 4:3 |

## Only Apple opens it

- Canon EOS 5D Mark III (Lossy JPEG compression, rgb (3:2)), DNG: `?`
- Nikon Z 8 (8bit 8bit compressed (3:2)), NEF: `nikon_he_load_raw()`
- Nikon Z 9 (8bit 8bit compressed (3:2)), NEF: `nikon_he_load_raw()`
- Nikon Z f (8bit 8bit lossy compressed (3:2)), NEF: `nikon_he_load_raw()`
- Nikon Z50_2 (8bit compressed (3:2)), NEF: `nikon_load_raw()`
- Nikon Z5_2 (8bit compressed (3:2)), NEF: `nikon_load_raw()`
- Nikon Z6_3 (8bit compressed (3:2)), NEF: `nikon_he_load_raw()`
- Panasonic DMC-FZ38 (16:9), RW2: `panasonic_load_raw()`
- RaspberryPi RP_ov5647 (3:2), RAW: `?`
- SONY ILCE-7M5 (14bit (3:2)), ARW: `?`
- Samsung Galaxy S23 (16:9), DNG: `lossless_dng_load_raw()`
- Samsung Galaxy S23+ (4:3), DNG: `lossless_dng_load_raw()`
- Samsung SM-S901E (4:3), DNG: `jxl_dng_load_raw_placeholder()`
- samsung SM-G973U (16bit 16bit (2.1132075471698)), DNG: `?`

## Neither opens it

- ?, ARI: `?`
- ?, CRW: `?`
- ?, CRW: `?`
- ?, RAW: `?`
- ?, RAW: `?`
- ?, RAW: `?`
- ?, RAW: `?`
- ?, RAW: `?`
- GoPro FUSION (16bit (1:1)), GPR: `vc5_dng_load_raw_placeholder()`
- GoPro HERO10 Black (16bit (4:3)), GPR: `vc5_dng_load_raw_placeholder()`
- GoPro HERO11 Black (16bit (5:4)), GPR: `vc5_dng_load_raw_placeholder()`
- GoPro HERO5 Black (16bit (4:3)), GPR: `vc5_dng_load_raw_placeholder()`
- GoPro HERO6 Black (16bit (4:3)), GPR: `vc5_dng_load_raw_placeholder()`
- GoPro HERO7 Black (16bit (4:3)), GPR: `vc5_dng_load_raw_placeholder()`
- GoPro HERO8 Black (16bit (4:3)), GPR: `vc5_dng_load_raw_placeholder()`
- GoPro HERO9 Black (16bit (4:3)), GPR: `vc5_dng_load_raw_placeholder()`

## Fallback opens it but the colour is suspect

- Panasonic DMC-FZ50 (16:9), RAW: distance 0.31
- Ricoh GXR S10 (12bit (4:3)), DNG: distance 0.30
- Canon EOS R6 Mark III (RAW (3:2)), CR3: distance 0.27
- Canon EOS R6 Mark III (CRAW (3:2)), CR3: distance 0.27
- Minolta DiMAGE 5 (4:3), MRW: distance 0.26 (Apple cannot open it either)
- LG-F800K (10bit (4:3)), DNG: distance 0.24
- Canon EOS D30 (RAW (3:2)), CRW: distance 0.23
- Kodak EOSDCS3C (8bit (4:3)), TIF: distance 0.23
- Sinarback eVolution 75, Sinar p3 / f3 (16bit (4:3)), STI: distance 0.21 (Apple cannot open it either)
- Realme RMX1851 (16bit (4:3)), DNG: distance 0.20
- Panasonic DC-GF10 (16:9), RW2: distance 0.19
- LG-H910 (16bit (4:3)), DNG: distance 0.19
- Blackmagic URSA 4K (12bit (16:9)), DNG: distance 0.18
- Panasonic DMC-LX10 (1:1), RW2: distance 0.17
- YIAC 3 (16bit (4:3)), DNG: distance 0.17
- Leica X2 (12bit (3:2)), DNG: distance 0.17
- Sigma fp (12bit (16:9)), DNG: distance 0.16
- Canon PowerShot SX130 IS (12bit 12bit CHDK ver. 1.5.1 (4:3)), DNG: distance 0.16
- Samsung GX20 (12bit (3:2)), DNG: distance 0.16
- Canon EOS 1000D (RAW (3:2)), CR2: distance 0.16
- Canon PowerShot A3300 IS (12bit 12bit CHDK ver. 1.4.1 (4:3)), DNG: distance 0.16
- Sony DSC-RX1R (14bit 14bit compressed (3:2)), ARW: distance 0.15
