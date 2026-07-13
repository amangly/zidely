#!/bin/sh
# Builds the macOS proto-shell. Needs Command Line Tools only.
set -e
cd "$(dirname "$0")"
xcrun swiftc -O main.swift -o zide-shell
echo "built: $(pwd)/zide-shell"
