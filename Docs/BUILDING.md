# Building and running

Requires macOS with Xcode 27. The library and demo run on iOS 17 and macOS 14 or later.

```sh
git clone --recurse-submodules https://github.com/rlx/RawCameraSDK.git
cd RawCameraSDK
```

LibRaw is a submodule. After a plain clone, run `git submodule update --init`.

## Library

```sh
swift build
```

As a dependency:

```swift
.package(url: "https://github.com/rlx/RawCameraSDK.git", from: "0.1.0")
// in the target:
.product(name: "RawInputKit", package: "RawCameraSDK")
```

## Demo app

Open `Examples/RawInputDemo/RawInputDemo.xcodeproj` and run the `RawInputDemo` scheme on an
iPhone simulator or "My Mac". The first build downloads eleven sample files (285 MB).

The gallery has one file that both decoders open and ten that Apple's decoder rejects. In
the detail view, the first picker selects the decoder and the second the rendering:
the decoder's own output, or the Neutral or Film look. Import adds your own files.

To run on a phone, choose your team under Signing & Capabilities for the `RawInputDemo`
target. The phone needs Developer Mode on (Settings → Privacy & Security).

XcodeGen is only needed to change project settings (`project.yml`).

## Tests

```sh
Examples/RawInputDemo/Scripts/fetch-samples.sh        # the demo's eleven files, 285 MB
Scripts/corpus.py fetch --only DMC-LX10_-_1_1         # one more, for the crop test, 22 MB
swift test
```

Suites whose files are missing are skipped.

On the iPhone simulator:

```sh
xcodebuild test -scheme RawInputKit-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## On a device

`xcrun devicectl list devices` prints the UDID. A free personal team works for signing.

```sh
# Test suite, hosted in the demo app.
Scripts/device-tests.sh <device-udid> <team-id>

# Timings and peak memory: 15 app launches by default, or everything three times.
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

## Portable core, Rust, WebAssembly

Described in [PORTING.md](PORTING.md).

```sh
# C: build the core with CMake and decode a sample.
cmake -S . -B .build/cmake && cmake --build .build/cmake && ctest --test-dir .build/cmake

# Rust (needs a Rust toolchain).
cd Bindings/rust && cargo test --features gpu

# WebAssembly (needs Emscripten and Node).
emcmake cmake -S . -B .build/wasm && cmake --build .build/wasm
node Bindings/web/test.mjs
```

## Regenerating the measurements

The numbers in the README and [MEASUREMENTS.md](MEASUREMENTS.md) come from these commands.
The full archive is 19 GB. Apple's results depend on the OS version.

```sh
Scripts/corpus.py fetch
swift run -c release rawprobe Tests/Corpus --json Tests/probe-results.json   # about 6 minutes
swift run -c release rawprobe bench FILES... --json Tests/bench-results.json
swift run -c release rawprobe match FILES... --json Tests/match-results.json
Scripts/coverage.py && Scripts/charts.py
```

Single files:

```sh
swift run -c release rawprobe render  FILE out.jpg [apple|fallback]   # develop one file
swift run -c release rawprobe compare FILE out.jpg                    # both decoders side by side
swift run -c release rawprobe looks   FILE out.jpg                    # both through the shared looks
swift run -c release rawprobe fuzz    FILE... --iterations 800        # decode damaged copies
```

Fuzzing under AddressSanitizer:

```sh
swift build -c release --sanitize=address --scratch-path .build/asan
.build/asan/release/rawprobe fuzz FILE... --iterations 400
```

`Examples/RawInputDemo/Scripts/record-demo.sh` re-records the walkthrough GIF.
`Scripts/conformance.py` regenerates the kernel conformance cases.
