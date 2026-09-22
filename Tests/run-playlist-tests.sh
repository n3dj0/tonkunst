#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/tonkunst-playlist-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
swiftc -parse-as-library -module-cache-path "$build_dir/modules" \
    Tonkunst/Models/MediaModels.swift Tonkunst/Services/PlaylistLibrary.swift \
    Tests/PlaylistSyncTests.swift -o "$build_dir/playlist-tests"
"$build_dir/playlist-tests"
