/* The WebAssembly build's entry points.
 *
 * Calls that return structs are wrapped so JavaScript needs no struct layouts. Text comes
 * back as JSON, numbers through rikw_result().
 */
#include <stdio.h>
#include <string.h>

#include "RawShim.h"

static double results[8];

/* The numbers left by the last rikw_* call. Pointers are offsets into the module's memory. */
double rikw_result(int index) { return index >= 0 && index < 8 ? results[index] : 0; }

/* Appends a JSON string, escaping the two characters that can break one. Anything below a
 * space is dropped. */
static size_t append_string(char *out, size_t at, size_t capacity, const char *text) {
    if (at + 1 < capacity)
        out[at++] = '"';
    for (; *text && at + 3 < capacity; text++) {
        if (*text == '"' || *text == '\\')
            out[at++] = '\\';
        if ((unsigned char)*text >= 0x20)
            out[at++] = *text;
    }
    if (at + 1 < capacity)
        out[at++] = '"';
    return at;
}

/* The file's metadata as a JSON object. The text is valid until the next call. */
const char *rikw_info_json(rik_handle *handle) {
    static char json[1024];
    rik_info info;
    rik_get_info(handle, &info);

    size_t at = 0;
    at += (size_t)snprintf(json + at, sizeof(json) - at, "{\"make\":");
    at = append_string(json, at, sizeof(json), info.make);
    at += (size_t)snprintf(json + at, sizeof(json) - at, ",\"model\":");
    at = append_string(json, at, sizeof(json), info.model);
    at += (size_t)snprintf(json + at, sizeof(json) - at, ",\"lens\":");
    at = append_string(json, at, sizeof(json), info.lens);
    at += (size_t)snprintf(json + at, sizeof(json) - at, ",\"decoder\":");
    at = append_string(json, at, sizeof(json), info.decoder);
    static const char *layouts[] = {"fullColor", "bayer", "xTrans", "other"};
    snprintf(json + at, sizeof(json) - at,
             ",\"layout\":\"%s\",\"width\":%u,\"height\":%u,\"rawWidth\":%u,\"rawHeight\":%u,\"flip\":%d,"
             "\"iso\":%g,\"shutterSeconds\":%g,\"aperture\":%g,\"focalLengthMM\":%g,\"plainBayer\":%s,"
             "\"dataErrors\":%s}",
             layouts[info.cfa_kind >= 0 && info.cfa_kind <= 3 ? info.cfa_kind : 3], info.width, info.height,
             info.raw_width, info.raw_height, info.flip, info.iso, info.shutter, info.aperture, info.focal_length,
             info.plain_bayer ? "true" : "false", info.data_errors ? "true" : "false");
    return json;
}

/* Results: pointer, byte length, width, height, 1 if JPEG. */
int rikw_thumbnail(rik_handle *handle) {
    rik_thumbnail thumbnail;
    int code = rik_get_thumbnail(handle, &thumbnail);
    if (code == 0) {
        results[0] = (double)(size_t)thumbnail.data;
        results[1] = (double)thumbnail.length;
        results[2] = thumbnail.width;
        results[3] = thumbnail.height;
        results[4] = thumbnail.is_jpeg;
    }
    return code;
}

/* Results: pointer to the raw Bayer plane (0 if the file is not a plain Bayer mosaic) and
 * the distance between rows in bytes. */
void rikw_mosaic(rik_handle *handle) {
    size_t row_bytes = 0;
    results[0] = (double)(size_t)rik_mosaic(handle, &row_bytes);
    results[1] = (double)row_bytes;
}

/* The core's CPU development. Results: pointer, width, height, channels, 1 if half size. */
int rikw_develop(rik_handle *handle, int half_size) {
    rik_rgb16 developed;
    int code = rik_process_rgb16(handle, half_size, &developed);
    if (code == 0) {
        results[0] = (double)(size_t)developed.pixels;
        results[1] = developed.width;
        results[2] = developed.height;
        results[3] = developed.channels;
        results[4] = developed.is_half_size;
    }
    return code;
}
