import CoreGraphics
import CoreText
import Foundation
import ImageIO

// Rebuild with: swift Design/render-app-icon.swift
// The app icon is geometry and one serif glyph, so the mark stays crisp at small sizes.
let canvasSize = 1024
let center = CGFloat(canvasSize) / 2
let destination = URL(fileURLWithPath: "Tonkunst/Resources/Assets.xcassets/AppIcon.appiconset/tonkunst-icon.png")

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    guard let result = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations) else {
        fatalError("Could not create app icon gradient")
    }
    return result
}

let ink = color(25, 24, 62)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("Could not create app icon canvas")
}

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

let backdrop = gradient(
    [color(20, 19, 52), color(46, 38, 100), color(40, 70, 139)],
    [0, 0.52, 1]
)
context.drawLinearGradient(
    backdrop,
    start: CGPoint(x: 0, y: canvasSize),
    end: CGPoint(x: canvasSize, y: 0),
    options: []
)

let discFrame = CGRect(x: 40, y: 40, width: 944, height: 944)
context.saveGState()
context.setShadow(offset: .zero, blur: 42, color: color(105, 124, 255, 0.55))
context.setFillColor(color(30, 32, 91))
context.fillEllipse(in: discFrame)
context.restoreGState()

context.saveGState()
context.addEllipse(in: discFrame)
context.clip()
let vinyl = gradient(
    [color(53, 45, 109), color(33, 31, 79), color(17, 23, 55)],
    [0, 0.54, 1]
)
context.drawRadialGradient(
    vinyl,
    startCenter: CGPoint(x: 520, y: 530),
    startRadius: 25,
    endCenter: CGPoint(x: center, y: center),
    endRadius: 490,
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)
let sheen = gradient(
    [color(76, 158, 255, 0.3), color(120, 112, 234, 0)],
    [0, 1]
)
context.drawRadialGradient(
    sheen,
    startCenter: CGPoint(x: 770, y: 735),
    startRadius: 0,
    endCenter: CGPoint(x: 770, y: 735),
    endRadius: 620,
    options: []
)
context.restoreGState()

let grooveRadii: [CGFloat] = [220, 277, 334, 391, 448]
context.setLineWidth(24)
context.setStrokeColor(color(105, 112, 240, 0.15))
for radius in grooveRadii {
    context.strokeEllipse(in: CGRect(x: center - radius, y: center - radius, width: radius * 2, height: radius * 2))
}

context.saveGState()
context.setLineWidth(10)
for radius in grooveRadii {
    context.addEllipse(in: CGRect(x: center - radius, y: center - radius, width: radius * 2, height: radius * 2))
}
context.replacePathWithStrokedPath()
context.clip()
let grooves = gradient(
    [color(132, 188, 255, 0.9), color(184, 159, 251, 0.72), color(128, 128, 232, 0.48)],
    [0, 0.55, 1]
)
context.drawLinearGradient(
    grooves,
    start: CGPoint(x: 80, y: 920),
    end: CGPoint(x: 950, y: 70),
    options: []
)
context.restoreGState()

let labelFrame = CGRect(x: center - 165, y: center - 165, width: 330, height: 330)
context.saveGState()
context.setShadow(offset: .zero, blur: 32, color: color(133, 131, 255, 0.43))
context.setFillColor(color(125, 143, 243))
context.fillEllipse(in: labelFrame)
context.restoreGState()

context.saveGState()
context.addEllipse(in: labelFrame)
context.clip()
let centerLabel = gradient(
    [color(86, 158, 253), color(166, 155, 244), color(215, 187, 252)],
    [0, 0.53, 1]
)
context.drawLinearGradient(
    centerLabel,
    start: CGPoint(x: 350, y: 680),
    end: CGPoint(x: 690, y: 340),
    options: []
)
context.restoreGState()

let font = CTFontCreateWithName("Georgia-BoldItalic" as CFString, 295, nil)
let attributes: [CFString: Any] = [
    kCTFontAttributeName: font,
    kCTForegroundColorAttributeName: ink,
]
guard let text = CFAttributedStringCreate(nil, "T" as CFString, attributes as CFDictionary) else {
    fatalError("Could not create center initial")
}
let line = CTLineCreateWithAttributedString(text)
let bounds = CTLineGetImageBounds(line, context)
context.textMatrix = .identity
context.textPosition = CGPoint(
    // Italic overhang makes the measured bounds look centered while the letter reads left-heavy.
    x: center - bounds.midX + 10,
    y: center - bounds.midY - 3
)
CTLineDraw(line, context)

guard let image = context.makeImage(),
      let output = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Could not create PNG output")
}
CGImageDestinationAddImage(output, image, nil)
guard CGImageDestinationFinalize(output) else {
    fatalError("Could not write app icon")
}
