/*
 * RawShim: the portable core's C interface to LibRaw. The Swift package, the Rust crate and
 * the WebAssembly build in Bindings/ all use this header. See Docs/PORTING.md.
 *
 * This file and RawShim.cpp may use only the C and C++ standard libraries and LibRaw.
 *
 * Lifecycle
 *     rik_open / rik_open_buffer   parse container and metadata, no sensor data read
 *       rik_get_info               identification and exposure fields are valid
 *       rik_get_thumbnail          embedded preview, needs no unpack
 *       rik_storage_mode           how the sensor data is stored, as text
 *     rik_unpack                   decompress the sensor data
 *       rik_get_info               geometry, levels and color fields are now valid
 *       rik_mosaic + rik_get_develop_params
 *                                  the Bayer plane and the inputs for developing it on a GPU
 *       rik_process_rgb16          LibRaw develops on the CPU
 *     rik_close
 *
 * Ownership: returned pointers point into memory owned by the handle and are valid until
 * rik_close.
 * Threading: one thread at a time per handle. Separate handles are independent.
 * Errors: functions that can fail return 0 or a LibRaw error code. No C++ exception leaves
 * this boundary.
 */
#ifndef RAWSHIM_H
#define RAWSHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rik_handle rik_handle;

/* How the sensor samples color, which decides who can develop the file. */
typedef enum {
    RIK_CFA_NONE = 0,   /* full color at every pixel: linear DNG, merged pixel-shift,
                           reduced-size RAW, monochrome sensors */
    RIK_CFA_BAYER = 1,  /* 2x2 mosaic of red, green and blue */
    RIK_CFA_XTRANS = 2, /* Fujifilm's 6x6 mosaic */
    RIK_CFA_OTHER = 3,  /* Foveon, four-color mosaics (CMYG, RGBE) and anything else */
} rik_cfa_kind;

typedef struct {
    /* ---- Identification: valid after rik_open ---------------------------------------- */
    char make[64];
    char model[64];
    char lens[128];
    char decoder[64];   /* LibRaw's decoding routine, e.g. "fuji_compressed_load_raw()" */
    int32_t cfa_kind;   /* rik_cfa_kind */
    int32_t colors;     /* number of color channels in the sensor data */
    uint32_t dng_version; /* 0 unless the container is DNG */

    /* ---- Exposure: valid after rik_open ---------------------------------------------- */
    float iso;
    float shutter;      /* seconds */
    float aperture;     /* f-number */
    float focal_length; /* millimeters */
    int64_t timestamp;  /* seconds since 1970. LibRaw converts the camera's local time with
                           mktime(), so this assumes the host is in the camera's time zone. */

    /* ---- Geometry ---------------------------------------------------------------------
     * `raw_width` x `raw_height` is the whole decoded plane, including masked borders.
     * The picture is the `width` x `height` rectangle at (`left_margin`, `top_margin`).
     * After rik_unpack it includes the camera's own crop. */
    uint32_t raw_width;
    uint32_t raw_height;
    uint32_t width;
    uint32_t height;
    uint32_t left_margin;
    uint32_t top_margin;
    /* Rotation needed for display, as a dcraw flip code: bit 0 mirrors horizontally,
     * bit 1 mirrors vertically, bit 2 swaps rows and columns. 0 = none, 3 = 180 degrees,
     * 5 = 90 degrees counter-clockwise, 6 = 90 degrees clockwise. */
    int32_t flip;

    /* ---- Levels and color: valid after rik_unpack, Bayer files only -------------------
     * Arrays of four are indexed by position in the 2x2 mosaic cell, relative to the top-left
     * pixel of the picture rectangle:  index = (row & 1) * 2 + (column & 1). */
    uint8_t bayer[4];   /* color at each position: 0 red, 1 green, 2 blue */
    float black[4];     /* black level at each position, in raw sample values */
    float white;        /* saturation level, in raw sample values */
    float wb[3];        /* as-shot white balance multipliers for R, G, B; green is 1 */
    float rgb_cam[9];   /* row-major 3x3: white-balanced camera RGB -> linear sRGB */

    /* 1 when a caller can develop the file from `rik_mosaic` and `rik_get_develop_params`.
     * Otherwise use `rik_process_rgb16`. */
    int32_t plain_bayer;
    /* 1 if LibRaw reported corrupt or truncated sensor data while unpacking. Part of the
     * picture is then garbage. */
    int32_t data_errors;
} rik_info;

typedef struct {
    const uint8_t *data;
    size_t length;
    uint32_t width;
    uint32_t height;
    int32_t is_jpeg;    /* 1: `data` is a JPEG stream. 0: tightly packed 8-bit RGB. */
} rik_thumbnail;

typedef struct {
    const uint16_t *pixels; /* interleaved, 16 bits per channel, linear light, not rotated */
    uint32_t width;
    uint32_t height;
    int32_t channels;       /* 3: RGB in the primaries set with rik_set_output_primaries.
                               1: monochrome sensor. */
    size_t row_bytes;
    int32_t is_half_size;   /* 1 if the 2x2-binned result was requested and produced */
} rik_rgb16;

/* Inputs for a GPU kernel developing a plain Bayer mosaic. Uploadable as a uniform buffer:
 * 128 bytes, every field at the offset a shader struct of float4/uint4/uint2 members gives
 * it. The Metal kernel (Sources/RawInputKit/MetalDevelop.swift) and the WGSL kernel
 * (Shaders/develop.wgsl) declare the same fields in the same order.
 *
 * Per-position arrays are indexed (row & 1) * 2 + (column & 1), relative to the picture's
 * top-left pixel. */
typedef struct {
    float black[4];          /* black level at each position, raw sample values */
    float white_balance[4];  /* multiplier for R, G, B (fourth unused); the smallest is 1,
                                so every channel reaches 1 when the sensor saturates */
    float matrix_row0[4];    /* rows of the 3x3 matrix, white-balanced camera RGB to */
    float matrix_row1[4];    /* linear sRGB (fourth element of each unused)          */
    float matrix_row2[4];
    uint32_t pattern[4];     /* color at each position: 0 red, 1 green, 2 blue */
    uint32_t origin[2];      /* picture's top-left corner inside the raw plane: x, y */
    uint32_t size[2];        /* picture size: width, height */
    float white;             /* saturation level, raw sample values */
    uint32_t reserved[3];
} rik_develop_params;

/* Changes when a struct layout or a function's meaning changes. A binding built separately
 * from the core should check it at start-up. */
int rik_abi_version(void);

/* Opens a file and parses its metadata. `*out` is NULL on failure. */
int rik_open(const char *path, rik_handle **out);

/* Opens a file already in memory. The bytes are not copied and must stay valid and
 * unchanged until rik_close. `*out` is NULL on failure. */
int rik_open_buffer(const void *bytes, size_t length, rik_handle **out);

/* Releases the handle and every buffer it handed out. NULL is ignored. */
void rik_close(rik_handle *handle);

/* Caps what rik_unpack may allocate for sensor data, in megabytes. Larger files fail with
 * RIK_TOO_BIG. Call before rik_unpack. */
void rik_set_memory_limit(rik_handle *handle, uint32_t megabytes);

/* Polled during rik_unpack and rik_process_rgb16. A non-zero return abandons the work,
 * which fails with RIK_CANCELLED. `context` is passed back unchanged. */
typedef int (*rik_cancel_callback)(void *context);
void rik_set_cancel_callback(rik_handle *handle, rik_cancel_callback callback, void *context);

/* Error codes callers may need to tell apart. */
extern const int RIK_CANCELLED;
extern const int RIK_TOO_BIG;

/* The primaries rik_process_rgb16 converts to. 16-bit unsigned output cannot hold colors
 * outside its primaries, so sRGB clips part of what a camera records and Rec. 2020 keeps
 * nearly all of it. The default is sRGB. Call before rik_process_rgb16. */
typedef enum {
    RIK_PRIMARIES_SRGB = 0,
    RIK_PRIMARIES_REC2020 = 1,
} rik_primaries;
void rik_set_output_primaries(rik_handle *handle, rik_primaries primaries);

/* Writes a short text naming how the sensor data is stored: the decoding routine, the
 * container's compression code, bits per sample, and the makers' own quality and
 * compression fields. Two files from one camera with the same text were recorded in the
 * same mode. Valid after rik_open. Always NUL-terminated. */
void rik_storage_mode(rik_handle *handle, char *out, size_t capacity);

/* Fills `info` from the handle's current state. The struct says what is valid when. */
void rik_get_info(rik_handle *handle, rik_info *info);

/* The largest embedded preview. Does not require rik_unpack. */
int rik_get_thumbnail(rik_handle *handle, rik_thumbnail *out);

/* Decompresses the sensor data. Safe to call more than once. */
int rik_unpack(rik_handle *handle);

/* The raw Bayer plane: `raw_width` x `raw_height` samples, rows `*row_bytes` apart.
 * Returns NULL unless `rik_info.plain_bayer` is 1. */
const uint16_t *rik_mosaic(rik_handle *handle, size_t *row_bytes);

/* Fills in the parameters for developing that plane. Returns non-zero, and leaves `out`
 * zeroed, unless `rik_info.plain_bayer` is 1. */
int rik_get_develop_params(rik_handle *handle, rik_develop_params *out);

/* LibRaw's CPU development: demosaic, white balance and color conversion, with no tone
 * curve, auto-brightness or rotation, in the primaries set with rik_set_output_primaries.
 * Works for every file the core can decode.
 * `half_size` asks for a 2x2-binned result, which LibRaw does for mosaic sensors only.
 * Check `is_half_size`. The first call fixes the result for later calls. */
int rik_process_rgb16(rik_handle *handle, int half_size, rik_rgb16 *out);

const char *rik_strerror(int code);
const char *rik_libraw_version(void);
int rik_camera_count(void);

#ifdef __cplusplus
}
#endif

#endif
