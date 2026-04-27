#!/usr/bin/env swift
//
// Print the average RGB of a PNG (or a rectangular region of it) to stdout.
// Output format: "R G B" with integer 0-255 channel values, space-separated.
//
// Usage:
//   sample-rgb.swift <png>
//   sample-rgb.swift <png> <x> <y> <w> <h>
//
// We rely on this from check-icons.sh because the system Python on recent
// macOS is externally-managed (PEP 668) and we can't depend on Pillow.
import Cocoa
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 2 || args.count == 6 else {
    FileHandle.standardError.write("usage: sample-rgb.swift <png> [x y w h]\n".data(using: .utf8)!)
    exit(2)
}

let path = args[1]
guard let dataProvider = CGDataProvider(filename: path),
      let cg = CGImage(pngDataProviderSource: dataProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
    FileHandle.standardError.write("could not decode \(path)\n".data(using: .utf8)!)
    exit(1)
}

let w = cg.width, h = cg.height

// Region defaults to the whole image.
var rx = 0, ry = 0, rw = w, rh = h
if args.count == 6 {
    rx = Int(args[2]) ?? 0
    ry = Int(args[3]) ?? 0
    rw = Int(args[4]) ?? w
    rh = Int(args[5]) ?? h
}
rx = max(0, min(rx, w - 1))
ry = max(0, min(ry, h - 1))
rw = max(1, min(rw, w - rx))
rh = max(1, min(rh, h - ry))

// Render the whole PNG into a fixed RGBA buffer so the per-pixel layout is known.
let bytesPerRow = w * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
let cs = CGColorSpaceCreateDeviceRGB()
let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
guard let ctx = pixels.withUnsafeMutableBufferPointer({ buf -> CGContext? in
    CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs, bitmapInfo: info)
}) else {
    FileHandle.standardError.write("could not create CGContext\n".data(using: .utf8)!)
    exit(1)
}
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

var rSum = 0, gSum = 0, bSum = 0, n = 0
for y in ry..<(ry + rh) {
    for x in rx..<(rx + rw) {
        let idx = y * bytesPerRow + x * 4
        rSum += Int(pixels[idx])
        gSum += Int(pixels[idx + 1])
        bSum += Int(pixels[idx + 2])
        n += 1
    }
}

print("\(rSum / n) \(gSum / n) \(bSum / n)")
