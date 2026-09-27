// Renders the take app icon: an LED panel, a 9:16 frame of lit dots, one red dot recording.
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

// macOS grid: 824 body, 100 inset, continuous corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).cgPath

// drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(shape); ctx.setFillColor(rgb(0x09090B)); ctx.fillPath()
ctx.restoreGState()

// body gradient
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let g = CGGradient(colorsSpace: cs, colors: [rgb(0x1F1F23), rgb(0x0B0B0D)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

// LED grid: pitch 36, 21 x 21, centred
let n = 21, pitch: CGFloat = 36, r: CGFloat = 8.5
let origin = CGPoint(x: S / 2 - CGFloat(n - 1) * pitch / 2, y: S / 2 - CGFloat(n - 1) * pitch / 2)
func center(_ c: Int, _ row: Int) -> CGPoint { CGPoint(x: origin.x + CGFloat(c) * pitch, y: origin.y + CGFloat(row) * pitch) }

// frame 9 wide x 16 tall (in dots, outline), centred
let fw = 9, fh = 16
let c0 = (n - fw) / 2, r0 = (n - fh) / 2
func onFrame(_ c: Int, _ row: Int) -> Bool {
    let inX = c >= c0 && c < c0 + fw, inY = row >= r0 && row < r0 + fh
    guard inX && inY else { return false }
    return c == c0 || c == c0 + fw - 1 || row == r0 || row == r0 + fh - 1
}
let rec = (c: c0 + fw - 3, row: r0 + fh - 3)   // top right inside the frame (y is up)

for row in 0..<n {
    for c in 0..<n {
        let p = center(c, row)
        let dot = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        if c == rec.c && row == rec.row { continue }
        let safe = NSBezierPath(roundedRect: body.insetBy(dx: 34, dy: 34), xRadius: 151, yRadius: 151).cgPath
        if ![CGPoint(x: dot.minX, y: p.y), CGPoint(x: dot.maxX, y: p.y), CGPoint(x: p.x, y: dot.minY), CGPoint(x: p.x, y: dot.maxY),
             CGPoint(x: dot.minX + 2.5, y: dot.minY + 2.5), CGPoint(x: dot.maxX - 2.5, y: dot.maxY - 2.5),
             CGPoint(x: dot.minX + 2.5, y: dot.maxY - 2.5), CGPoint(x: dot.maxX - 2.5, y: dot.minY + 2.5)].allSatisfy({ safe.contains($0) }) { continue }
        if onFrame(c, row) {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 14, color: rgb(0xFFFFFF, 0.35))
            ctx.setFillColor(rgb(0xF4F4F5))
            ctx.fillEllipse(in: dot)
            ctx.restoreGState()
        } else {
            ctx.setFillColor(rgb(0xFFFFFF, 0.07))
            ctx.fillEllipse(in: dot)
        }
    }
}

// the one red dot
let rp = center(rec.c, rec.row)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: rgb(0xFF3B30, 1))
let halo = CGGradient(colorsSpace: cs, colors: [rgb(0xFF3B30, 0.45), rgb(0xFF3B30, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(halo, startCenter: rp, startRadius: 0, endCenter: rp, endRadius: r * 5, options: [])
ctx.setFillColor(rgb(0xFF3B30))
ctx.fillEllipse(in: CGRect(x: rp.x - r * 1.35, y: rp.y - r * 1.35, width: r * 2.7, height: r * 2.7))
ctx.restoreGState()
ctx.setFillColor(rgb(0xFF6B61))
ctx.fillEllipse(in: CGRect(x: rp.x - r * 0.55, y: rp.y - r * 0.1, width: r * 0.9, height: r * 0.9))

// top highlight + hairline
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.10)); ctx.setLineWidth(2)
ctx.strokePath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
