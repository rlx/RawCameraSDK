//! The C interface, declared by hand from `Sources/RawShim/include/RawShim.h`.
//!
//! It is small enough that a generator would add a build dependency for little gain. The
//! cost is that a change to the header has to be made here too; `ABI_VERSION` and the size
//! assertions below are what catch a mismatch.

use std::ffi::{c_char, c_int, c_void};

/// The interface version these declarations were written against.
pub const ABI_VERSION: c_int = 1;

#[repr(C)]
pub struct Handle {
    _private: [u8; 0],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Info {
    pub make: [c_char; 64],
    pub model: [c_char; 64],
    pub lens: [c_char; 128],
    pub decoder: [c_char; 64],
    pub cfa_kind: i32,
    pub colors: i32,
    pub dng_version: u32,
    pub iso: f32,
    pub shutter: f32,
    pub aperture: f32,
    pub focal_length: f32,
    pub timestamp: i64,
    pub raw_width: u32,
    pub raw_height: u32,
    pub width: u32,
    pub height: u32,
    pub left_margin: u32,
    pub top_margin: u32,
    pub flip: i32,
    pub bayer: [u8; 4],
    pub black: [f32; 4],
    pub white: f32,
    pub wb: [f32; 3],
    pub rgb_cam: [f32; 9],
    pub plain_bayer: i32,
    pub data_errors: i32,
}

/// The development kernel's uniform block, byte for byte.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct DevelopParams {
    pub black: [f32; 4],
    pub white_balance: [f32; 4],
    pub matrix_row0: [f32; 4],
    pub matrix_row1: [f32; 4],
    pub matrix_row2: [f32; 4],
    pub pattern: [u32; 4],
    pub origin: [u32; 2],
    pub size: [u32; 2],
    pub white: f32,
    pub reserved: [u32; 3],
}

const _: () = assert!(std::mem::size_of::<DevelopParams>() == 128);

#[repr(C)]
pub struct Thumbnail {
    pub data: *const u8,
    pub length: usize,
    pub width: u32,
    pub height: u32,
    pub is_jpeg: i32,
}

#[repr(C)]
pub struct Rgb16 {
    pub pixels: *const u16,
    pub width: u32,
    pub height: u32,
    pub channels: i32,
    pub row_bytes: usize,
    pub is_half_size: i32,
}

extern "C" {
    pub static RIK_TOO_BIG: c_int;

    pub fn rik_abi_version() -> c_int;
    pub fn rik_open(path: *const c_char, out: *mut *mut Handle) -> c_int;
    pub fn rik_open_buffer(bytes: *const c_void, length: usize, out: *mut *mut Handle) -> c_int;
    pub fn rik_close(handle: *mut Handle);
    pub fn rik_set_memory_limit(handle: *mut Handle, megabytes: u32);
    pub fn rik_get_info(handle: *mut Handle, info: *mut Info);
    pub fn rik_get_thumbnail(handle: *mut Handle, out: *mut Thumbnail) -> c_int;
    pub fn rik_unpack(handle: *mut Handle) -> c_int;
    pub fn rik_mosaic(handle: *mut Handle, row_bytes: *mut usize) -> *const u16;
    pub fn rik_get_develop_params(handle: *mut Handle, out: *mut DevelopParams) -> c_int;
    pub fn rik_process_rgb16(handle: *mut Handle, half_size: c_int, out: *mut Rgb16) -> c_int;
    pub fn rik_strerror(code: c_int) -> *const c_char;
    pub fn rik_libraw_version() -> *const c_char;
}
