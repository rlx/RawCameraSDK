// Implementation of the C boundary declared in RawShim.h. Read that header first: it
// documents the lifecycle, ownership and threading rules this file implements.
//
// A note on LibRaw's state, because most of the subtlety here comes from it. A `LibRaw`
// object is one large mutable struct (`imgdata`) that different calls fill in and rewrite:
//
//   open_file()      fills identification, exposure and nominal geometry
//   unpack()         decodes the sensor plane and finalises black levels from the masked
//                    border; it does NOT compute the real white level
//   dcraw_process()  develops the image and, along the way, overwrites geometry fields
//                    (width, height, flip) with the processed image's
//
// So "read the field when it is valid, and remember it" is the rule throughout: anything
// the caller may ask for after processing is captured at unpack time.

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

    // Captured in rik_unpack; see the note at the top of the file.
    int flip = 0;
    float white = 0;
    uint8_t bayer[4] = {};
    float black[4] = {};
    bool metal_ready = false;
};

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
    // LibRaw describes plain Bayer sensors either as three colours or as four with the
    // second green listed separately ("RGBG"). A real fourth colour (CMYG, RGBE) is not Bayer.
    bool rgb = id.colors == 3 || (id.colors == 4 && id.cdesc[3] == 'G');
    return rgb ? RIK_CFA_BAYER : RIK_CFA_OTHER;
}

// LibRaw calls this when a decoder runs out of data or meets an invalid stream. Its default
// handler prints to stderr; a library should report through its API instead.
void on_data_error(void *context, const char *, const INT64) {
    static_cast<rik_handle *>(context)->data_errors = true;
}

// Narrows the picture rectangle to the camera's own crop.
//
// Many cameras record a crop inside the sensor area: an in-camera aspect ratio (1:1, 16:9)
// or simply the region the maker considers the image. LibRaw parses it but leaves applying
// it to the caller; without it the fallback would return a differently framed picture than
// Apple's decoder and the camera's JPEG.
//
// The crop origin is kept on the same mosaic phase as the original margins (an even offset
// for Bayer), so the colour pattern does not shift under either the GPU kernel or LibRaw's
// own demosaic. X-Trans is left alone: its pattern repeats every six pixels and LibRaw's
// tables are tied to the original origin.
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

// The level at which the sensor actually clips.
//
// `color.maximum` is a nominal value from LibRaw's tables or the file's metadata, and for
// many cameras the data saturates somewhat below it. Developing against the nominal value
// leaves blown highlights short of white in the green channel while red and blue, which
// white balance scales up, still clip: magenta highlights. LibRaw's own development avoids
// this with the rule reproduced here: trust the brightest sample in the picture when it is
// below the nominal maximum but above 75% of it (below that, the picture is simply dark).
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

// Decides whether the caller can develop the plane itself, and captures what it needs to.
// Every condition is something the GPU kernel in MetalDevelop.swift assumes.
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
        // COLOR() is relative to the picture's top-left pixel and reports the second green
        // of a cell as colour 3.
        const int c = raw.COLOR(row, col);
        handle->bayer[position] = (uint8_t)(c == 3 ? 1 : c);
        // Black level has three parts: a base, a per-colour offset, and an optional
        // repeating pattern whose size is in cblack[4] (rows) and cblack[5] (columns).
        float black = (float)color.black + (float)color.cblack[c];
        if (color.cblack[4] > 0 && color.cblack[5] > 0)
            black += (float)color.cblack[6 + (row % color.cblack[4]) * color.cblack[5] + col % color.cblack[5]];
        handle->black[position] = black;
        highest_black = std::max(highest_black, black);
    }
    handle->white = effective_white(d);

    // Not plain enough for the kernel:
    //   - Phase One format files need per-sensor corrections (quadrant black, defect and
    //     linearity maps) that only LibRaw's development applies;
    //   - Fuji SuperCCD sensors are rotated 45 degrees (fuji_width) and some sensors have
    //     non-square pixels; LibRaw resamples both.
    bool needs_libraw = color.phase_one_data.format != 0 || d.rawdata.ioparams.fuji_width != 0 ||
                        s.pixel_aspect != 1.0;
    // A white level at or below black would divide by zero; a non-finite multiplier would
    // poison every pixel. Both can come straight from a malformed file's tags.
    bool levels_ok = handle->white > highest_black;
    const float *mul = color.cam_mul[0] > 0 && color.cam_mul[1] > 0 ? color.cam_mul : color.pre_mul;
    bool balance_ok = std::isfinite(mul[0]) && std::isfinite(mul[1]) && std::isfinite(mul[2]) &&
                      mul[0] > 0 && mul[1] > 0 && mul[2] > 0;
    handle->metal_ready = !needs_libraw && levels_ok && balance_ok;
}

} // namespace

int rik_open(const char *path, rik_handle **out) {
    *out = nullptr;
    if (!path)
        return LIBRAW_IO_ERROR;
    rik_handle *handle = new (std::nothrow) rik_handle();
    if (!handle)
        return LIBRAW_UNSUFFICIENT_MEMORY;
    handle->raw.set_dataerror_handler(on_data_error, handle);
    int rc = handle->raw.open_file(path);
    if (rc != LIBRAW_SUCCESS) {
        delete handle;
        return rc;
    }
    handle->flip = handle->raw.imgdata.sizes.flip;
    *out = handle;
    return LIBRAW_SUCCESS;
}

void rik_close(rik_handle *handle) {
    if (!handle)
        return;
    if (handle->processed)
        LibRaw::dcraw_clear_mem(handle->processed);
    handle->raw.recycle();
    delete handle;
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

    // Before processing these are the sensor's; dcraw_process() rewrites width and height
    // with the developed image's, which is exactly what a caller asking afterwards wants.
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

    // LibRaw's rgb_cam is 3x4; the fourth column only matters for four-colour sensors.
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
            info->rgb_cam[r * 3 + c] = color.rgb_cam[r][c];

    info->metal_ready = handle->metal_ready ? 1 : 0;
    info->data_errors = handle->data_errors ? 1 : 0;
}

int rik_get_thumbnail(rik_handle *handle, rik_thumbnail *out) {
    std::memset(out, 0, sizeof(*out));
    LibRaw &raw = handle->raw;
    int rc = raw.unpack_thumb();
    if (rc != LIBRAW_SUCCESS)
        return rc;
    const libraw_thumbnail_t &thumb = raw.imgdata.thumbnail;
    bool jpeg = thumb.tformat == LIBRAW_THUMBNAIL_JPEG;
    bool bitmap = thumb.tformat == LIBRAW_THUMBNAIL_BITMAP && thumb.tcolors == 3;
    if (!thumb.thumb || thumb.tlength == 0 || !(jpeg || bitmap))
        return LIBRAW_UNSUPPORTED_THUMBNAIL;
    // For a bitmap the caller is about to read width * height * 3 bytes.
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
    int rc = raw.unpack();
    if (rc != LIBRAW_SUCCESS)
        return rc;
    handle->unpacked = true;
    handle->flip = raw.imgdata.sizes.flip;
    apply_camera_crop(raw);
    capture_bayer_state(handle);
    return LIBRAW_SUCCESS;
}

const uint16_t *rik_mosaic(rik_handle *handle, size_t *row_bytes) {
    *row_bytes = 0;
    if (!handle->metal_ready)
        return nullptr;
    const libraw_data_t &d = handle->raw.imgdata;
    *row_bytes = d.sizes.raw_pitch;
    return d.rawdata.raw_image;
}

int rik_process_rgb16(rik_handle *handle, int half_size, rik_rgb16 *out) {
    std::memset(out, 0, sizeof(*out));
    if (!handle->unpacked)
        return LIBRAW_OUT_OF_ORDER_CALL;
    LibRaw &raw = handle->raw;

    if (!handle->processed) {
        // The aim is the same contract as the GPU path: scene-linear, white-balanced,
        // sRGB primaries, nothing baked in that an editor would want to control.
        libraw_output_params_t &p = raw.imgdata.params;
        p.output_bps = 16;
        p.gamm[0] = 1;        // linear transfer curve
        p.gamm[1] = 1;
        p.no_auto_bright = 1; // exposure is the caller's decision
        p.use_camera_wb = 1;
        p.output_color = 1;   // sRGB primaries
        p.user_flip = 0;      // the caller applies `flip`, as it does on the GPU path
        p.highlight = 0;      // clip highlights; reconstruction is out of scope
        p.half_size = half_size ? 1 : 0;
        // X-Trans: one interpolation pass instead of three. Roughly three times faster and
        // slightly softer. This path only runs for files Apple's decoder rejects, where a
        // usable image in six seconds beats a marginally sharper one in eighteen.
        if (raw.imgdata.idata.filters == 9)
            p.user_qual = 2;
        // LibRaw only bins mosaic sensors; full-colour data ignores half_size.
        handle->half_size_applied = half_size && raw.imgdata.idata.filters != 0;

        int rc = raw.dcraw_process();
        if (rc != LIBRAW_SUCCESS)
            return rc;
        handle->processed = raw.dcraw_make_mem_image(&rc);
        if (!handle->processed)
            return rc != LIBRAW_SUCCESS ? rc : LIBRAW_UNSPECIFIED_ERROR;
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
