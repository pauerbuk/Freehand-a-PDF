// Disegna l'icona dell'app: un foglio da disegno vettoriale "FH" che diventa una pagina PDF.
// Uso: swift icona.swift cartella.iconset anteprima.png
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }

func label(_ c: CGContext, _ s: String, size: CGFloat, center: CGPoint, color: CGColor, spacing: CGFloat = 0) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color, .init(kCTKernAttributeName as String): spacing]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    let box = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    c.textPosition = CGPoint(x: center.x - box.midX, y: center.y - box.midY)
    CTLineDraw(line, c)
}

// Tutto è disegnato su una griglia 1024 e poi scalato; sotto i 64 punti spariscono i dettagli fini.
func draw(_ c: CGContext, pixels: CGFloat) {
    let simple = pixels < 64
    c.scaleBy(x: pixels/1024, y: pixels/1024)

    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: rgb(0, 0, 0, 0.32))
    c.addPath(platePath); c.setFillColor(rgb(20, 60, 130)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(platePath); c.clip()
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(44, 110, 214), rgb(15, 48, 112)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(sky, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 700, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()

    // A sinistra: "FH" sotto una curva di Bézier con le maniglie, il gesto tipico del disegno vettoriale.
    let white = rgb(255, 255, 255)
    if simple {
        label(c, "FH", size: 300, center: CGPoint(x: 322, y: 512), color: white, spacing: -8)
    } else {
        let a = CGPoint(x: 168, y: 610), b = CGPoint(x: 476, y: 700)
        let h1 = CGPoint(x: 250, y: 835), h2 = CGPoint(x: 380, y: 500)
        c.setStrokeColor(rgb(255, 255, 255, 0.65)); c.setLineWidth(7)
        c.strokeLineSegments(between: [a, h1, b, h2])
        c.setFillColor(rgb(255, 208, 70))
        for h in [h1, h2] { c.fillEllipse(in: CGRect(x: h.x-16, y: h.y-16, width: 32, height: 32)) }
        c.setStrokeColor(white); c.setLineWidth(17); c.setLineCap(.round)
        c.move(to: a); c.addCurve(to: b, control1: h1, control2: h2); c.strokePath()
        c.setFillColor(white)
        for p in [a, b] { c.fill(CGRect(x: p.x-22, y: p.y-22, width: 44, height: 44)) }
        label(c, "FH", size: 214, center: CGPoint(x: 322, y: 392), color: white, spacing: -4)
    }

    // A destra: la pagina PDF con l'angolo piegato, leggermente inclinata.
    c.saveGState()
    c.translateBy(x: 680, y: 512); c.rotate(by: -0.05)
    let w: CGFloat = 330, h: CGFloat = 450, fold: CGFloat = 96
    let page = CGMutablePath()
    page.move(to: CGPoint(x: -w/2+24, y: -h/2))
    page.addLine(to: CGPoint(x: w/2-24, y: -h/2))
    page.addQuadCurve(to: CGPoint(x: w/2, y: -h/2+24), control: CGPoint(x: w/2, y: -h/2))
    page.addLine(to: CGPoint(x: w/2, y: h/2-fold))
    page.addLine(to: CGPoint(x: w/2-fold, y: h/2))
    page.addLine(to: CGPoint(x: -w/2+24, y: h/2))
    page.addQuadCurve(to: CGPoint(x: -w/2, y: h/2-24), control: CGPoint(x: -w/2, y: h/2))
    page.addLine(to: CGPoint(x: -w/2, y: -h/2+24))
    page.addQuadCurve(to: CGPoint(x: -w/2+24, y: -h/2), control: CGPoint(x: -w/2, y: -h/2))
    page.closeSubpath()
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0, 0, 0, 0.4))
    c.addPath(page); c.setFillColor(white); c.fillPath()
    c.restoreGState()
    c.move(to: CGPoint(x: w/2, y: h/2-fold))
    c.addLine(to: CGPoint(x: w/2-fold+12, y: h/2-fold))
    c.addQuadCurve(to: CGPoint(x: w/2-fold, y: h/2-fold+12), control: CGPoint(x: w/2-fold, y: h/2-fold))
    c.addLine(to: CGPoint(x: w/2-fold, y: h/2))
    c.closePath(); c.setFillColor(rgb(202, 212, 226)); c.fillPath()
    let band = CGRect(x: -w/2-22, y: -92, width: w+44, height: 158)
    c.addPath(CGPath(roundedRect: band, cornerWidth: 22, cornerHeight: 22, transform: nil))
    c.setFillColor(rgb(216, 34, 44)); c.fillPath()
    label(c, "PDF", size: 124, center: CGPoint(x: 0, y: -13), color: white, spacing: 2)
    if !simple {
        c.setFillColor(rgb(202, 212, 226))
        for (i, width) in [230, 190].enumerated() {
            c.addPath(CGPath(roundedRect: CGRect(x: -115, y: -175 - CGFloat(i)*36, width: CGFloat(width), height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil)); c.fillPath()
        }
        c.addPath(CGPath(roundedRect: CGRect(x: -115, y: 110, width: 150, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil)); c.fillPath()
    }
    c.restoreGState()
}

func render(_ pixels: Int) -> CGImage {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(c, pixels: CGFloat(pixels))
    return c.makeImage()!
}
func save(_ image: CGImage, _ path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, image, nil); CGImageDestinationFinalize(d)
}

let args = CommandLine.arguments
try? FileManager.default.createDirectory(atPath: args[1], withIntermediateDirectories: true)
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for s in scales {
        save(render(points*s), "\(args[1])/icon_\(points)x\(points)\(s == 2 ? "@2x" : "").png")
    }
}

// Anteprima: l'icona grande e, a fianco, le misure piccole su fondo chiaro e scuro.
let sheet = CGContext(data: nil, width: 1500, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.setFillColor(rgb(236, 236, 238)); sheet.fill(CGRect(x: 0, y: 0, width: 1500, height: 1000))
sheet.setFillColor(rgb(40, 40, 44)); sheet.fill(CGRect(x: 1000, y: 0, width: 500, height: 1000))
sheet.draw(render(1024), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
for x in [1040, 1270] {
    var y = 720
    for s in [256, 128, 64, 32, 16] {
        sheet.interpolationQuality = .none
        sheet.draw(render(s), in: CGRect(x: x, y: y, width: s, height: s))
        y -= s == 256 ? 150 : s == 128 ? 90 : s == 64 ? 50 : 30
    }
}
save(sheet.makeImage()!, args[2])
