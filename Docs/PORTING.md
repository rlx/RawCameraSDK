# Using the core from Rust and from the web

The Swift package is one consumer of this project's decoder. The decoder itself is a
portable core with a C interface, and the same core builds into a Rust crate and a
WebAssembly module. This page explains how the pieces are divided and what each binding
gets.

## Three layers

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ Platform adapters                                                             │
│   Swift package   Apple's decoder first, Metal kernel, looks, colour check    │
│   Rust crate      safe wrapper, WGSL kernel through wgpu                      │
│   Web module      WebAssembly build, JavaScript wrapper                       │
├───────────────────────────────────────────────────────────────────────────────┤
│ Development contract                                                          │
│   rik_develop_params   the kernel's 128-byte uniform block                    │
│   Shaders/develop.wgsl and the Metal kernel   one algorithm, two languages    │
│   Conformance/kernel-cases.json   what every kernel must reproduce            │
├───────────────────────────────────────────────────────────────────────────────┤
│ Portable core                                                                 │
│   Sources/RawShim   the C interface                                           │
│   Vendor/LibRaw     the decoder                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

**The core** is LibRaw plus `Sources/RawShim`. It uses the C and C++ standard libraries and
zlib, and nothing from any operating system or GPU API. It opens a file from a path or from
memory, reads metadata, extracts the embedded preview, decodes the sensor data, and can
develop any file on the CPU.

**The development contract** is what lets a GPU do the developing instead. For a plain Bayer
file the core hands out the raw mosaic and a parameter block, `rik_develop_params`. The
block is laid out to be a shader's uniform buffer as it is, so no binding has to rebuild
it. The kernel that consumes it exists twice, in Metal and in WGSL.

**The adapters** are thin. Each one compiles the core with its own build system and adds
what is natural on its platform.

## What keeps two kernels the same

Two implementations of one algorithm drift apart unless something checks them.
`Conformance/kernel-cases.json` holds sixteen small sensor mosaics with known answers:
flat fields for each of the four Bayer arrangements, per-position black levels, a picture
with a distinct top and left, white balance, and blown highlights. The Swift tests run them
against the Metal kernel and the Rust tests run them against the WGSL kernel under wgpu.
A new port of the kernel is done when it passes the file.

`Scripts/conformance.py` generates the cases and says what each one is for.

## The C interface as the extension point

`Sources/RawShim/include/RawShim.h` is the whole surface. Three properties make it safe to
build on from outside:

- **A version.** `rik_abi_version()` changes when a struct's layout or a function's meaning
  does. The Rust crate and the JavaScript wrapper check it when they start.
- **No platform in it.** Names, types and behaviour are the same on every host. A file is
  described as `plain_bayer`, not by which GPU API might develop it.
- **Ownership stated once.** Every pointer belongs to the handle and lives until
  `rik_close`. Each binding turns that rule into its language's idiom: closures in Swift,
  borrows in Rust, copies in JavaScript.

Adding a binding for another language means compiling the sources listed in
`CMakeLists.txt` and wrapping that header.

## Rust

`Bindings/rust` is a crate named `rawinput`.

```rust
let mut file = rawinput::RawFile::open("photo.arw")?;
file.unpack()?;

// Any file: the core's own development, on the CPU.
let developed = file.develop_cpu(false)?;

// Plain Bayer files: the WGSL kernel through wgpu (feature "gpu").
if let (Some(mosaic), Some(params)) = (file.mosaic(), file.develop_params()) {
    let developer = rawinput::gpu::Developer::new(&device);
    let texture = developer.develop(&device, &queue, &mosaic, &params, false);
}
```

- `build.rs` compiles LibRaw and the C interface with the `cc` crate; there is nothing to
  install beyond a C++ compiler.
- `RawFile` closes the handle on drop. Buffers the core owns come back as slices borrowed
  from the file, so the compiler enforces the lifetime rule.
- The `gpu` feature adds `gpu::Developer`, which returns an `Rgba16Float` texture of linear
  sRGB values. `gpu::KERNEL_WGSL` exposes the shader source for an engine that wants to
  build the pipeline into its own.

```sh
cd Bindings/rust
cargo test                  # the decoder, on the demo's sample files
cargo test --features gpu   # plus the WGSL kernel against the conformance cases
```

## WebAssembly

`Bindings/web` holds a JavaScript wrapper over the core compiled with Emscripten.

```js
import { loadRawInput } from './rawinput.mjs';

const rawInput = await loadRawInput();
const file = rawInput.open(bytes);        // a Uint8Array holding the whole file
file.unpack();
const picture = file.developCPU();        // linear 16-bit RGB
const params = file.developParams();      // 128 bytes: the WebGPU kernel's uniform buffer
file.close();
```

```sh
emcmake cmake -S . -B .build/wasm && cmake --build .build/wasm   # writes Bindings/web/dist
node Bindings/web/test.mjs
```

- A browser has no file paths, so the wrapper opens from memory (`rik_open_buffer`).
- `Bindings/web/glue.c` exists because JavaScript cannot read a C struct without knowing its
  layout. Metadata crosses as JSON and everything else as a few numbers.
- The wrapper returns copies, because the module's memory can move when it grows.
- The module is about 850 KB before compression.

The tests run under Node. The same module loads in a browser, and `Shaders/develop.wgsl` is
valid WebGPU, but nothing here has been run in a browser.

## What the other platforms do not get

- **Apple's decoder.** It exists only on Apple platforms. There the Swift package prefers
  it and uses the core as the fallback. Everywhere else the core is the only decoder, so
  the cameras and formats it cannot open (see the README) are simply unsupported.
- **Looks, the colour check and automatic exposure.** These are written against Core Image
  in the Swift package. They are small and would port, but they have not been.
- **Cancellation** is in the C interface (`rik_set_cancel_callback`) and used by the Swift
  package. The Rust and JavaScript wrappers do not expose it yet.

## Keeping the builds in step

The core is compiled by three build systems from one list of sources and two definitions
(`USE_ZLIB`, `USE_X3FTOOLS`). The list lives in `Package.swift`, `CMakeLists.txt` and
`Bindings/rust/build.rs`. All three exclude LibRaw's `*_ph.cpp` placeholder files. A
change to one has to be made in the others; each file says so at the top.
