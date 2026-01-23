#!/bin/bash

# Build script for SimpleSwitcher.app
# Creates a proper macOS application bundle

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="SimpleSwitcher"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

# Use debug build by default (more reliable with event tap)
# Pass "release" as argument to use release build
BUILD_CONFIG="${1:-debug}"

echo "Building $APP_NAME ($BUILD_CONFIG)..."

# Clean previous build
rm -rf "$APP_BUNDLE"

# Create app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cd "$PROJECT_DIR"

if [ "$BUILD_CONFIG" = "release" ]; then
    if swift build -c release 2>/dev/null; then
        BINARY=".build/release/$APP_NAME"
        echo "Release build successful"
    elif [ -f ".build/release/$APP_NAME" ]; then
        BINARY=".build/release/$APP_NAME"
        echo "Using existing release build"
    else
        echo "ERROR: Release build failed. Run 'swift build -c release' first."
        exit 1
    fi
else
    if swift build 2>/dev/null; then
        BINARY=".build/debug/$APP_NAME"
        echo "Debug build successful"
    elif [ -f ".build/debug/$APP_NAME" ]; then
        BINARY=".build/debug/$APP_NAME"
        echo "Using existing debug build"
    else
        echo "ERROR: Debug build failed. Run 'swift build' first."
        exit 1
    fi
fi

# Copy binary to app bundle
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/"

# Create PkgInfo file
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo ""
echo "Build complete: $APP_BUNDLE"
echo ""
echo "To install:"
echo "  1. Move to Applications: mv '$APP_BUNDLE' /Applications/"
echo "  2. Grant Input Monitoring permission when prompted"
echo "  3. Add to Login Items in System Settings > General > Login Items"
echo ""
echo "To run directly:"
echo "  open '$APP_BUNDLE'"
