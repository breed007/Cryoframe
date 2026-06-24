//
//  make-icon.swift — draws the Cryoframe app icon at a given pixel size.
//  usage: swift make-icon.swift <size> <output.png>
//
//  concept: a silver hard drive sealed inside a frost-blue cryo capsule.
//  large sizes get the full drive (platter, bevel, screws, status LED); small
//  sizes (<128px) use a bold, simplified version that stays legible in the dock.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let size = args.count > 1 ? (Int(args[1]) ?? 1024) : 1024
let outPath = args.count > 2 ? args[2] : "icon_\(size).png"
let minimal = size < 128

let S = Double(size)
func F(_ f: Double) -> CGFloat { CGFloat(f * S) }
func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: F(x), y: F(y)) }

let cs = CGColorSpaceCreateDeviceRGB()
func rgb(_ hex: Int, _ a: Double = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: CGFloat(a))
}
func rrect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> CGPath {
    CGPath(roundedRect: CGRect(x: F(x), y: F(y), width: F(w), height: F(h)),
           cornerWidth: F(r), cornerHeight: F(r), transform: nil)
}

let cyan       = rgb(0x34D6FF)
let cyanBold   = rgb(0x3FDCFF)
let capsuleFill = rgb(0x0B2030)
let driveBody  = rgb(0xCFD5DB)
let driveBevel = rgb(0xE9EDF1)
let driveEdge  = rgb(0x9AA3AC)
let platter    = rgb(0xB9C0C8)
let spindle    = rgb(0x7F8790)
let screw      = rgb(0x8A929B)

guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("ctx") }
ctx.interpolationQuality = .high

// background squircle ------------------------------------------------------
ctx.saveGState()
ctx.addPath(rrect(0.09, 0.09, 0.82, 0.82, 0.184)); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x0B1826), rgb(0x05090F)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: P(0, 0.91), end: P(0, 0.09), options: [])
ctx.restoreGState()

// cryo capsule with cyan glow ---------------------------------------------
let capX = 0.29, capY = 0.165, capW = 0.42, capH = 0.67, capR = 0.18
ctx.saveGState()
ctx.addPath(rrect(capX, capY, capW, capH, capR)); ctx.setFillColor(capsuleFill); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: F(0.022), color: cyan.copy(alpha: 0.55)!)
ctx.addPath(rrect(capX, capY, capW, capH, capR))
ctx.setStrokeColor(minimal ? cyanBold : cyan); ctx.setLineWidth(F(minimal ? 0.05 : 0.026)); ctx.strokePath()
ctx.restoreGState()

// left glass sheen
ctx.saveGState()
ctx.addPath(rrect(capX, capY, capW, capH, capR)); ctx.clip()
ctx.addPath(rrect(0.325, 0.21, 0.055, 0.57, 0.027)); ctx.setFillColor(rgb(0xFFFFFF, 0.07)); ctx.fillPath()
ctx.restoreGState()

// the drive (specimen) -----------------------------------------------------
let dX = 0.37, dY = 0.31, dW = 0.26, dH = 0.38, dR = 0.035
let drive = rrect(dX, dY, dW, dH, dR)
ctx.addPath(drive); ctx.setFillColor(driveBody); ctx.fillPath()

// bevel highlight along the visual top (higher y in CG space)
ctx.saveGState()
ctx.addPath(drive); ctx.clip()
ctx.setFillColor(driveBevel); ctx.fill(CGRect(x: F(dX), y: F(dY + dH - 0.085), width: F(dW), height: F(0.085)))
ctx.restoreGState()

ctx.addPath(drive); ctx.setStrokeColor(driveEdge); ctx.setLineWidth(F(minimal ? 0.006 : 0.004)); ctx.strokePath()

if minimal {
    // one seam + LED, nothing finer
    ctx.setStrokeColor(driveEdge); ctx.setLineWidth(F(0.006))
    ctx.move(to: P(dX + 0.04, 0.46)); ctx.addLine(to: P(dX + dW - 0.04, 0.46)); ctx.strokePath()
    ctx.setFillColor(cyanBold); ctx.fillEllipse(in: CGRect(x: F(dX + dW - 0.075), y: F(dY + dH - 0.075), width: F(0.034), height: F(0.034)))
} else {
    // platter
    let pr = 0.066
    ctx.setFillColor(platter)
    ctx.fillEllipse(in: CGRect(x: F(0.5 - pr), y: F(0.5 - pr), width: F(pr * 2), height: F(pr * 2)))
    ctx.setStrokeColor(driveEdge); ctx.setLineWidth(F(0.0035))
    ctx.strokeEllipse(in: CGRect(x: F(0.5 - pr), y: F(0.5 - pr), width: F(pr * 2), height: F(pr * 2)))
    ctx.setStrokeColor(rgb(0xAAB2BB)); ctx.setLineWidth(F(0.003))
    ctx.strokeEllipse(in: CGRect(x: F(0.5 - pr * 0.6), y: F(0.5 - pr * 0.6), width: F(pr * 1.2), height: F(pr * 1.2)))
    ctx.setFillColor(spindle)
    ctx.fillEllipse(in: CGRect(x: F(0.5 - 0.016), y: F(0.5 - 0.016), width: F(0.032), height: F(0.032)))

    // corner screws
    ctx.setFillColor(screw)
    for (sx, sy) in [(dX + 0.03, dY + 0.03), (dX + dW - 0.03, dY + 0.03),
                     (dX + 0.03, dY + dH - 0.03), (dX + dW - 0.03, dY + dH - 0.03)] {
        ctx.fillEllipse(in: CGRect(x: F(sx - 0.011), y: F(sy - 0.011), width: F(0.022), height: F(0.022)))
    }
    // status LED near the visual top-right
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: F(0.014), color: cyan)
    ctx.setFillColor(cyan)
    ctx.fillEllipse(in: CGRect(x: F(dX + dW - 0.085), y: F(dY + dH - 0.085), width: F(0.03), height: F(0.03)))
    ctx.restoreGState()
}

// write png ----------------------------------------------------------------
guard let img = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else { fatalError("png") }
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath) (\(size)px, \(minimal ? "minimal" : "detailed"))")
