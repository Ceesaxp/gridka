#!/bin/bash
# Downloads DuckDB macOS universal library for Gridka
# Run this script before building if Libraries/libduckdb.dylib is missing

set -euo pipefail

DUCKDB_VERSION="v1.2.1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DYLIB_PATH="$SCRIPT_DIR/libduckdb.dylib"
HEADER_PATH="$SCRIPT_DIR/duckdb.h"

if [ -f "$DYLIB_PATH" ] && [ -f "$HEADER_PATH" ]; then
    echo "DuckDB library already exists at $DYLIB_PATH"
    exit 0
fi

echo "Downloading DuckDB $DUCKDB_VERSION for macOS (universal)..."
TEMP_DIR=$(mktemp -d)
curl -L -o "$TEMP_DIR/libduckdb-osx-universal.zip" \
    "https://github.com/duckdb/duckdb/releases/download/$DUCKDB_VERSION/libduckdb-osx-universal.zip"

echo "Extracting..."
unzip -o "$TEMP_DIR/libduckdb-osx-universal.zip" -d "$SCRIPT_DIR"
rm -rf "$TEMP_DIR"

# Remove C++ header we don't need
rm -f "$SCRIPT_DIR/duckdb.hpp"

echo "DuckDB $DUCKDB_VERSION installed to $SCRIPT_DIR"
ls -la "$DYLIB_PATH" "$HEADER_PATH"
