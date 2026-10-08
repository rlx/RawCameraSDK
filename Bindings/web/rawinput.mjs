// Camera RAW decoding for JavaScript, on the same portable core as the Swift package and
// the Rust crate, compiled to WebAssembly.
//
//     import { loadRawInput } from './rawinput.mjs';
//     const rawInput = await loadRawInput();
//     const file = rawInput.open(bytes);          // a Uint8Array holding the whole file
//     console.log(file.info.make, file.info.model);
//     file.unpack();
//     const picture = file.developCPU();          // linear 16-bit RGB, any file the core decodes
//     file.close();
//
// Build the module first: `emcmake cmake -S . -B .build/wasm && cmake --build .build/wasm`
// from the repository root, which writes dist/rawinput_core.mjs and .wasm next to this file.
//
// What a browser does with the result is up to the caller. For plain Bayer files, mosaic()
// and developParams() are the inputs to the WebGPU kernel in Shaders/develop.wgsl: the
// parameter block is the kernel's uniform buffer as it is. developCPU() needs no GPU.
//
// Everything returned is a copy. The module's memory can grow and move during a later call,
// which would silently detach a view into it.

import createCore from './dist/rawinput_core.mjs';

/** The interface version this file was written against; see rik_abi_version in RawShim.h. */
const ABI_VERSION = 1;

export class RawInputError extends Error {
  constructor(message, code) {
    super(message);
    this.name = 'RawInputError';
    /** The decoder's own status code. */
    this.code = code;
  }
}

export async function loadRawInput() {
  const core = await createCore();
  const abi = core._rik_abi_version();
  if (abi !== ABI_VERSION) {
    throw new RawInputError(`the core speaks interface version ${abi}, this wrapper expects ${ABI_VERSION}`, 0);
  }

  const check = (code) => {
    if (code !== 0) throw new RawInputError(core.UTF8ToString(core._rik_strerror(code)), code);
  };

  class RawFile {
    #handle;
    #bytes; // the file, inside the module's memory; the core reads from it until close()

    constructor(handle, bytes) {
      this.#handle = handle;
      this.#bytes = bytes;
    }

    /** Camera, exposure and geometry. Geometry is final only after unpack(). */
    get info() {
      return JSON.parse(core.UTF8ToString(core._rikw_info_json(this.#handle)));
    }

    /** Refuses files whose sensor data would need more than this to decode. */
    setMemoryLimit(megabytes) {
      core._rik_set_memory_limit(this.#handle, megabytes);
    }

    /** The largest embedded preview: a JPEG, or packed 8-bit RGB. Needs no unpack(). */
    thumbnail() {
      check(core._rikw_thumbnail(this.#handle));
      const [pointer, length, width, height, isJPEG] = [0, 1, 2, 3, 4].map((i) => core._rikw_result(i));
      return { bytes: core.HEAPU8.slice(pointer, pointer + length), width, height, isJPEG: isJPEG === 1 };
    }

    /** Decompresses the sensor data: the expensive step. */
    unpack() {
      check(core._rik_unpack(this.#handle));
      if (this.info.dataErrors) {
        throw new RawInputError("the file's image data is truncated or corrupt", 0);
      }
    }

    /** The raw Bayer plane, or null if the file is not a plain Bayer mosaic. */
    mosaic() {
      core._rikw_mosaic(this.#handle);
      const pointer = core._rikw_result(0);
      if (pointer === 0) return null;
      const rowStride = core._rikw_result(1) / 2;
      const { rawWidth, rawHeight } = this.info;
      const start = pointer / 2;
      return { samples: core.HEAPU16.slice(start, start + rowStride * rawHeight), rawWidth, rawHeight, rowStride };
    }

    /**
     * The 128-byte parameter block for the development kernel, or null if the file is not
     * a plain Bayer mosaic. Upload it as the kernel's uniform buffer unchanged.
     */
    developParams() {
      const pointer = core._malloc(128);
      try {
        if (core._rik_get_develop_params(this.#handle, pointer) !== 0) return null;
        return core.HEAPU8.slice(pointer, pointer + 128);
      } finally {
        core._free(pointer);
      }
    }

    /**
     * The core's own development on the CPU: linear, 16 bits per channel, not rotated.
     * Works for every file the core can decode. `channels` is 3 (RGB, sRGB primaries) or
     * 1 (monochrome sensor).
     */
    developCPU({ halfSize = false } = {}) {
      check(core._rikw_develop(this.#handle, halfSize ? 1 : 0));
      const [pointer, width, height, channels, isHalfSize] = [0, 1, 2, 3, 4].map((i) => core._rikw_result(i));
      const start = pointer / 2;
      return {
        pixels: core.HEAPU16.slice(start, start + width * height * channels),
        width, height, channels, isHalfSize: isHalfSize === 1,
      };
    }

    /** Releases the file. Nothing else here frees it; JavaScript has no destructors. */
    close() {
      if (this.#handle === 0) return;
      core._rik_close(this.#handle);
      core._free(this.#bytes);
      this.#handle = 0;
    }
  }

  return {
    /** The decoder library's version. */
    version: core.UTF8ToString(core._rik_libraw_version()),

    /** Parses a RAW file held in memory. Cheap; no sensor data is read until unpack(). */
    open(bytes) {
      const copy = core._malloc(bytes.length);
      core.HEAPU8.set(bytes, copy);
      const out = core._malloc(4);
      try {
        const code = core._rik_open_buffer(copy, bytes.length, out);
        if (code !== 0) {
          core._free(copy);
          check(code);
        }
        return new RawFile(new Uint32Array(core.HEAPU8.buffer, out, 1)[0], copy);
      } finally {
        core._free(out);
      }
    },
  };
}
