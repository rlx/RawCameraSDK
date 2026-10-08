/*
 * RawShim — the C boundary between RawInputKit and LibRaw.
 *
 * Why this exists
 * ---------------
 * LibRaw is a C++ library with a very wide surface. Everything the Swift side needs from it
 * is narrowed here to a handful of C functions and plain structs, for three reasons:
 *
 *   1. Swift never has to import C++, so the public Swift API cannot leak LibRaw types.
 *   2. The same header can be bound from Rust, Kotlin/JNI or plain C if the decoder core is
 *      ever reused outside Apple platforms.
 *   3. LibRaw's quirks (which field means what, in which state) are dealt with once, in
 *      RawShim.cpp, instead of in every caller.
 *
 * Lifecycle
 * ---------
 *     rik_open            parse the container and metadata; cheap, no sensor data read
 *       rik_get_info      valid now for identification and exposure fields
 *       rik_get_thumbnail embedded preview, independent of unpacking
 *     rik_unpack          decompress the sensor data; the expensive step
 *       rik_get_info      now also valid for geometry, levels and colour fields
 *       rik_mosaic        the Bayer plane, for callers that develop it themselves
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
 * turns a code into text.
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

    /* 1 when `rik_mosaic` returns a plane the caller can develop with nothing more than
     * the fields above. 0 for every other layout and for sensors that need corrections
     * only LibRaw applies; those go through `rik_process_rgb16`. */
    int32_t metal_ready;
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

/* Opens a file and parses its metadata. `*out` is NULL on failure. */
int rik_open(const char *path, rik_handle **out);

/* Releases the handle and every buffer it handed out. NULL is ignored. */
void rik_close(rik_handle *handle);

/* Fills `info` from the handle's current state; see the struct for what is valid when. */
void rik_get_info(rik_handle *handle, rik_info *info);

/* The largest embedded preview. Does not require rik_unpack. */
int rik_get_thumbnail(rik_handle *handle, rik_thumbnail *out);

/* Decompresses the sensor data. Safe to call more than once. */
int rik_unpack(rik_handle *handle);

/* The raw Bayer plane: `raw_width` x `raw_height` samples, rows `*row_bytes` apart.
 * Returns NULL unless `rik_info.metal_ready` is 1. */
const uint16_t *rik_mosaic(rik_handle *handle, size_t *row_bytes);

/* LibRaw's own development: demosaic, white balance and colour conversion on the CPU,
 * with no tone curve, no auto-brightness and no rotation. Used for everything that is not
 * `metal_ready`. `half_size` asks for a 2x2-binned result; LibRaw can only do that for
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
