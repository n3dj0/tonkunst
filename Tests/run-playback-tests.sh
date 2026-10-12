#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/tonkunst-playback-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
swiftc -parse-as-library -module-cache-path "$build_dir/modules" \
    Tonkunst/Store/PlaybackOrder.swift Tests/PlaybackOrderTests.swift \
    -o "$build_dir/playback-tests"
"$build_dir/playback-tests"
