// Draw Tolkara Management's macOS icon from the iPad app's artwork
// (launcher/Assets.xcassets, drawn by tools/make_icon.py): the macOS icon
// grid's rounded square with its drop shadow, at every macOS size.
//   swift tools/make_management_icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("launcher/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
let output = root.appendingPathComponent("management/Assets.xcassets/AppIcon.appiconset")
guard let art = NSImage(contentsOf: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("missing \(source.path)") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    // Apple's grid: an 824-point square inset 100 points, corner radius about 185.
    let square = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: square, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(shape); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fillPath()
    context.restoreGState()
    context.addPath(shape); context.clip()
    context.interpolationQuality = .high
    context.draw(art, in: square)
    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "AppIcon-\(points)@\(scale)x.png"
        try render(points * scale).write(to: output.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(to: output.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(images.count) icons to \(output.path)")
