#!/bin/sh
# Builds the macOS browser host prototype. Needs Command Line Tools only.
set -e
cd "$(dirname "$0")"
xcrun swiftc -O main.swift -o zide-browser-host
echo "built: $(pwd)/zide-browser-host"
