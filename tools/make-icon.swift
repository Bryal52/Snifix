// Turns the logo (rounded square on a black background) into a macOS icon:
// black around the shape becomes transparent, the shape is fitted to the 824/1024 icon grid.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("usage: make-icon in.png out.png") }
let w = image.width, h = image.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

// Brightness ramp: pure black background → transparent, the dark square body (≈ 14/255) → opaque
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let lum = max(pixels[i], pixels[i + 1], pixels[i + 2])
        let a = min(1.0, max(0.0, (Double(lum) - 3) / 7))
        pixels[i] = UInt8(Double(pixels[i]) * a)
        pixels[i + 1] = UInt8(Double(pixels[i + 1]) * a)
        pixels[i + 2] = UInt8(Double(pixels[i + 2]) * a)
        pixels[i + 3] = UInt8(a * 255)
        if a > 0.5 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
    }
}
let cut = ctx.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
let out = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.interpolationQuality = .high
out.draw(cut, in: CGRect(x: 100, y: 100, width: 824, height: 824))
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("bbox \(minX),\(minY) – \(maxX),\(maxY)")
