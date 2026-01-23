#!/bin/bash

# Build script for SimpleSwitcher.app
# Creates a proper macOS application bundle

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="SimpleSwitcher"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# Clean previous build
rm -rf "$APP_BUNDLE"

# Create app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Try to build release binary
echo "Compiling release binary..."
cd "$PROJECT_DIR"

if swift build -c release 2>/dev/null; then
    BINARY=".build/release/$APP_NAME"
    echo "Release build successful"
elif [ -f ".build/release/$APP_NAME" ]; then
    BINARY=".build/release/$APP_NAME"
    echo "Using existing release build"
elif [ -f ".build/debug/$APP_NAME" ]; then
    BINARY=".build/debug/$APP_NAME"
    echo "Using existing debug build (run 'swift build -c release' manually for optimized build)"
else
    echo "ERROR: No binary found. Run 'swift build' first."
    exit 1
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
