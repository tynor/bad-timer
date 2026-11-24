#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
zig build native -Doptimize=ReleaseSmall
app="build/Bad Timer.app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -parse-as-library -import-objc-header macos/Bridge.h macos/BadTimer.swift \
  -L zig-out/lib -lbad_timer_core -framework SwiftUI -framework AppKit \
  -framework CoreFoundation -o "$app/Contents/MacOS/BadTimer"
cp macos/Info.plist "$app/Contents/Info.plist"
printf 'Built %s\n' "$app"
