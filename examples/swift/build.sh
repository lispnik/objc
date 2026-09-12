#!/bin/sh
# Build libLispSwift.dylib beside this script.  Needs Xcode's swiftc; the
# frameworks are linked by their imports.
set -e
cd "$(dirname "$0")"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  -emit-library -module-name LispSwift \
  -o libLispSwift.dylib LispSwift.swift
echo "built $(pwd)/libLispSwift.dylib"
