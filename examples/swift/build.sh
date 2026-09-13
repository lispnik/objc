#!/bin/sh
# Build libLispSwift.dylib beside this script.  Needs Xcode's swiftc; the
# frameworks are linked by their imports.
#
# One slice per architecture, then lipo: the committed library has to load
# on GitHub's Intel runner as well as on Apple silicon, and a single-slice
# arm64 dylib fails there with "incompatible architecture".
set -e
cd "$(dirname "$0")"
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target $arch-apple-macos26.0 \
    -emit-library -module-name LispSwift \
    -o libLispSwift-$arch.dylib LispSwift.swift
done
lipo -create -output libLispSwift.dylib libLispSwift-arm64.dylib libLispSwift-x86_64.dylib
rm -f libLispSwift-arm64.dylib libLispSwift-x86_64.dylib
echo "built $(pwd)/libLispSwift.dylib: $(lipo -archs libLispSwift.dylib)"
