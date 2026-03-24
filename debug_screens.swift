#!/usr/bin/env swift
import Cocoa

// Print all screen information for debugging the portrait monitor coordinate issue
print("=== NSScreen Information ===")
for (i, screen) in NSScreen.screens.enumerated() {
    let f = screen.frame
    print("Screen \(i): frame=(\(f.origin.x), \(f.origin.y), \(f.width), \(f.height)) maxY=\(f.maxY) backingScale=\(screen.backingScaleFactor)")
    if i == 0 {
        print("  ^ This is screens.first (primary / menu bar screen)")
    }
    if screen == NSScreen.main {
        print("  ^ This is NSScreen.main (screen with key window)")
    }
}

let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
let maxYHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0

print("\n=== Coordinate Conversion Comparison ===")
print("primaryHeight (screens.first.frame.height) = \(primaryHeight)")
print("maxYHeight (max of all screens' maxY) = \(maxYHeight)")
print("Difference = \(maxYHeight - primaryHeight)")

for (i, screen) in NSScreen.screens.enumerated() {
    let f = screen.frame
    let cgY_primary = primaryHeight - f.origin.y - f.height
    let cgY_maxY = maxYHeight - f.origin.y - f.height
    print("\nScreen \(i) (\(f.width)x\(f.height)):")
    print("  NS origin: (\(f.origin.x), \(f.origin.y))")
    print("  CG Y using primaryHeight: \(cgY_primary)")
    print("  CG Y using maxYHeight:    \(cgY_maxY)")
    print("  Correct CG Y should be:   \(primaryHeight - f.origin.y - f.height)")
}
