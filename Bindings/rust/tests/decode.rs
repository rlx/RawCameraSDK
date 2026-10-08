//! The decoder on real files: the demo app's samples, if they have been fetched
//! (`Examples/RawInputDemo/Scripts/fetch-samples.sh`). Without them the tests pass
//! without checking anything, and say so.

use std::path::PathBuf;

use rawinput::{Error, RawFile, SensorLayout};

fn sample(name: &str) -> Option<PathBuf> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../Examples/RawInputDemo/Samples/files")
        .join(name);
    if !path.exists() {
        eprintln!("skipped: {name} has not been fetched");
        return None;
    }
    Some(path)
}

#[test]
fn opens_a_bayer_file_and_exposes_what_a_gpu_kernel_needs() {
    let Some(path) = sample("samsung-nx300.srw") else { return };
    let mut file = RawFile::open(&path).unwrap();
    assert_eq!(file.info().make, "Samsung");
    assert!(file.mosaic().is_none(), "nothing to hand out before unpack");

    file.unpack().unwrap();
    let info = file.info();
    assert_eq!(info.layout, SensorLayout::Bayer);
    assert!(info.plain_bayer);

    let mosaic = file.mosaic().expect("a plain Bayer file has a mosaic");
    assert_eq!(mosaic.raw_width, info.raw_width);
    assert!(mosaic.samples.len() >= (info.raw_width * info.raw_height) as usize);

    let params = file.develop_params().expect("and development parameters");
    assert_eq!(params.size, [info.width, info.height]);
    assert!(params.white > params.black.iter().cloned().fold(0.0, f32::max));
    let smallest = params.white_balance[..3].iter().cloned().fold(f32::MAX, f32::min);
    assert!((smallest - 1.0).abs() < 1e-6, "multipliers are scaled so the smallest is 1");
}

#[test]
fn opening_from_memory_matches_opening_from_a_path() {
    let Some(path) = sample("dji-osmo-action.dng") else { return };
    let from_path = RawFile::open(&path).unwrap().info();
    let from_bytes = RawFile::from_bytes(std::fs::read(&path).unwrap()).unwrap().info();
    assert_eq!(from_path, from_bytes);
}

#[test]
fn develops_a_foveon_file_on_the_cpu() {
    // Not a Bayer sensor: no mosaic, and the core's own development is the only path.
    let Some(path) = sample("sigma-dp0-quattro.x3f") else { return };
    let mut file = RawFile::open(&path).unwrap();
    file.unpack().unwrap();
    assert!(!file.info().plain_bayer);
    assert!(file.mosaic().is_none() && file.develop_params().is_none());

    let developed = file.develop_cpu(false).unwrap();
    assert_eq!(developed.channels, 3);
    assert_eq!(developed.pixels.len(), (developed.width * developed.height * 3) as usize);
    assert!(developed.pixels.iter().step_by(997).any(|&v| v > 0), "the picture is not black");
}

#[test]
fn has_an_embedded_preview() {
    let Some(path) = sample("samsung-nx300.srw") else { return };
    let mut file = RawFile::open(&path).unwrap();
    let thumbnail = file.thumbnail().unwrap();
    assert!(thumbnail.is_jpeg);
    assert_eq!(&thumbnail.bytes[..2], &[0xFF, 0xD8], "a JPEG starts with its SOI marker");
}

#[test]
fn refuses_a_frame_over_the_memory_limit() {
    let Some(path) = sample("samsung-nx300.srw") else { return };
    let mut file = RawFile::open(&path).unwrap();
    file.set_memory_limit(1);
    assert_eq!(file.unpack(), Err(Error::TooBig));
}

#[test]
fn rejects_what_is_not_a_raw_file() {
    assert!(matches!(RawFile::from_bytes(vec![0u8; 4096]), Err(Error::Decode { .. })));
    assert!(matches!(RawFile::open("/nonexistent/file.arw"), Err(Error::Decode { .. })));
    assert!(matches!(RawFile::from_bytes(Vec::new()), Err(Error::Decode { .. })));
}

#[test]
fn development_needs_unpacked_data() {
    let Some(path) = sample("samsung-nx300.srw") else { return };
    let mut file = RawFile::open(&path).unwrap();
    assert!(matches!(file.develop_cpu(false), Err(Error::NotUnpacked)));
}
