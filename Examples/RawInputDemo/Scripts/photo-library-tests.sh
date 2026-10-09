#!/bin/sh
# Tests the photo library path in the iOS simulator: PhotoKit, then the photo picker.
#
#     Examples/RawInputDemo/Scripts/photo-library-tests.sh [simulator name]
#
# 1. Tests/RawInputKitTests/PhotoLibraryTests.swift saves the sample RAW files to the
#    simulator's photo library and reads them back through PhotoKit.
# 2. UITests/PhotoImportTests.swift picks from that library in the app's photo picker.
#
# The simulator is used because its photo library is disposable and `simctl` can grant
# access without a prompt. On a device these tests skip themselves.
set -eu
cd "$(dirname "$0")/.."
simulator=${1:-iPhone 17 Pro}
derived=../../.build/sim
destination="platform=iOS Simulator,name=$simulator"

Scripts/fetch-samples.sh
xcrun simctl boot "$simulator" 2>/dev/null || true
xcrun simctl privacy "$simulator" grant photos dev.rawinputkit.demo

log=$(mktemp)
# A suite that finds no permission, or a picker that finds no photos, skips or stops early.
# So the output is checked for the tests having run, not only for a zero exit status.
run() {
    scheme=$1 tests=$2 proof=$3
    if ! xcodebuild test -project RawInputDemo.xcodeproj -scheme "$scheme" -destination "$destination" \
        -derivedDataPath "$derived" -only-testing:"$tests" > "$log" 2>&1 || ! grep -q "$proof" "$log"; then
        grep -E "✘|error:|XCTAssert|skipped|failed" "$log" | head -40
        echo "FAILED: $tests (full log: $log)"
        exit 1
    fi
    echo "passed: $tests"
}
run RawInputDemo RawInputDemoTests/PhotoLibraryTests 'Suite "Photo library" passed'
run RawInputDemoUITests RawInputDemoUITests/PhotoImportTests "testPickedPhotosAreOpenedFromTheirBytes]' passed"
