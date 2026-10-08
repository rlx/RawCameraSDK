#!/bin/sh
# Records the demo walkthrough in the iOS simulator and turns it into the README's GIF.
#
#     Examples/RawInputDemo/Scripts/record-demo.sh [simulator name]
#
# The UI test in UITests/WalkthroughTests.swift drives the app while `simctl` records the
# screen, so the recording is reproducible and always shows the current build.
set -eu
cd "$(dirname "$0")/.."
simulator=${1:-iPhone 17 Pro}
derived=../../.build/demo
movie=$(mktemp -d)/walkthrough.mov

xcrun simctl boot "$simulator" 2>/dev/null || true
xcodebuild build-for-testing -project RawInputDemo.xcodeproj -scheme RawInputDemoUITests \
    -destination "platform=iOS Simulator,name=$simulator" -derivedDataPath "$derived" -quiet

xcrun simctl io "$simulator" recordVideo --codec h264 --force "$movie" &
recorder=$!
sleep 2
xcodebuild test-without-building -project RawInputDemo.xcodeproj -scheme RawInputDemoUITests \
    -destination "platform=iOS Simulator,name=$simulator" -derivedDataPath "$derived" -quiet || status=$?
# SIGINT is how simctl is told to finish the file cleanly.
kill -INT "$recorder"
wait "$recorder" 2>/dev/null || true

swift Scripts/movie-to-gif.swift "$movie" ../../Docs/walkthrough.gif
exit "${status:-0}"
