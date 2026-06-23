import Foundation
import AppKit
import CoreGraphics
import CoreImage

let canvasSize = CGSize(width: 2880, height: 1800)
let scaleFactor: CGFloat = 0.78
let cornerRadius: CGFloat = 24
let shadowBlur: CGFloat = 60
let shadowOffsetY: CGFloat = 30
let shadowAlpha: CGFloat = 0.25

let gradientTop = CGColor(red: 0.93, green: 0.91, blue: 0.97, alpha: 1.0)
let gradientBottom = CGColor(red: 0.97, green: 0.91, blue: 0.94, alpha: 1.0)

func loadCGImage(_ path: String) -> CGImage? {
    guard let url = URL(string: "file://" + path) as CFURL?,
          let src = CGImageSourceCreateWithURL(url, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return img
}

func saveCGImage(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

func compose(inputPath: String, outputPath: String) -> Bool {
    guard let src = loadCGImage(inputPath) else {
        print("FAIL load \(inputPath)")
        return false
    }

    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: Int(canvasSize.width),
        height: Int(canvasSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }

    // gradient background — diagonal top-left → bottom-right
    let gradient = CGGradient(
        colorsSpace: cs,
        colors: [gradientTop, gradientBottom] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: canvasSize.height),
        end: CGPoint(x: canvasSize.width, y: 0),
        options: []
    )

    // compute window placement: scale to fit within scaleFactor * canvas
    let srcW = CGFloat(src.width)
    let srcH = CGFloat(src.height)
    let maxW = canvasSize.width * scaleFactor
    let maxH = canvasSize.height * scaleFactor
    let scale = min(maxW / srcW, maxH / srcH)
    let drawW = srcW * scale
    let drawH = srcH * scale
    let originX = (canvasSize.width - drawW) / 2
    let originY = (canvasSize.height - drawH) / 2
    let rect = CGRect(x: originX, y: originY, width: drawW, height: drawH)

    // shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -shadowOffsetY),
        blur: shadowBlur,
        color: CGColor(gray: 0, alpha: shadowAlpha)
    )

    // rounded-rect clip path for the window image
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(src, in: rect)
    ctx.restoreGState()

    guard let out = ctx.makeImage() else { return false }
    return saveCGImage(out, to: outputPath)
}

// MARK: - Driver

let args = CommandLine.arguments
if args.count == 3 {
    let ok = compose(inputPath: args[1], outputPath: args[2])
    exit(ok ? 0 : 1)
} else {
    print("usage: swift _compose.swift <input.png> <output.png>")
    exit(2)
}
