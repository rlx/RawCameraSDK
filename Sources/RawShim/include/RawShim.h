/*
 * RawShim: the portable core's C interface.
 *
 * Why this exists
 * ---------------
 * LibRaw is a C++ library with a very wide surface. Everything a caller needs from it is
 * narrowed here to a handful of C functions and plain structs, for three reasons:
 *
 *   1. One interface serves every host. The Swift package, the Rust crate and the
 *      WebAssembly build in Bindings/ all sit on this header and nothing else.
 *   2. No caller has to understand C++ or LibRaw's types.
 *   3. LibRaw's quirks (which field means what, in which state) are dealt with once, in
 *      RawShim.cpp, instead of in every binding.
 *
 * This file and RawShim.cpp use only the C and C++ standard libraries and LibRaw. Nothing
 * in them may depend on an operating system or a GPU API; that is what keeps the core
 * buildable for Rust and for the web. Docs/PORTING.md describes the bindings.
 *
 * Compatibility
 * -------------
 * `rik_abi_version` changes whenever a struct's layout or a function's meaning does. A
 * binding built separately from the core should check it once at start-up.
 *
 * Lifecycle
 * ---------
 *     rik_open /
 *     rik_open_buffer     parse the container and metadata; cheap, no sensor data read
 *       rik_get_info      valid now for identification and exposure fields
 *       rik_get_thumbnail embedded preview, independent of unpacking
 *     rik_unpack          decompress the sensor data; the expensive step
 *       rik_get_info      now also valid for geometry, levels and colour fields
 *       rik_mosaic +
 *       rik_get_develop_params
 *                         the Bayer plane and everything needed to develop it on a GPU
 *       rik_process_rgb16 or let LibRaw develop it on the CPU
 *     rik_close
 *
 * Ownership
 * ---------
 * Every pointer returned through this header points into memory owned by the handle and
 * is valid until `rik_close`. Callers copy what they need to keep.
 *
 * Threading
 * ---------
 * A handle must be used by one thread at a time. Separate handles are independent, so
 * decoding several files in parallel is safe.
 *
 * Errors
 * ------
 * Functions that can fail return 0 on success or a LibRaw error code; `rik_strerror`
 * turns a code into text. No C++ exception leaves this boundary.
 */
#ifndef RAWSHIM_H
#define RAWSHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rik_handle rik_handle;

/* How the sensor samples colour, which decides who can develop the file. */
typedef enum {
    RIK_CFA_NONE = 0,   /* full colour at every pixel: linear DNG, merged pixel-shift,
                           reduced-size RAW, monochrome sensors */
    RIK_CFA_BAYER = 1,  /* 2x2 mosaic of red, green and blue */
    RIK_CFA_XTRANS = 2, /* Fujifilm's 6x6 mosaic */
    RIK_CFA_OTHER = 3,  /* Foveon, four-colour mosaics (CMYG, RGBE) and anything else */
} rik_cfa_kind;

typedef struct {
    /* ---- Identification: valid after rik_open ---------------------------------------- */
    char make[64];
    char model[64];
    char lens[128];
    char decoder[64];   /* LibRaw's decoding routine, e.g. "fuji_compressed_load_raw()".
                           The most precise description of the compression available. */
    int32_t cfa_kind;   /* rik_cfa_kind */
    int32_t colors;     /* number of colour channels in the sensor data */
    uint32_t dng_version; /* 0 unless the container is DNG */

    /* ---- Exposure: valid after rik_open ---------------------------------------------- */
    float iso;
    float shutter;      /* seconds */
    float aperture;     /* f-number */
    float focal_length; /* millimetres */
    int64_t timestamp;  /* seconds since 1970. LibRaw converts the camera's local time with
                           mktime(), so this assumes the host is in the camera's time zone. */

    /* ---- Geometry ---------------------------------------------------------------------
     * `raw_width` x `raw_height` is the whole decoded plane, including masked borders.
     * The picture is the `width` x `height` rectangle at (`left_margin`, `top_margin`).
     * After rik_unpack that rectangle includes the camera's own crop (in-camera aspect
     * ratio, default crop), so it matches what the camera's JPEG shows. */
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

    /* ---- Levels and colour: valid after rik_unpack, Bayer files only -------------------
     * Arrays of four are indexed by position in the 2x2 mosaic cell, relative to the top-left
     * pixel of the picture rectangle:  index = (row & 1) * 2 + (column & 1). */
    uint8_t bayer[4];   /* colour at each position: 0 red, 1 green, 2 blue */
    float black[4];     /* black level at each position, in raw sample values */
    float white;        /* saturation level, in raw sample values */
    float wb[3];        /* as-shot white balance multipliers for R, G, B; green is 1 */
    float rgb_cam[9];   /* row-major 3x3: white-balanced camera RGB -> linear sRGB */

    /* 1 when the file is a plain Bayer mosaic that a caller can develop itself from
     * `rik_mosaic` and `rik_get_develop_params`. 0 for every other layout and for sensors
     * that need corrections only LibRaw applies; those go through `rik_process_rgb16`. */
    int32_t plain_bayer;
    /* 1 if LibRaw reported corrupt or truncated sensor data while unpacking. The decode
     * still "succeeds", but part of the picture is garbage. */
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
    int32_t channels;       /* 3: RGB with sRGB primaries. 1: monochrome sensor. */
    size_t row_bytes;
    int32_t is_half_size;   /* 1 if the 2x2-binned result was requested and produced */
} rik_rgb16;

/* What a GPU kernel needs to develop a plain Bayer mosaic, laid out so the struct can be
 * uploaded as a uniform buffer as it is: 128 bytes, every field at the offset a shader
 * struct of float4/uint4/uint2 members gives it. The kernels in this repository (Metal in
 * Sources/RawInputKit/MetalDevelop.swift, WGSL in Shaders/develop.wgsl) declare the same
 * fields in the same order.
 *
 * Per-position arrays are indexed by position in the 2x2 mosaic cell relative to the
 * picture's top-left pixel: (row & 1) * 2 + (column & 1). */
typedef struct {
    float black[4];          /* black level at each position, raw sample values */
    float white_balance[4];  /* multiplier for R, G, B (fourth unused); the smallest is 1,
                                so every channel reaches 1 when the sensor saturates */
    float matrix_row0[4];    /* rows of the 3x3 matrix, white-balanced camera RGB to */
    float matrix_row1[4];    /* linear sRGB (fourth element of each unused)          */
    float matrix_row2[4];
    uint32_t pattern[4];     /* colour at each position: 0 red, 1 green, 2 blue */
    uint32_t origin[2];      /* picture's top-left corner inside the raw plane: x, y */
    uint32_t size[2];        /* picture size: width, height */
    float white;             /* saturation level, raw sample values */
    uint32_t reserved[3];
} rik_develop_params;

/* Incremented when anything in this header changes shape or meaning. */
int rik_abi_version(void);

/* Opens a file and parses its metadata. `*out` is NULL on failure. */
int rik_open(const char *path, rik_handle **out);

/* The same, for a file already in memory: the only way in on a platform without a file
 * system, such as a browser. The bytes are not copied and must stay valid and unchanged
 * until rik_close. */
int rik_open_buffer(const void *bytes, size_t length, rik_handle **out);

/* Releases the handle and every buffer it handed out. NULL is ignored. */
void rik_close(rik_handle *handle);

/* Caps what rik_unpack may allocate for sensor data, in megabytes. A file whose header
 * asks for more is refused with RIK_TOO_BIG instead of being allowed to exhaust memory.
 * Call before rik_unpack. */
void rik_set_memory_limit(rik_handle *handle, uint32_t megabytes);

/* Polled during rik_unpack and rik_process_rgb16; return non-zero to abandon the work,
 * which then fails with RIK_CANCELLED. `context` is passed back unchanged. */
typedef int (*rik_cancel_callback)(void *context);
void rik_set_cancel_callback(rik_handle *handle, rik_cancel_callback callback, void *context);

/* Error codes a caller may want to tell apart from the rest. */
extern const int RIK_CANCELLED;
extern const int RIK_TOO_BIG;

/* Fills `info` from the handle's current state; see the struct for what is valid when. */
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

/* LibRaw's own development: demosaic, white balance and colour conversion on the CPU,
 * with no tone curve, no auto-brightness and no rotation. It works for every file the core
 * can decode, and is the only way to develop one that is not `plain_bayer`. `half_size` asks for a 2x2-binned result; LibRaw can only do that for
 * mosaic sensors, so check `is_half_size` on the way out. The first call fixes the result;
 * later calls return the same image whatever `half_size` says. */
int rik_process_rgb16(rik_handle *handle, int half_size, rik_rgb16 *out);

const char *rik_strerror(int code);
const char *rik_libraw_version(void);
int rik_camera_count(void);

#ifdef __cplusplus
}
#endif

#endif
