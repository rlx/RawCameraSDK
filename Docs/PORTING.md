# Rust and WebAssembly

The decoder is a portable core with a C interface. The Swift package, a Rust crate and a
WebAssembly module all build from it.

## Layers

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ Bindings                                                                      │
│   Swift package   Apple's decoder first, Metal kernel, looks, colour check    │
│   Rust crate      safe wrapper, WGSL kernel through wgpu                      │
│   Web module      WebAssembly build, JavaScript wrapper                       │
├───────────────────────────────────────────────────────────────────────────────┤
│ Kernel contract                                                               │
│   rik_develop_params              128-byte uniform block                      │
│   Shaders/develop.wgsl, Metal     the same kernel in two languages            │
│   Conformance/kernel-cases.json   expected output for both                    │
├───────────────────────────────────────────────────────────────────────────────┤
│ Portable core                                                                 │
│   Sources/RawShim   C interface                                               │
│   Vendor/LibRaw     decoder                                                   │
└───────────────────────────────────────────────────────────────────────────────┘
```

The core depends on the C and C++ standard libraries and zlib. It opens a file from a path
or from memory, reads metadata, extracts the embedded preview, decodes the sensor data,
and can develop any file on the CPU.

For plain Bayer files it also returns the raw mosaic and `rik_develop_params`, which is
laid out as a shader uniform buffer. A GPU kernel takes those two and develops the image.

## Conformance cases

`Conformance/kernel-cases.json` holds sixteen small mosaics with known results: flat
fields for the four Bayer arrangements, per-position black levels, orientation, white
balance and clipped highlights. The Swift tests run them on the Metal kernel and the Rust
tests run them on the WGSL kernel. `Scripts/conformance.py` generates the file.

## C interface

`Sources/RawShim/include/RawShim.h` is the full interface.

- `rik_abi_version()` changes with any struct layout or behaviour change. The Rust and
  JavaScript wrappers check it at start-up.
- Every pointer belongs to the handle and is valid until `rik_close`.

A binding for another language compiles the sources listed in `CMakeLists.txt` and wraps
that header.

## Rust

`Bindings/rust` is a crate named `rawinput`.

```rust
let mut file = rawinput::RawFile::open("photo.arw")?;
file.unpack()?;

// Any file, on the CPU.
let developed = file.develop_cpu(false)?;

// Plain Bayer files, on the GPU (feature "gpu").
if let (Some(mosaic), Some(params)) = (file.mosaic(), file.develop_params()) {
    let developer = rawinput::gpu::Developer::new(&device);
    let texture = developer.develop(&device, &queue, &mosaic, &params, false);
}
```

- `build.rs` compiles LibRaw and the C interface with the `cc` crate. Only a C++ compiler
  is required.
- `RawFile` closes the handle on drop. Buffers are slices borrowed from the file.
- The `gpu` feature adds `gpu::Developer`, which returns an `Rgba16Float` texture in linear
  sRGB. `gpu::KERNEL_WGSL` is the shader source, for an engine with its own pipeline.

```sh
cd Bindings/rust
cargo test                  # decoder, on the demo's sample files
cargo test --features gpu   # also the WGSL kernel against the conformance cases
```

## WebAssembly

`Bindings/web` is a JavaScript wrapper over the core compiled with Emscripten.

```js
import { loadRawInput } from './rawinput.mjs';

const rawInput = await loadRawInput();
const file = rawInput.open(bytes);        // Uint8Array with the whole file
file.unpack();
const picture = file.developCPU();        // linear 16-bit RGB
const params = file.developParams();      // 128 bytes, the kernel's uniform buffer
file.close();
```

```sh
emcmake cmake -S . -B .build/wasm && cmake --build .build/wasm   # writes Bindings/web/dist
node Bindings/web/test.mjs
```

- The wrapper opens files from memory (`rik_open_buffer`).
- `Bindings/web/glue.c` passes metadata to JavaScript as JSON.
- Returned buffers are copies, because the module's memory can move when it grows.
- The module is about 850 KB uncompressed.

The tests run under Node. Nothing here has been run in a browser.

## Missing from the Rust and web bindings

- Apple's decoder, which exists only on Apple platforms. The core is the only decoder
  elsewhere.
- Looks, the colour check and automatic exposure. They are written against Core Image.
- Cancellation. `rik_set_cancel_callback` is in the C interface but the wrappers do not
  expose it.

## Source list

Three build files list the core's sources and its two definitions (`USE_ZLIB`,
`USE_X3FTOOLS`): `Package.swift`, `CMakeLists.txt` and `Bindings/rust/build.rs`. All
exclude LibRaw's `*_ph.cpp` placeholder files. Keep them in sync.
