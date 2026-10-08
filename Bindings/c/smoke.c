/* Smoke test for the portable core from plain C: open a RAW file, read its metadata,
 * decode it, develop it on the CPU.
 *
 *     core_smoke <file.raw>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "RawShim.h"

static int fail(const char *step, int code) {
    fprintf(stderr, "%s failed: %s (%d)\n", step, rik_strerror(code), code);
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: core_smoke <file.raw>\n");
        return 2;
    }
    printf("core ABI %d, %s\n", rik_abi_version(), rik_libraw_version());

    /* Open from memory, as a host without a file system does. */
    FILE *file = fopen(argv[1], "rb");
    if (!file) {
        perror(argv[1]);
        return 1;
    }
    fseek(file, 0, SEEK_END);
    long length = ftell(file);
    rewind(file);
    void *bytes = malloc((size_t)length);
    if (!bytes || fread(bytes, 1, (size_t)length, file) != (size_t)length) {
        fprintf(stderr, "could not read %s\n", argv[1]);
        return 1;
    }
    fclose(file);

    rik_handle *handle = NULL;
    int code = rik_open_buffer(bytes, (size_t)length, &handle);
    if (code != 0)
        return fail("open", code);

    rik_info info;
    rik_get_info(handle, &info);
    printf("%s %s, %s\n", info.make, info.model, info.decoder);

    rik_set_memory_limit(handle, 1024);
    if ((code = rik_unpack(handle)) != 0)
        return fail("unpack", code);
    rik_get_info(handle, &info);
    printf("picture %ux%u at (%u, %u) in a %ux%u plane, %s\n", info.width, info.height, info.left_margin,
           info.top_margin, info.raw_width, info.raw_height,
           info.plain_bayer ? "plain Bayer: a GPU kernel can develop it" : "needs the core's own development");

    if (info.plain_bayer) {
        rik_develop_params params;
        size_t row_bytes = 0;
        if (rik_get_develop_params(handle, &params) != 0 || !rik_mosaic(handle, &row_bytes))
            return fail("develop parameters", -1);
        printf("white balance %.3f %.3f %.3f, white level %.0f\n", params.white_balance[0],
               params.white_balance[1], params.white_balance[2], params.white);
    }

    rik_rgb16 developed;
    if ((code = rik_process_rgb16(handle, 0, &developed)) != 0)
        return fail("develop", code);
    unsigned long long sum = 0;
    size_t count = (size_t)developed.width * developed.height * (size_t)developed.channels;
    for (size_t i = 0; i < count; i += 997)
        sum += developed.pixels[i];
    printf("developed %ux%u, %d channel(s), mean level %.4f\n", developed.width, developed.height,
           developed.channels, (double)sum / (double)((count + 996) / 997) / 65535.0);

    rik_close(handle);
    free(bytes);
    return sum > 0 ? 0 : 1;
}
