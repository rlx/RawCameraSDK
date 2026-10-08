#!/bin/sh
# Runs the test suite on a connected iPhone or iPad.
#
#     Scripts/device-tests.sh <device-udid> <development-team-id>
#
# `xcrun devicectl list devices` shows the UDID. The team ID is the ten-character code of
# the Apple developer team that signs the build; a free personal team works.
#
# A device cannot run a Swift package's tests directly, so the same test sources are built
# into a bundle hosted by the demo app (the RawInputDemoTests target). The ten samples ride
# along inside the app; the two reference files are copied into its Documents folder here.
set -eu
device=$1
team=$2
cd "$(dirname "$0")/.."
project=Examples/RawInputDemo/RawInputDemo.xcodeproj
derived=.build/device

Examples/RawInputDemo/Scripts/fetch-samples.sh
Scripts/corpus.py fetch --only "ILCE-9M3_-_14bit_(3_2)" "DMC-LX10_-_1_1" > /dev/null

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
copy "$(ls Tests/Corpus/*ILCE-9M3_-_14bit_\(3_2\)* | head -1)" reference.arw
copy "$(ls Tests/Corpus/*DMC-LX10_-_1_1* | head -1)" cropped.rw2

xcodebuild -project "$project" -scheme RawInputDemo -destination "id=$device" \
    -derivedDataPath "$derived" DEVELOPMENT_TEAM="$team" -allowProvisioningUpdates \
    test-without-building
