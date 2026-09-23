import CoreGraphics
import CoreText
import Foundation

/// Writes the Finder DMG background as a PDF made only of vector drawing
/// commands. Finder receives this PDF directly; it is never rasterised.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: makeDmgBackground.swift OUTPUT.pdf\n", stderr)
    exit(64)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
var mediaBox = CGRect(x: 0, y: 0, width: 660, height: 360)
guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
    fputs("Unable to create PDF background: \(output.path)\n", stderr)
    exit(1)
}

context.beginPDFPage(nil)
context.setFillColor(CGColor(red: 0.961, green: 0.961, blue: 0.969, alpha: 1))
context.fill(mediaBox)

let instruction = "请将左边的图标拖入右边的文件夹"
let instructionFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, 14, nil)
let instructionColor = CGColor(red: 0.235, green: 0.235, blue: 0.247, alpha: 1)
let instructionAttributes: [CFString: Any] = [
    kCTFontAttributeName: instructionFont,
    kCTForegroundColorAttributeName: instructionColor,
]
let instructionLine = CTLineCreateWithAttributedString(
    CFAttributedStringCreate(
        kCFAllocatorDefault,
        instruction as CFString,
        instructionAttributes as CFDictionary
    )!
)
let instructionWidth = CGFloat(CTLineGetTypographicBounds(instructionLine, nil, nil, nil))
// This is still in Quartz's native bottom-left coordinates: a 286pt baseline
// from SVG/Finder's top edge places the instruction below both icons.
context.textPosition = CGPoint(x: (mediaBox.width - instructionWidth) / 2, y: 74)
CTLineDraw(instructionLine, context)

// Finder/SVG layout coordinates start at the top-left. Quartz PDF drawing
// starts at the bottom-left, so flip only the authored arrow geometry.
context.translateBy(x: 0, y: mediaBox.height)
context.scaleBy(x: 1, y: -1)

let arrowColor = CGColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)
context.setStrokeColor(arrowColor)
context.setLineWidth(4)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: 280, y: 145))
context.addLine(to: CGPoint(x: 380, y: 145))
context.strokePath()
context.move(to: CGPoint(x: 365, y: 130))
context.addLine(to: CGPoint(x: 380, y: 145))
context.addLine(to: CGPoint(x: 365, y: 160))
context.strokePath()

context.endPDFPage()
context.closePDF()

// Do not rely on Spotlight indexing timing during packaging. CoreGraphics is
// the same stack used to create the PDF and can deterministically verify its
// page geometry immediately after closing the file.
guard let document = CGPDFDocument(output as CFURL),
      document.numberOfPages == 1,
      let page = document.page(at: 1) else {
    fputs("Generated DMG background is not a readable one-page PDF.\n", stderr)
    exit(1)
}
let verifiedBox = page.getBoxRect(.mediaBox)
guard abs(verifiedBox.width - 660) < 0.001,
      abs(verifiedBox.height - 360) < 0.001 else {
    fputs("Generated DMG background has an unexpected page size.\n", stderr)
    exit(1)
}
