//! Camera RAW decoding for Rust, on the same portable core as the Swift package.
//!
//! ```no_run
//! let mut file = rawinput::RawFile::open("photo.arw")?;
//! println!("{} {}", file.info().make, file.info().model);
//! file.unpack()?;
//! let developed = file.develop_cpu(false)?; // works for every file the core can decode
//! # Ok::<(), rawinput::Error>(())
//! ```
//!
//! What this crate is, and is not. It wraps the core's C interface in safe types: the handle
//! is closed on drop, and every buffer the core owns is exposed as a borrow that cannot
//! outlive the file. It does not include Apple's decoder, which only exists on Apple
//! platforms and is the Swift package's first choice there; on other platforms the core's
//! own decoding is all there is.
//!
//! With the `gpu` feature, [`gpu::Developer`] runs the development kernel (`develop.wgsl`)
//! through wgpu for plain Bayer files, which is most cameras.

use std::ffi::{CStr, CString};
use std::path::Path;

#[cfg(feature = "gpu")]
pub mod gpu;
mod sys;

pub use sys::DevelopParams;

#[derive(Debug, Clone, PartialEq)]
pub enum Error {
    /// The core was built from a different version of the interface than this crate.
    AbiMismatch { core: i32, expected: i32 },
    /// The file could not be opened or decoded. `code` is the decoder's own status.
    Decode { code: i32, reason: String },
    /// The sensor data is truncated or corrupt; part of the picture would be garbage.
    CorruptData,
    /// Decoding would need more memory than the limit set with `set_memory_limit`.
    TooBig,
    /// The call needs `unpack` to have succeeded first.
    NotUnpacked,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::AbiMismatch { core, expected } => {
                write!(f, "the core speaks interface version {core}, this crate expects {expected}")
            }
            Error::Decode { code, reason } => write!(f, "{reason} ({code})"),
            Error::CorruptData => write!(f, "the file's image data is truncated or corrupt"),
            Error::TooBig => write!(f, "the file needs more memory than the limit allows"),
            Error::NotUnpacked => write!(f, "call unpack() first"),
        }
    }
}

impl std::error::Error for Error {}

fn check(code: i32) -> Result<(), Error> {
    if code == 0 {
        return Ok(());
    }
    if code == unsafe { sys::RIK_TOO_BIG } {
        return Err(Error::TooBig);
    }
    let reason = unsafe { CStr::from_ptr(sys::rik_strerror(code)) }.to_string_lossy().into_owned();
    Err(Error::Decode { code, reason })
}

/// How the sensor samples colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SensorLayout {
    /// Full colour at every pixel: linear DNG, merged pixel-shift, monochrome sensors.
    FullColor,
    /// The usual 2x2 mosaic of red, green and blue.
    Bayer,
    /// Fujifilm's 6x6 mosaic.
    XTrans,
    /// Foveon, four-colour mosaics and anything else.
    Other,
}

/// What a RAW file says about itself. Geometry is only final after `unpack`.
#[derive(Debug, Clone, PartialEq)]
pub struct Info {
    pub make: String,
    pub model: String,
    pub lens: String,
    /// The decoder's routine for this file: in effect, its compression scheme.
    pub decoder: String,
    pub layout: SensorLayout,
    /// Size of the picture, before `flip` is applied.
    pub width: u32,
    pub height: u32,
    /// Size of the whole decoded plane, masked borders included.
    pub raw_width: u32,
    pub raw_height: u32,
    /// Rotation needed for display, as a dcraw flip code: 0 none, 3 is 180 degrees,
    /// 5 is 90 degrees counter-clockwise, 6 is 90 degrees clockwise.
    pub flip: i32,
    pub iso: f32,
    pub shutter_seconds: f32,
    pub aperture: f32,
    pub focal_length_mm: f32,
    /// True when the file is a plain Bayer mosaic a GPU kernel can develop from
    /// `mosaic()` and `develop_params()`. Meaningful after `unpack`.
    pub plain_bayer: bool,
}

/// An embedded preview: a JPEG stream, or tightly packed 8-bit RGB.
pub struct Thumbnail<'a> {
    pub bytes: &'a [u8],
    pub width: u32,
    pub height: u32,
    pub is_jpeg: bool,
}

/// The raw Bayer plane, borrowed from the file.
pub struct Mosaic<'a> {
    /// `raw_width` samples per row, `row_stride` samples from one row to the next.
    pub samples: &'a [u16],
    pub raw_width: u32,
    pub raw_height: u32,
    pub row_stride: usize,
}

/// The core's CPU development: linear, 16 bits per channel, not rotated.
pub struct Developed<'a> {
    /// Interleaved, `channels` per pixel: 3 is RGB with sRGB primaries, 1 is a monochrome sensor.
    pub pixels: &'a [u16],
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub is_half_size: bool,
}

/// A RAW file opened by the core. Closed when dropped.
///
/// Not `Sync`: one file is used from one thread at a time. Separate files are independent.
pub struct RawFile {
    handle: *mut sys::Handle,
    unpacked: bool,
    /// When opened from memory the core reads from these bytes for as long as it lives, so
    /// the file owns them. Declared after `handle` and dropped after it in `Drop`.
    _bytes: Option<Vec<u8>>,
}

// The handle is owned and has no thread affinity; it may move between threads.
unsafe impl Send for RawFile {}

impl RawFile {
    fn check_abi() -> Result<(), Error> {
        let core = unsafe { sys::rik_abi_version() };
        if core == sys::ABI_VERSION {
            Ok(())
        } else {
            Err(Error::AbiMismatch { core, expected: sys::ABI_VERSION })
        }
    }

    /// Parses the container and metadata. Cheap; no sensor data is read.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, Error> {
        Self::check_abi()?;
        let path = CString::new(path.as_ref().to_string_lossy().as_bytes())
            .map_err(|_| Error::Decode { code: -1, reason: "the path contains a NUL byte".into() })?;
        let mut handle = std::ptr::null_mut();
        check(unsafe { sys::rik_open(path.as_ptr(), &mut handle) })?;
        Ok(Self { handle, unpacked: false, _bytes: None })
    }

    /// The same, for a file already in memory.
    pub fn from_bytes(bytes: Vec<u8>) -> Result<Self, Error> {
        Self::check_abi()?;
        let mut handle = std::ptr::null_mut();
        // The Vec's heap buffer does not move when the Vec itself is moved into the struct.
        check(unsafe { sys::rik_open_buffer(bytes.as_ptr().cast(), bytes.len(), &mut handle) })?;
        Ok(Self { handle, unpacked: false, _bytes: Some(bytes) })
    }

    /// Refuses files whose sensor data would need more than this to decode. A frame's size
    /// comes from the file, so without a limit a damaged header can ask for gigabytes.
    pub fn set_memory_limit(&mut self, megabytes: u32) {
        unsafe { sys::rik_set_memory_limit(self.handle, megabytes) }
    }

    pub fn info(&self) -> Info {
        let mut raw = std::mem::MaybeUninit::<sys::Info>::zeroed();
        let raw = unsafe {
            sys::rik_get_info(self.handle, raw.as_mut_ptr());
            raw.assume_init()
        };
        let text = |field: &[std::ffi::c_char]| {
            unsafe { CStr::from_ptr(field.as_ptr()) }.to_string_lossy().trim().to_owned()
        };
        Info {
            make: text(&raw.make),
            model: text(&raw.model),
            lens: text(&raw.lens),
            decoder: text(&raw.decoder),
            layout: match raw.cfa_kind {
                0 => SensorLayout::FullColor,
                1 => SensorLayout::Bayer,
                2 => SensorLayout::XTrans,
                _ => SensorLayout::Other,
            },
            width: raw.width,
            height: raw.height,
            raw_width: raw.raw_width,
            raw_height: raw.raw_height,
            flip: raw.flip,
            iso: raw.iso,
            shutter_seconds: raw.shutter,
            aperture: raw.aperture,
            focal_length_mm: raw.focal_length,
            plain_bayer: raw.plain_bayer == 1,
        }
    }

    /// The largest embedded preview. Does not need `unpack`.
    pub fn thumbnail(&mut self) -> Result<Thumbnail<'_>, Error> {
        let mut raw = std::mem::MaybeUninit::<sys::Thumbnail>::zeroed();
        check(unsafe { sys::rik_get_thumbnail(self.handle, raw.as_mut_ptr()) })?;
        let raw = unsafe { raw.assume_init() };
        Ok(Thumbnail {
            // The buffer lives until the handle closes; the borrow of `self` keeps it shorter.
            bytes: unsafe { std::slice::from_raw_parts(raw.data, raw.length) },
            width: raw.width,
            height: raw.height,
            is_jpeg: raw.is_jpeg == 1,
        })
    }

    /// Decompresses the sensor data: the expensive step.
    pub fn unpack(&mut self) -> Result<(), Error> {
        check(unsafe { sys::rik_unpack(self.handle) })?;
        let mut raw = std::mem::MaybeUninit::<sys::Info>::zeroed();
        let errors = unsafe {
            sys::rik_get_info(self.handle, raw.as_mut_ptr());
            raw.assume_init().data_errors
        };
        // The decoder keeps going past truncated data and fills the rest with whatever its
        // state yields. A picture that is partly noise is worse than an error.
        if errors != 0 {
            return Err(Error::CorruptData);
        }
        self.unpacked = true;
        Ok(())
    }

    /// The raw Bayer plane, or `None` if the file is not a plain Bayer mosaic.
    pub fn mosaic(&self) -> Option<Mosaic<'_>> {
        if !self.unpacked {
            return None;
        }
        let mut row_bytes = 0usize;
        let samples = unsafe { sys::rik_mosaic(self.handle, &mut row_bytes) };
        if samples.is_null() {
            return None;
        }
        let info = self.info();
        let row_stride = row_bytes / std::mem::size_of::<u16>();
        Some(Mosaic {
            samples: unsafe { std::slice::from_raw_parts(samples, row_stride * info.raw_height as usize) },
            raw_width: info.raw_width,
            raw_height: info.raw_height,
            row_stride,
        })
    }

    /// What a GPU kernel needs to develop the mosaic, or `None` if the file is not a plain
    /// Bayer mosaic. The struct is the kernel's uniform block as it is.
    pub fn develop_params(&self) -> Option<DevelopParams> {
        let mut params = DevelopParams::default();
        (unsafe { sys::rik_get_develop_params(self.handle, &mut params) } == 0).then_some(params)
    }

    /// The core's own development on the CPU. Works for every file the core can decode,
    /// and is the only way to develop one that is not a plain Bayer mosaic. Slow: seconds
    /// for the largest files.
    pub fn develop_cpu(&mut self, half_size: bool) -> Result<Developed<'_>, Error> {
        if !self.unpacked {
            return Err(Error::NotUnpacked);
        }
        let mut raw = std::mem::MaybeUninit::<sys::Rgb16>::zeroed();
        check(unsafe { sys::rik_process_rgb16(self.handle, half_size as i32, raw.as_mut_ptr()) })?;
        let raw = unsafe { raw.assume_init() };
        let count = raw.width as usize * raw.height as usize * raw.channels as usize;
        Ok(Developed {
            pixels: unsafe { std::slice::from_raw_parts(raw.pixels, count) },
            width: raw.width,
            height: raw.height,
            channels: raw.channels as u32,
            is_half_size: raw.is_half_size == 1,
        })
    }
}

impl Drop for RawFile {
    fn drop(&mut self) {
        // Closed here, before `_bytes` is freed: the core may still read from them.
        unsafe { sys::rik_close(self.handle) }
    }
}

/// The decoder library's version, for logs and for anything that must stay reproducible.
pub fn core_version() -> String {
    unsafe { CStr::from_ptr(sys::rik_libraw_version()) }.to_string_lossy().into_owned()
}
