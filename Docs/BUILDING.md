# Building and running

Requirements: macOS with Xcode 27 (Swift 6). The library and demo run on iOS 17 and
macOS 14 or later. Nothing else is needed for the Swift package; the Rust and WebAssembly
bindings need their own toolchains, listed below.

```sh
git clone --recurse-submodules https://github.com/rlx/RawCameraSDK.git
cd RawCameraSDK
```

LibRaw is a git submodule. If you cloned without `--recurse-submodules`, run
`git submodule update --init`.

## The library

```sh
swift build
```

To use it in another project, add the package and depend on its `RawInputKit` product.
The repository and the library have different names, so the product has to be named:

```swift
.package(url: "https://github.com/rlx/RawCameraSDK.git", from: "0.1.0")
// and in the target:
.product(name: "RawInputKit", package: "RawCameraSDK")
```

## The demo app

Open `Examples/RawInputDemo/RawInputDemo.xcodeproj` and run the `RawInputDemo` scheme on an
iPhone simulator or "My Mac". The first build downloads eleven sample files (285 MB) and
verifies their checksums.

The app opens on one file both decoders can open and ten that Apple's decoder rejects. Open
one and switch the decoder between Automatic, Apple and Fallback, and the rendering between
Decoder (each decoder's own output), Neutral and Film. The exposure slider works on the
linear image. Import adds your own files from Files or a card reader.

To run on a phone, select the `RawInputDemo` target, choose your team under
Signing & Capabilities, and run. The phone needs Developer Mode switched on
(Settings → Privacy & Security).

The Xcode project is generated from `project.yml` with XcodeGen and committed, so the tool
is only needed to change project settings.

## Tests

```sh
Examples/RawInputDemo/Scripts/fetch-samples.sh        # the demo's eleven files, 285 MB
Scripts/corpus.py fetch --only DMC-LX10_-_1_1         # one more, for the crop test, 22 MB
swift test
```

Without the downloads, the suites that need files are skipped, with the command that
fetches them, and the rest still run. CI runs them on pushes to `main` and on pull requests.

On the iPhone simulator:

```sh
xcodebuild test -scheme RawInputKit-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## On a device

`xcrun devicectl list devices` gives the device's UDID. The team ID is the ten-character
code of the Apple developer team that signs the build; a free personal team works.

```sh
# The test suite, on the device. It runs inside the demo app, because a device cannot
# run a Swift package's tests directly.
Scripts/device-tests.sh <device-udid> <team-id>

# Timings and peak memory. 15 app launches by default, one per measurement;
# the second form measures everything three times.
Scripts/device-bench.py <device-udid>
Scripts/device-bench.py <device-udid> --limit 0 --runs 3
```

The benchmark needs the Release build of the demo installed first:

```sh
xcodebuild -project Examples/RawInputDemo/RawInputDemo.xcodeproj -scheme RawInputDemo \
    -configuration Release -destination 'id=<device-udid>' -derivedDataPath .build/device \
    DEVELOPMENT_TEAM=<team-id> -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-udid> \
    .build/device/Build/Products/Release-iphoneos/RawInputDemo.app
```

## The portable core, Rust and WebAssembly

See [PORTING.md](PORTING.md) for what these are.

```sh
# Plain C: builds the core with CMake and decodes a sample.
cmake -S . -B .build/cmake && cmake --build .build/cmake && ctest --test-dir .build/cmake

# Rust (needs a Rust toolchain).
cd Bindings/rust && cargo test --features gpu

# WebAssembly (needs Emscripten and Node).
emcmake cmake -S . -B .build/wasm && cmake --build .build/wasm
node Bindings/web/test.mjs
```

## Regenerating the measurements

Every number in the README and in [MEASUREMENTS.md](MEASUREMENTS.md) comes from these
commands. The full archive is 19 GB.

```sh
Scripts/corpus.py fetch
swift run -c release rawprobe Tests/Corpus --json Tests/probe-results.json   # about 6 minutes
swift run -c release rawprobe bench FILES... --json Tests/bench-results.json
swift run -c release rawprobe match FILES... --json Tests/match-results.json
Scripts/coverage.py && Scripts/charts.py
```

`rawprobe` also looks at single files:

```sh
swift run -c release rawprobe render  FILE out.jpg [apple|fallback]   # develop one file
swift run -c release rawprobe compare FILE out.jpg                    # both decoders side by side
swift run -c release rawprobe looks   FILE out.jpg                    # both through the shared looks
swift run -c release rawprobe fuzz    FILE... --iterations 800        # decode damaged copies
```

To fuzz under AddressSanitizer, build the tool with it first:

```sh
swift build -c release --sanitize=address --scratch-path .build/asan
.build/asan/release/rawprobe fuzz FILE... --iterations 400
```

`Examples/RawInputDemo/Scripts/record-demo.sh` re-records the walkthrough GIF by running the
app's UI test in the simulator. `Scripts/conformance.py` regenerates the kernel conformance
cases.
