#!/bin/bash
# Xcode Cloud post-clone hook: download DuckDB and generate Xcode project
set -euo pipefail

echo "Running ci_post_clone: downloading DuckDB dylib..."
bash "$CI_PRIMARY_REPOSITORY_PATH/Libraries/download-duckdb.sh"

echo "Installing XcodeGen..."
brew install xcodegen

echo "Generating Xcode project from project.yml..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
