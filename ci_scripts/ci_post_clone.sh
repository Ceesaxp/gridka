#!/bin/bash
# Xcode Cloud post-clone hook: download DuckDB before building
set -euo pipefail

echo "Running ci_post_clone: downloading DuckDB dylib..."
bash "$CI_PRIMARY_REPOSITORY_PATH/Libraries/download-duckdb.sh"
