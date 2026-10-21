#!/bin/sh
# Builds .build/scalebench (Homebrew libwebp 1.6.0 = the vendored CWebP version, libjxl, zstd, lz4) and the corpus renderer.
set -e
cd "$(dirname "$0")"
mkdir -p .build
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.0-Beta.app/Contents/Developer}"
B=/opt/homebrew
clang -O2 -std=c11 -Wall -Wno-unused-function -I$B/include -o .build/scalebench scalebench.c -L$B/lib -lwebp -lsharpyuv -lzstd -llz4 -ljxl \
  -framework ImageIO -framework CoreGraphics -framework CoreFoundation
swiftc -O -parse-as-library -framework AppKit -o .build/render corpus/render.swift ../testbench/scenes.swift
swiftc -O -o .build/jxlcheck jxlcheck.swift 2>/dev/null || true
