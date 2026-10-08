#!/bin/sh
# Runs the test suite on a connected iPhone or iPad.
#
#     Scripts/device-tests.sh <device-udid> <development-team-id>
#
# `xcrun devicectl list devices` shows the UDID. A free personal team works.
# The tests are built into a bundle hosted by the demo app (the RawInputDemoTests target).
# The crop-test file is copied into the app's Documents folder here.
set -eu
device=$1
team=$2
cd "$(dirname "$0")/.."
project=Examples/RawInputDemo/RawInputDemo.xcodeproj
derived=.build/device

Examples/RawInputDemo/Scripts/fetch-samples.sh
Scripts/corpus.py fetch --only "DMC-LX10_-_1_1" > /dev/null

# The app has to be on the device before files can be put in its container.
xcodebuild -project "$project" -scheme RawInputDemo -destination "id=$device" \
    -derivedDataPath "$derived" DEVELOPMENT_TEAM="$team" -allowProvisioningUpdates \
    build-for-testing -quiet
xcrun devicectl device install app --device "$device" \
    "$derived/Build/Products/Debug-iphoneos/RawInputDemo.app" > /dev/null

copy() {
    xcrun devicectl device copy to --device "$device" --domain-type appDataContainer \
        --domain-identifier dev.rawinputkit.demo --source "$1" --destination "Documents/$2" > /dev/null
}
copy "$(ls Tests/Corpus/*DMC-LX10_-_1_1* | head -1)" cropped.rw2

xcodebuild -project "$project" -scheme RawInputDemo -destination "id=$device" \
    -derivedDataPath "$derived" DEVELOPMENT_TEAM="$team" -allowProvisioningUpdates \
    test-without-building
