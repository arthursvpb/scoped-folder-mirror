#!/bin/sh
set -eu

destination=${1:-platform=macOS}
test_root=$(mktemp -d)

cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT INT TERM

xcodebuild \
    -project ScopedFolderMirror.xcodeproj \
    -scheme ScopedFolderMirror \
    -destination "$destination" \
    -derivedDataPath "$test_root" \
    CODE_SIGNING_ALLOWED=NO \
    build-for-testing

codesign --force --deep --sign - "$test_root/Build/Products/Debug/ScopedFolderMirror.app"
codesign --force --deep --sign - "$test_root/Build/Products/Debug/ScopedFolderMirrorUITests-Runner.app"

xcodebuild \
    -project ScopedFolderMirror.xcodeproj \
    -scheme ScopedFolderMirror \
    -destination "$destination" \
    -derivedDataPath "$test_root" \
    CODE_SIGNING_ALLOWED=NO \
    test-without-building
