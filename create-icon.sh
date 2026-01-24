#!/bin/bash

# Create an app icon from an emoji using macOS built-in tools
# Usage: ./create-icon.sh [emoji]
# Default emoji: ⌘

set -e

EMOJI="${1:-⌘}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICONSET_DIR="$PROJECT_DIR/AppIcon.iconset"
ICNS_FILE="$PROJECT_DIR/AppIcon.icns"
TEMP_SWIFT="$PROJECT_DIR/.icon_generator.swift"

echo "Creating icon from emoji: $EMOJI"

# Create iconset directory
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Create Swift script
cat > "$TEMP_SWIFT" << 'SWIFT_END'
import Cocoa

let args = CommandLine.arguments
let emoji = args.count > 1 ? args[1] : "⌘"
let iconsetPath = args.count > 2 ? args[2] : "AppIcon.iconset"

// Icon sizes: (filename, size)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (filename, size) in sizes {
    let cgSize = CGFloat(size)
    let image = NSImage(size: NSSize(width: cgSize, height: cgSize))

    image.lockFocus()

    // Draw rounded rect background
    let rect = NSRect(x: 0, y: 0, width: cgSize, height: cgSize)
    let cornerRadius = cgSize * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor(white: 0.15, alpha: 1.0).setFill()
    path.fill()

    // Draw emoji
    let fontSize = cgSize * 0.55
    let font = NSFont.systemFont(ofSize: fontSize)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white
    ]

    let textSize = emoji.size(withAttributes: attributes)
    let textRect = NSRect(
        x: (cgSize - textSize.width) / 2,
        y: (cgSize - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
    )
    emoji.draw(in: textRect, withAttributes: attributes)

    image.unlockFocus()

    // Save as PNG
    if let tiffData = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiffData),
       let pngData = bitmap.representation(using: .png, properties: [:]) {
        let url = URL(fileURLWithPath: iconsetPath).appendingPathComponent(filename)
        try? pngData.write(to: url)
        print("Created \(filename)")
    }
}
SWIFT_END

# Run the Swift script
echo "Generating PNG files..."
swiftc -o "$PROJECT_DIR/.icon_generator" "$TEMP_SWIFT" -framework Cocoa
"$PROJECT_DIR/.icon_generator" "$EMOJI" "$ICONSET_DIR"

# Clean up Swift files
rm -f "$TEMP_SWIFT" "$PROJECT_DIR/.icon_generator"

# Create icns file from iconset
echo "Creating .icns file..."
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_FILE"

# Clean up iconset directory
rm -rf "$ICONSET_DIR"

echo ""
echo "Icon created: $ICNS_FILE"
