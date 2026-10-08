// Implements RawShim.h, which documents lifecycle, ownership and threading.
//
// LibRaw keeps one mutable struct (`imgdata`). unpack() finalises black levels but leaves
// the nominal white level. dcraw_process() overwrites width, height and flip. Anything the
// caller may ask for after processing is captured in rik_unpack.

#include "RawShim.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>

#include "libraw/libraw.h"

struct rik_handle {
    LibRaw raw;
    libraw_processed_image_t *processed = nullptr;
    bool unpacked = false;
    bool data_errors = false;
    bool half_size_applied = false;

    // Captured in rik_unpack.
    int flip = 0;
    float white = 0;
    uint8_t bayer[4] = {};
    float black[4] = {};
    bool plain_bayer = false;

    rik_cancel_callback cancel = nullptr;
    void *cancel_context = nullptr;
};

const int RIK_CANCELLED = LIBRAW_CANCELLED_BY_CALLBACK;
const int RIK_TOO_BIG = LIBRAW_TOO_BIG;

namespace {

// Smallest picture the GPU kernel's border mirroring is defined for.
constexpr unsigned kMinimumSide = 4;

void copy_string(char *dst, size_t capacity, const char *src) {
    if (!src) {
        dst[0] = 0;
        return;
    }
    std::strncpy(dst, src, capacity - 1);
    dst[capacity - 1] = 0;
}

int cfa_kind(const libraw_iparams_t &id) {
    if (id.filters == 0)
        return id.is_foveon ? RIK_CFA_OTHER : RIK_CFA_NONE;
    if (id.filters == 9)
        return RIK_CFA_XTRANS;
    if (id.filters < 1000)
        return RIK_CFA_OTHER;
    // Plain Bayer is three colours, or four with the second green listed separately ("RGBG").
    bool rgb = id.colors == 3 || (id.colors == 4 && id.cdesc[3] == 'G');
    return rgb ? RIK_CFA_BAYER : RIK_CFA_OTHER;
}

// Stops anything `body` throws from unwinding through a C function into the caller.
template <typename Body> int guarded(Body body) {
    try {
        return body();
    } catch (const std::bad_alloc &) {
        return LIBRAW_UNSUFFICIENT_MEMORY;
    } catch (...) {
        return LIBRAW_UNSPECIFIED_ERROR;
    }
}

// LibRaw stops if this returns non-zero.
int on_progress(void *context, enum LibRaw_progress, int, int) {
    rik_handle *handle = static_cast<rik_handle *>(context);
    return handle->cancel && handle->cancel(handle->cancel_context) ? 1 : 0;
}

// Replaces LibRaw's default handler, which prints to stderr.
void on_data_error(void *context, const char *, const INT64) {
    static_cast<rik_handle *>(context)->data_errors = true;
}

// Narrows the picture rectangle to the camera's own crop, which LibRaw parses but does not
// apply. The origin stays on the same mosaic phase as the original margins.
// X-Trans is skipped: LibRaw's tables are tied to the original origin.
void apply_camera_crop(LibRaw &raw) {
    libraw_image_sizes_t &sizes = raw.imgdata.sizes;
    if (raw.imgdata.idata.filters == 9)
        return;
    const int left = sizes.left_margin, top = sizes.top_margin;

    // Mask 3 considers both crops LibRaw knows about and prefers the aspect-ratio one.
    if (raw.adjust_to_raw_inset_crop(3) == 0)
        return;

    auto realign = [](ushort &margin, ushort &extent, int original) {
        if ((margin - original) % 2 != 0 && extent > 1) {
            margin += 1;
            extent -= 1;
        }
    };
    realign(sizes.left_margin, sizes.width, left);
    realign(sizes.top_margin, sizes.height, top);
    // dcraw_process() restores its geometry from this second copy.
    raw.imgdata.rawdata.sizes.left_margin = sizes.left_margin;
    raw.imgdata.rawdata.sizes.top_margin = sizes.top_margin;
    raw.imgdata.rawdata.sizes.width = sizes.width;
    raw.imgdata.rawdata.sizes.height = sizes.height;
}

// The level at which the sensor clips. `color.maximum` is nominal and many cameras saturate
// below it, which gives magenta highlights. LibRaw's rule: use the brightest sample when it
// is below the nominal maximum and above 75% of it.
float effective_white(const libraw_data_t &d) {
    const libraw_image_sizes_t &s = d.sizes;
    const ushort *plane = d.rawdata.raw_image;
    const size_t stride = s.raw_pitch / sizeof(ushort);
    ushort brightest = 0;
    for (unsigned row = 0; row < s.height; row++) {
        const ushort *samples = plane + (size_t)(row + s.top_margin) * stride + s.left_margin;
        brightest = std::max(brightest, *std::max_element(samples, samples + s.width));
    }
    const float nominal = (float)d.color.maximum;
    return brightest < nominal && brightest > nominal * 0.75f ? (float)brightest : nominal;
}

// Decides whether the caller can develop the plane itself. Each condition is an assumption
// of the GPU kernel in MetalDevelop.swift.
void capture_bayer_state(rik_handle *handle) {
    LibRaw &raw = handle->raw;
    const libraw_data_t &d = raw.imgdata;
    const libraw_image_sizes_t &s = d.sizes;
    const libraw_colordata_t &color = d.color;

    bool geometry_ok = d.rawdata.raw_image != nullptr &&
                       s.width >= kMinimumSide && s.height >= kMinimumSide &&
                       (unsigned)s.left_margin + s.width <= s.raw_width &&
                       (unsigned)s.top_margin + s.height <= s.raw_height &&
                       s.raw_pitch >= (unsigned)s.raw_width * sizeof(ushort);
    if (cfa_kind(d.idata) != RIK_CFA_BAYER || !geometry_ok)
        return;

    float highest_black = 0;
    for (int position = 0; position < 4; position++) {
        const int row = position >> 1, col = position & 1;
        // COLOR() is relative to the picture's top-left pixel. The second green is colour 3.
        const int c = raw.COLOR(row, col);
        handle->bayer[position] = (uint8_t)(c == 3 ? 1 : c);
        // Base, per-colour offset, and an optional pattern of cblack[4] rows by cblack[5] columns.
        float black = (float)color.black + (float)color.cblack[c];
        if (color.cblack[4] > 0 && color.cblack[5] > 0)
            black += (float)color.cblack[6 + (row % color.cblack[4]) * color.cblack[5] + col % color.cblack[5]];
        handle->black[position] = black;
        highest_black = std::max(highest_black, black);
    }
    handle->white = effective_white(d);

    // Left to LibRaw: Phase One per-sensor corrections, Fuji SuperCCD rotation (fuji_width),
    // non-square pixels, and black-level patterns larger than 2x2.
    bool wide_black_pattern = color.cblack[4] > 2 || color.cblack[5] > 2;
    bool needs_libraw = color.phase_one_data.format != 0 || d.rawdata.ioparams.fuji_width != 0 ||
                        s.pixel_aspect != 1.0 || wide_black_pattern;
    // A malformed file can give white at or below black (division by zero) or non-finite
    // multipliers.
    bool levels_ok = handle->white > highest_black;
    const float *mul = color.cam_mul[0] > 0 && color.cam_mul[1] > 0 ? color.cam_mul : color.pre_mul;
    bool balance_ok = std::isfinite(mul[0]) && std::isfinite(mul[1]) && std::isfinite(mul[2]) &&
                      mul[0] > 0 && mul[1] > 0 && mul[2] > 0;
    handle->plain_bayer = !needs_libraw && levels_ok && balance_ok;
}

} // namespace

static_assert(sizeof(rik_develop_params) == 128, "must match the kernels' uniform block");

int rik_abi_version(void) { return 1; }

namespace {

// `source` hands the bytes to LibRaw.
template <typename Source> int open_with(rik_handle **out, Source source) {
    *out = nullptr;
    rik_handle *handle = new (std::nothrow) rik_handle();
    if (!handle)
        return LIBRAW_UNSUFFICIENT_MEMORY;
    handle->raw.set_dataerror_handler(on_data_error, handle);
    handle->raw.set_progress_handler(on_progress, handle);
    int rc = guarded([&] { return source(handle->raw); });
    if (rc != LIBRAW_SUCCESS) {
        delete handle;
        return rc;
    }
    handle->flip = handle->raw.imgdata.sizes.flip;
    *out = handle;
    return LIBRAW_SUCCESS;
}

} // namespace

int rik_open(const char *path, rik_handle **out) {
    if (!path) {
        *out = nullptr;
        return LIBRAW_IO_ERROR;
    }
    return open_with(out, [&](LibRaw &raw) { return raw.open_file(path); });
}

int rik_open_buffer(const void *bytes, size_t length, rik_handle **out) {
    if (!bytes || length == 0) {
        *out = nullptr;
        return LIBRAW_IO_ERROR;
    }
    return open_with(out, [&](LibRaw &raw) { return raw.open_buffer(bytes, length); });
}

void rik_close(rik_handle *handle) {
    if (!handle)
        return;
    if (handle->processed)
        LibRaw::dcraw_clear_mem(handle->processed);
    handle->raw.recycle();
    delete handle;
}

void rik_set_memory_limit(rik_handle *handle, uint32_t megabytes) {
    handle->raw.imgdata.rawparams.max_raw_memory_mb = megabytes;
}

void rik_set_cancel_callback(rik_handle *handle, rik_cancel_callback callback, void *context) {
    handle->cancel = callback;
    handle->cancel_context = context;
}

void rik_get_info(rik_handle *handle, rik_info *info) {
    std::memset(info, 0, sizeof(*info));
    LibRaw &raw = handle->raw;
    const libraw_data_t &d = raw.imgdata;

    copy_string(info->make, sizeof(info->make), d.idata.make);
    copy_string(info->model, sizeof(info->model), d.idata.model);
    copy_string(info->lens, sizeof(info->lens), d.lens.Lens);
    libraw_decoder_info_t decoder = {};
    if (raw.get_decoder_info(&decoder) == LIBRAW_SUCCESS)
        copy_string(info->decoder, sizeof(info->decoder), decoder.decoder_name);

    info->cfa_kind = cfa_kind(d.idata);
    info->colors = d.idata.colors;
    info->dng_version = d.idata.dng_version;

    info->iso = d.other.iso_speed;
    info->shutter = d.other.shutter;
    info->aperture = d.other.aperture;
    info->focal_length = d.other.focal_len;
    info->timestamp = (int64_t)d.other.timestamp;

    // dcraw_process() rewrites width and height with the developed image's.
    info->raw_width = d.sizes.raw_width;
    info->raw_height = d.sizes.raw_height;
    info->width = d.sizes.width;
    info->height = d.sizes.height;
    info->left_margin = d.sizes.left_margin;
    info->top_margin = d.sizes.top_margin;
    info->flip = handle->flip;

    std::memcpy(info->bayer, handle->bayer, sizeof(info->bayer));
    std::memcpy(info->black, handle->black, sizeof(info->black));
    info->white = handle->white;

    // As-shot multipliers when the camera recorded them, LibRaw's daylight set otherwise.
    const libraw_colordata_t &color = d.color;
    const float *mul = color.cam_mul[0] > 0 && color.cam_mul[1] > 0 ? color.cam_mul : color.pre_mul;
    const float green = mul[1] > 0 ? mul[1] : 1;
    info->wb[0] = mul[0] / green;
    info->wb[1] = 1;
    info->wb[2] = mul[2] / green;

    // rgb_cam is 3x4. The fourth column is for four-colour sensors.
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
            info->rgb_cam[r * 3 + c] = color.rgb_cam[r][c];

    info->plain_bayer = handle->plain_bayer ? 1 : 0;
    info->data_errors = handle->data_errors ? 1 : 0;
}

int rik_get_thumbnail(rik_handle *handle, rik_thumbnail *out) {
    std::memset(out, 0, sizeof(*out));
    LibRaw &raw = handle->raw;
    int rc = guarded([&] { return raw.unpack_thumb(); });
    if (rc != LIBRAW_SUCCESS)
        return rc;
    const libraw_thumbnail_t &thumb = raw.imgdata.thumbnail;
    bool jpeg = thumb.tformat == LIBRAW_THUMBNAIL_JPEG;
    bool bitmap = thumb.tformat == LIBRAW_THUMBNAIL_BITMAP && thumb.tcolors == 3;
    if (!thumb.thumb || thumb.tlength == 0 || !(jpeg || bitmap))
        return LIBRAW_UNSUPPORTED_THUMBNAIL;
    // A bitmap is read as width * height * 3 bytes.
    if (bitmap && (uint64_t)thumb.twidth * thumb.theight * 3 > thumb.tlength)
        return LIBRAW_UNSUPPORTED_THUMBNAIL;
    out->data = (const uint8_t *)thumb.thumb;
    out->length = thumb.tlength;
    out->width = thumb.twidth;
    out->height = thumb.theight;
    out->is_jpeg = jpeg ? 1 : 0;
    return LIBRAW_SUCCESS;
}

int rik_unpack(rik_handle *handle) {
    if (handle->unpacked)
        return LIBRAW_SUCCESS;
    LibRaw &raw = handle->raw;
    return guarded([&] {
        int rc = raw.unpack();
        if (rc != LIBRAW_SUCCESS)
            return rc;
        handle->unpacked = true;
        handle->flip = raw.imgdata.sizes.flip;
        apply_camera_crop(raw);
        capture_bayer_state(handle);
        return (int)LIBRAW_SUCCESS;
    });
}

const uint16_t *rik_mosaic(rik_handle *handle, size_t *row_bytes) {
    *row_bytes = 0;
    if (!handle->plain_bayer)
        return nullptr;
    const libraw_data_t &d = handle->raw.imgdata;
    *row_bytes = d.sizes.raw_pitch;
    return d.rawdata.raw_image;
}

int rik_get_develop_params(rik_handle *handle, rik_develop_params *out) {
    std::memset(out, 0, sizeof(*out));
    if (!handle->plain_bayer)
        return LIBRAW_REQUEST_FOR_NONEXISTENT_IMAGE;
    const libraw_data_t &d = handle->raw.imgdata;
    const libraw_colordata_t &color = d.color;

    std::memcpy(out->black, handle->black, sizeof(out->black));
    out->white = handle->white;
    for (int position = 0; position < 4; position++)
        out->pattern[position] = handle->bayer[position];
    out->origin[0] = d.sizes.left_margin;
    out->origin[1] = d.sizes.top_margin;
    out->size[0] = d.sizes.width;
    out->size[1] = d.sizes.height;

    // Scaled so the smallest multiplier is 1. A kernel that clips at 1 after white balance
    // then keeps blown highlights neutral.
    const float *mul = color.cam_mul[0] > 0 && color.cam_mul[1] > 0 ? color.cam_mul : color.pre_mul;
    const float smallest = std::min({mul[0], mul[1], mul[2]});
    for (int c = 0; c < 3; c++)
        out->white_balance[c] = mul[c] / smallest;
    out->white_balance[3] = 1;

    // rgb_cam is 3x4. The fourth column is for four-colour sensors.
    float *rows[3] = {out->matrix_row0, out->matrix_row1, out->matrix_row2};
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
            rows[r][c] = color.rgb_cam[r][c];
    return LIBRAW_SUCCESS;
}

int rik_process_rgb16(rik_handle *handle, int half_size, rik_rgb16 *out) {
    std::memset(out, 0, sizeof(*out));
    if (!handle->unpacked)
        return LIBRAW_OUT_OF_ORDER_CALL;
    LibRaw &raw = handle->raw;

    if (!handle->processed) {
        // Same contract as the GPU path: scene-linear, white-balanced, sRGB primaries.
        libraw_output_params_t &p = raw.imgdata.params;
        p.output_bps = 16;
        p.gamm[0] = 1;        // linear transfer curve
        p.gamm[1] = 1;
        p.no_auto_bright = 1; // the caller sets exposure
        p.use_camera_wb = 1;
        p.output_color = 1;   // sRGB primaries
        p.user_flip = 0;      // the caller applies `flip`
        p.highlight = 0;      // clip highlights
        p.half_size = half_size ? 1 : 0;
        // X-Trans: one interpolation pass. About three times faster, slightly softer.
        if (raw.imgdata.idata.filters == 9)
            p.user_qual = 2;
        // LibRaw bins mosaic sensors only.
        handle->half_size_applied = half_size && raw.imgdata.idata.filters != 0;

        int rc = guarded([&] {
            int status = raw.dcraw_process();
            if (status != LIBRAW_SUCCESS)
                return status;
            handle->processed = raw.dcraw_make_mem_image(&status);
            return status;
        });
        if (rc != LIBRAW_SUCCESS)
            return rc;
        if (!handle->processed)
            return LIBRAW_UNSPECIFIED_ERROR;
    }

    const libraw_processed_image_t *image = handle->processed;
    bool supported = image->colors == 3 || image->colors == 1;
    if (image->type != LIBRAW_IMAGE_BITMAP || !supported || image->bits != 16)
        return LIBRAW_UNSPECIFIED_ERROR;
    out->pixels = (const uint16_t *)image->data;
    out->width = image->width;
    out->height = image->height;
    out->channels = image->colors;
    out->row_bytes = (size_t)image->width * sizeof(uint16_t) * image->colors;
    out->is_half_size = handle->half_size_applied ? 1 : 0;
    return LIBRAW_SUCCESS;
}

const char *rik_strerror(int code) { return libraw_strerror(code); }
const char *rik_libraw_version(void) { return LibRaw::version(); }
int rik_camera_count(void) { return LibRaw::cameraCount(); }
