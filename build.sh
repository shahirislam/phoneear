#!/bin/zsh
set -e
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O -swift-version 5 Sources/main.swift -o bin/phoneear \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
codesign -s - -f --identifier com.shahir.phoneear bin/phoneear >/dev/null 2>&1
echo "Built $(pwd)/bin/phoneear"
