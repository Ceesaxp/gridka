#!/usr/bin/env bash
set -euo pipefail

# Bump version numbers in project.yml.
#
# Usage:
#   ./scripts/bump-version.sh 1.0.1          # Set marketing version + reset build to 1
#   ./scripts/bump-version.sh 1.0.1 --build  # Set marketing version + increment build
#   ./scripts/bump-version.sh --build         # Increment build number only

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_YML="$SCRIPT_DIR/../project.yml"

if [ ! -f "$PROJECT_YML" ]; then
    echo "Error: project.yml not found at $PROJECT_YML"
    exit 1
fi

NEW_VERSION=""
BUMP_BUILD=false

for arg in "$@"; do
    case "$arg" in
        --build)
            BUMP_BUILD=true
            ;;
        --help|-h)
            echo "Usage: $0 [VERSION] [--build]"
            echo "  VERSION      Set MARKETING_VERSION (e.g. 1.0.1)"
            echo "  --build      Increment CURRENT_PROJECT_VERSION"
            echo ""
            echo "Examples:"
            echo "  $0 1.0.1          # Set version to 1.0.1, reset build to 1"
            echo "  $0 1.0.1 --build  # Set version to 1.0.1, increment build"
            echo "  $0 --build        # Increment build number only"
            exit 0
            ;;
        *)
            if [[ "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                NEW_VERSION="$arg"
            else
                echo "Error: Invalid version format '$arg'. Expected X.Y.Z"
                exit 1
            fi
            ;;
    esac
done

if [ -z "$NEW_VERSION" ] && [ "$BUMP_BUILD" = false ]; then
    echo "Error: Provide a version number and/or --build flag."
    echo "Run '$0 --help' for usage."
    exit 1
fi

# Get current values
CURRENT_VERSION=$(grep 'MARKETING_VERSION:' "$PROJECT_YML" | head -1 | sed 's/.*: *"\(.*\)"/\1/')
CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | head -1 | sed 's/.*: *"\(.*\)"/\1/')

echo "Current: v${CURRENT_VERSION} (build ${CURRENT_BUILD})"

# Update marketing version
if [ -n "$NEW_VERSION" ]; then
    sed -i '' "s/MARKETING_VERSION: \"${CURRENT_VERSION}\"/MARKETING_VERSION: \"${NEW_VERSION}\"/g" "$PROJECT_YML"
    echo "Version: ${CURRENT_VERSION} -> ${NEW_VERSION}"

    # Reset build to 1 unless --build is specified
    if [ "$BUMP_BUILD" = false ]; then
        sed -i '' "s/CURRENT_PROJECT_VERSION: \"${CURRENT_BUILD}\"/CURRENT_PROJECT_VERSION: \"1\"/g" "$PROJECT_YML"
        echo "Build:   ${CURRENT_BUILD} -> 1 (reset)"
    fi
fi

# Increment build number
if [ "$BUMP_BUILD" = true ]; then
    NEW_BUILD=$((CURRENT_BUILD + 1))
    sed -i '' "s/CURRENT_PROJECT_VERSION: \"${CURRENT_BUILD}\"/CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"/g" "$PROJECT_YML"
    echo "Build:   ${CURRENT_BUILD} -> ${NEW_BUILD}"
fi

# Show result
FINAL_VERSION=$(grep 'MARKETING_VERSION:' "$PROJECT_YML" | head -1 | sed 's/.*: *"\(.*\)"/\1/')
FINAL_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | head -1 | sed 's/.*: *"\(.*\)"/\1/')
echo "Result:  v${FINAL_VERSION} (build ${FINAL_BUILD})"
