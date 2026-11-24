// Draws the Usage Wizard artwork (original pixel art, created with Claude for this project).
//   swift icon/make_wizard.swift <folder>          AppIcon.icns + menu bar icons (build.sh runs this)
//   swift icon/make_wizard.swift --banner <file>   README banner as SVG (docs/banner.svg)
// Menu bar icons are template images (macOS tints them white or black), 36×36 px = 18 pt @2x:
//   WizardMenu.png  the app-icon wizard in gray steps (alpha from brightness)
//   HatMenu.png     a painted wizard hat, turned into 36×36 pixels
//   WandMenu.png    the wand with its star, drawn smoothly at 36×36 px (same shapes as its picture)
import AppKit

// MARK: - Wizard, 32×32. Letters = colors (see the palette), "." = transparent.
let appArt = [
    "................................",
    "................HHHH............",
    "...............HHHHHH...........",
    "..............LHHHHHHd..........",
    "..............LHHHH..d..........",
    ".............LHHHHd.........S...",
    "............LHHYHHd........SSS..",
    "............LHYYYHHd......SSZSS.",
    "...........LHHHYHHHd.......SSS..",
    "...........LHHHHHHHdd.......S...",
    "..........LHHHHHHHHdd......BB...",
    ".........YYYYYYYYYYYYYY....BB...",
    ".........yyyyyyyyyyyyyy....BB...",
    "....hhhhhhhhhhhhhhhhhhhhhhhBB...",
    "....kkkkkkkkkkkkkkkkkkkkkkkB....",
    ".........WWFFFFFFFFFFWg...BB....",
    ".........WWFWWWFFWWWFWg...BB....",
    ".........WWFFEFFFFEFFWg...BB....",
    ".........WWFFEFnnFEFFWg...BB....",
    ".........WWWFWWnnWWFWWg...BB....",
    "........gWWWWWWWWWWWWWWg..B.....",
    ".......lgWWWWWgmmgWWWWWgR.BB....",
    "......llWWWgWWWWWWWWgWWgyFFF....",
    ".....llRWWWgWWWWWWWWgWWgyFFF....",
    ".....lRRRWWWgWWWWWWgWWgrRFF.....",
    ".....RYRrWWWgWWWWWWgWWgrRRR.....",
    "....lRRRrRWWWgWWWWgWWgrRRrRr....",
    "....lRRYRrRWWWgWWgWWgrRRRrRr....",
    "....RRYYYrRRWWgWWgWgrRYRrRRr....",
    "...RYRrYRRrRRWWgWWgrRRRRrRYRr...",
    "...RRRrRRYRrRRWgWgrRRRRrRRRRr...",
    "...RRrRRRRRRrRRWgrRRRYRrRRRRr...",
]

let palette: [Character: UInt32] = [
    "H": 0x5B3BA8, "L": 0x7A58C6, "d": 0x452B85, "h": 0x3A2470, "k": 0x2B1A55,  // hat: body, lit, dark, brim, under brim
    "Y": 0xFFD23F, "y": 0xE0AE1F, "S": 0xFFD23F, "Z": 0xFFF8D8,  // gold (band, cuff, stars), sparkle
    "F": 0xF2C4A0, "n": 0xDFA57E, "E": 0x2A2A2A,                 // face, nose, eyes
    "W": 0xF4F4F4, "g": 0xC9CDD8, "m": 0x8E93A3,                 // beard and hair, strands, mouth
    "R": 0x6B45B5, "r": 0x4E3090, "l": 0x8A66D0,                 // purple robe, folds, lit side
    "B": 0x8A5A34,                                               // staff
]
precondition(appArt.count == 32 && appArt.allSatisfy { $0.count == 32 })

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
func hex(_ h: UInt32) -> String { String(format: "#%06X", h) }
/// RGBA bitmap with y pointing down (row 0 at the top)
func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
    draw(c); return c
}
func pngData(_ c: CGContext) -> Data { NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])! }

// MARK: - App icon: the wizard on a night-sky rounded square

func appIcon(_ px: Int) -> Data {
    pngData(bitmap(px, px) { c in
        let s = CGFloat(px) / 1024
        // macOS icon grid: 824×824 body centered in 1024, corner radius ~185
        let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
        c.addPath(shape); c.setFillColor(rgb(0x24294F)); c.fillPath()
        c.saveGState(); c.addPath(shape); c.clip()
        c.setFillColor(rgb(0x2F3666)); c.fill(CGRect(x: body.minX, y: body.maxY - body.height * 0.4, width: body.width, height: body.height * 0.4))
        c.setFillColor(CGColor(gray: 1, alpha: 0.45))
        for (x, y) in [(0.12, 0.15), (0.86, 0.5), (0.1, 0.45), (0.9, 0.8), (0.14, 0.8)] {
            c.fill(CGRect(x: body.minX + body.width * x, y: body.minY + body.height * y, width: 14 * s, height: 14 * s))
        }
        // 32 cells of 22 px (at 1024), standing on the bottom edge
        c.setShouldAntialias(false)
        let cs = 22 * s, ox = body.midX - 16 * cs, oy = body.maxY - 32 * cs + 8 * s
        for (y, row) in appArt.enumerated() { for (x, ch) in row.enumerated() where ch != "." {
            c.setFillColor(rgb(palette[ch]!))
            // a hair of overlap so neighbouring cells don't leave seams at small sizes
            c.fill(CGRect(x: ox + CGFloat(x) * cs, y: oy + CGFloat(y) * cs, width: cs, height: cs).insetBy(dx: -0.25, dy: -0.25))
        } }
        c.restoreGState()
    })
}

// MARK: - Menu bar icons

let N = 36
typealias Template = [[CGFloat]]   // alpha per pixel, row 0 at the top

/// The app-icon wizard as gray steps: bright parts (beard, stars) strong, dark parts faint, eyes cut out
let wizardTemplate: Template = {
    let alpha: [Character: CGFloat] = ["H": 0.6, "L": 0.75, "d": 0.45, "h": 0.5, "k": 0.3, "Y": 1, "y": 0.85, "S": 1, "Z": 1,
                                       "F": 0.85, "n": 0.7, "E": 0, "W": 1, "g": 0.7, "m": 0.4, "R": 0.5, "r": 0.35, "l": 0.65, "B": 0.55]
    return (0..<N).map { y in (0..<N).map { x in
        let sy = y - 2, sx = x - 2
        guard sy >= 0, sy < 32, sx >= 0, sx < 32 else { return 0 }
        return alpha[Array(appArt[sy])[sx]] ?? 0
    } }
}()

// Paintings (360×360, 10 px per menu pixel), turned into pixels by `pixelate`
let S = 360
func canvas(_ draw: (CGContext) -> Void) -> CGContext { bitmap(S, S, draw) }
func linear(_ c: CGContext, _ path: CGPath, _ cols: [UInt32], _ from: CGPoint, _ to: CGPoint) {
    c.saveGState(); c.addPath(path); c.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cols.map { rgb($0) } as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]); c.restoreGState()
}
func star4(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ col: UInt32) {
    let p = CGMutablePath(), w = r * 0.28
    p.move(to: CGPoint(x: x, y: y - r))
    p.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x + w, y: y - w))
    p.addQuadCurve(to: CGPoint(x: x, y: y + r), control: CGPoint(x: x + w, y: y + w))
    p.addQuadCurve(to: CGPoint(x: x - r, y: y), control: CGPoint(x: x - w, y: y + w))
    p.addQuadCurve(to: CGPoint(x: x, y: y - r), control: CGPoint(x: x - w, y: y - w))
    c.setFillColor(rgb(col)); c.addPath(p); c.fillPath()
}

// MARK: Hat: tall cone with a soft, crumpled tip that flops to the right, band with buckle, wide brim seen from slightly above
let hat = canvas { c in
    // brim back half (behind the cone)
    let brim = CGRect(x: 10, y: 238, width: 330, height: 74)
    let brimPath = CGPath(ellipseIn: brim, transform: nil)
    linear(c, brimPath, [0x7A58C6, 0x3A2470], CGPoint(x: 0, y: 240), CGPoint(x: 0, y: 312))
    // inner rim shadow where the head goes
    c.setFillColor(rgb(0x1E1240)); c.fillEllipse(in: CGRect(x: 92, y: 248, width: 170, height: 34))
    // cone
    let cone = CGMutablePath()
    cone.move(to: CGPoint(x: 92, y: 268))
    cone.addCurve(to: CGPoint(x: 150, y: 70), control1: CGPoint(x: 112, y: 200), control2: CGPoint(x: 128, y: 120))
    cone.addCurve(to: CGPoint(x: 205, y: 22), control1: CGPoint(x: 165, y: 40), control2: CGPoint(x: 180, y: 22))
    cone.addCurve(to: CGPoint(x: 300, y: 70), control1: CGPoint(x: 245, y: 22), control2: CGPoint(x: 285, y: 40))
    cone.addCurve(to: CGPoint(x: 292, y: 92), control1: CGPoint(x: 310, y: 80), control2: CGPoint(x: 302, y: 92))
    cone.addCurve(to: CGPoint(x: 222, y: 80), control1: CGPoint(x: 268, y: 70), control2: CGPoint(x: 240, y: 66))
    cone.addCurve(to: CGPoint(x: 262, y: 268), control1: CGPoint(x: 222, y: 140), control2: CGPoint(x: 244, y: 210))
    cone.addQuadCurve(to: CGPoint(x: 92, y: 268), control: CGPoint(x: 177, y: 290))
    linear(c, cone, [0x9A7AE0, 0x6B45B5, 0x4E3090, 0x2B1A55], CGPoint(x: 95, y: 0), CGPoint(x: 265, y: 0))
    // crease lines on the cone (soft fabric)
    c.setStrokeColor(rgb(0x2B1A55, 0.8)); c.setLineWidth(7); c.setLineCap(.round)
    c.move(to: CGPoint(x: 158, y: 128)); c.addCurve(to: CGPoint(x: 200, y: 150), control1: CGPoint(x: 172, y: 142), control2: CGPoint(x: 186, y: 146)); c.strokePath()
    c.move(to: CGPoint(x: 210, y: 46)); c.addQuadCurve(to: CGPoint(x: 232, y: 70), control: CGPoint(x: 226, y: 52)); c.strokePath()
    // band
    let band = CGMutablePath()
    band.move(to: CGPoint(x: 104, y: 222)); band.addQuadCurve(to: CGPoint(x: 252, y: 222), control: CGPoint(x: 178, y: 240))
    band.addLine(to: CGPoint(x: 260, y: 262)); band.addQuadCurve(to: CGPoint(x: 94, y: 262), control: CGPoint(x: 177, y: 284)); band.closeSubpath()
    linear(c, band, [0xFFE27A, 0xFFD23F], CGPoint(x: 100, y: 0), CGPoint(x: 262, y: 0))
    // buckle
    c.setStrokeColor(rgb(0x2B1A55)); c.setLineWidth(9); c.stroke(CGRect(x: 158, y: 232, width: 40, height: 36))
    // brim front half (in front of the cone)
    c.saveGState(); c.addPath(brimPath); c.clip()
    let front = CGMutablePath(); front.addRect(CGRect(x: 0, y: 272, width: S, height: 60))
    front.addEllipse(in: CGRect(x: 92, y: 248, width: 170, height: 34)) // keep the rim inside visible
    c.addPath(front); c.clip(using: .evenOdd)
    linear(c, CGPath(ellipseIn: brim, transform: nil), [0x8A66D0, 0x452B85], CGPoint(x: 0, y: 270), CGPoint(x: 0, y: 312))
    c.restoreGState()
    // brim edge highlight
    c.setStrokeColor(rgb(0xB79CF0, 0.9)); c.setLineWidth(6)
    c.saveGState(); c.translateBy(x: brim.midX, y: brim.midY); c.scaleBy(x: brim.width / 2 - 3, y: brim.height / 2 - 3)
    c.addArc(center: .zero, radius: 1, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false); c.restoreGState(); c.strokePath()
    // star on the cone + sparkles
    star4(c, 178, 165, 34, 0xFFF3B0)
}

// MARK: Wand: the classic magic wand: an even, thick stick (diagonal) with a clean five-point star on it,
// symmetric to the stick's axis (one point continues the stick, the stick ends in the opposite notch).
// The same shapes give the colored picture and the menu icon; the menu icon is drawn smoothly at
// 36 px (not snapped to 4 steps), because a turned star cannot be drawn evenly in coarse pixels.
func drawWand(_ c: CGContext, stick paintStick: (CGPath) -> Void, grip paintGrip: (CGRect) -> Void, star paintStar: (CGPath, CGPoint, CGFloat) -> Void) {
    let end = CGPoint(x: 44, y: 316), dir = -CGFloat.pi / 4            // grip end, direction towards the star
    let cx: CGFloat = 250, cy: CGFloat = 110, ro: CGFloat = 104, ri: CGFloat = 48
    // stick: same thickness along its whole length, rounded ends, running on under the star
    let len = hypot(cx - end.x, cy - end.y)
    c.saveGState(); c.translateBy(x: end.x, y: end.y); c.rotate(by: dir)
    let stick = CGPath(roundedRect: CGRect(x: 0, y: -18, width: len, height: 36), cornerWidth: 14, cornerHeight: 14, transform: nil)
    paintStick(stick)
    c.saveGState(); c.addPath(stick); c.clip(); paintGrip(CGRect(x: -2, y: -20, width: 74, height: 40)); c.restoreGState()
    c.restoreGState()
    let star = CGMutablePath()
    for i in 0..<10 {
        let r = i % 2 == 0 ? ro : ri, a = dir + CGFloat(i) * .pi / 5
        let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
        i == 0 ? star.move(to: pt) : star.addLine(to: pt)
    }
    star.closeSubpath()
    paintStar(star, CGPoint(x: cx, y: cy), ro)
}
let wandPicture = canvas { c in
    drawWand(c, stick: { linear(c, $0, [0xB07A4A, 0x7A4A26, 0x4A2C14], CGPoint(x: 0, y: -18), CGPoint(x: 0, y: 18)) },
             grip: { c.setFillColor(rgb(0x3A2210)); c.fill($0) },
             star: { p, m, r in linear(c, p, [0xFFF3B0, 0xFFD23F], CGPoint(x: m.x + r * 0.7, y: m.y - r * 0.7), CGPoint(x: m.x - r * 0.7, y: m.y + r * 0.7)) })
    star4(c, 80, 80, 26, 0xFFE27A); star4(c, 320, 290, 16, 0xFFE27A); star4(c, 170, 330, 12, 0xFFE27A)
}
// menu icon: smooth shapes at 36 px; stick 60 %, grip 40 %, star solid, plus the crisp pixel sparkles
func wandTemplate(sparkles: [(Int, Int, Int)]) -> Template {
    let c = bitmap(N, N) { c in
        c.scaleBy(x: CGFloat(N) / CGFloat(S), y: CGFloat(N) / CGFloat(S))
        drawWand(c, stick: { c.setFillColor(CGColor(gray: 0, alpha: 0.6)); c.addPath($0); c.fillPath() },
                 grip: { c.setBlendMode(.copy); c.setFillColor(CGColor(gray: 0, alpha: 0.4)); c.fill($0); c.setBlendMode(.normal) },
                 star: { p, _, _ in c.setFillColor(CGColor(gray: 0, alpha: 1)); c.addPath(p); c.fillPath() })
    }
    let p = c.data!.assumingMemoryBound(to: UInt8.self)
    var out = (0..<N).map { y in (0..<N).map { x in CGFloat(p[(y * N + x) * 4 + 3]) / 255 } }
    for (x, y, r) in sparkles {
        var pts = [(x, y)]
        for d in 1...r { pts += [(x - d, y), (x + d, y), (x, y - d), (x, y + d)] }
        for (px, py) in pts where px >= 0 && px < N && py >= 0 && py < N { out[py][px] = 1 }
    }
    return out
}

func pixelate(_ c: CGContext, sparkles: [(Int, Int, Int)]) -> Template {
    let p = c.data!.assumingMemoryBound(to: UInt8.self), b = S / N
    var lums = [[Double?]](repeating: [Double?](repeating: nil, count: N), count: N)
    for gy in 0..<N { for gx in 0..<N {
        var r = 0.0, g = 0.0, bl = 0.0, a = 0.0
        for y in gy * b..<(gy + 1) * b { for x in gx * b..<(gx + 1) * b {
            let i = (y * S + x) * 4
            r += Double(p[i]); g += Double(p[i + 1]); bl += Double(p[i + 2]); a += Double(p[i + 3])
        } }
        if a / Double(b * b) / 255 > 0.4 { lums[gy][gx] = (0.299 * r + 0.587 * g + 0.114 * bl) / a }
    } }
    // stretch brightness to the full range, then snap to 4 steps (keeps a pixel-art look)
    let all = lums.flatMap { $0 }.compactMap { $0 }, lo = all.min() ?? 0, hi = all.max() ?? 1
    var out = lums.map { $0.map { l -> CGFloat in
        guard let l else { return 0 }
        let t = (l - lo) / max(0.01, hi - lo)
        let steps: [CGFloat] = [0.4, 0.6, 0.8, 1]
        return steps[min(3, Int(t * 4))]
    } }
    // crisp pixel sparkles: (x, y, arm length); arm 2+ gets a cut-out ring so it stays readable on the shape
    for (x, y, r) in sparkles {
        var pts = [(x, y)]
        for d in 1...r { pts += [(x - d, y), (x + d, y), (x, y - d), (x, y + d)] }
        if r >= 3 { pts += [(x - 1, y - 1), (x + 1, y - 1), (x - 1, y + 1), (x + 1, y + 1)] }
        for (px, py) in pts where px >= 0 && px < N && py >= 0 && py < N { out[py][px] = 1 }
    }
    return out
}

func templatePNG(_ t: Template) -> Data {
    pngData(bitmap(N, N) { c in
        for y in 0..<N { for x in 0..<N where t[y][x] > 0 {
            c.setFillColor(CGColor(gray: 0, alpha: t[y][x])); c.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
    })
}

// MARK: - README banner (all pixels, so it looks the same everywhere; written as SVG)

let font: [Character: [String]] = [
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
    "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
    "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "I": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"],
    "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    "N": ["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"],
    "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    ",": [".....", ".....", ".....", ".....", ".....", "..#..", ".#..."],
    " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
]

struct Box { var x, y, w, h: Double; var color: UInt32; var alpha = 1.0 }
let BW = 1280.0, BH = 320.0

func banner(_ pal: [Character: UInt32], title: UInt32, shadow: UInt32) -> [Box] {
    var boxes: [Box] = []
    func text(_ t: String, _ x: Double, _ y: Double, _ s: Double, _ color: UInt32) {
        for (i, ch) in t.enumerated() {
            for (r, row) in font[ch]!.enumerated() {
                for (c, px) in row.enumerated() where px == "#" {
                    boxes.append(Box(x: x + Double(i * 6 + c) * s, y: y + Double(r) * s, w: s, h: s, color: color))
                }
            }
        }
    }
    func sparkle(_ cx: Double, _ cy: Double, _ s: Double, _ color: UInt32) {
        boxes.append(Box(x: cx - s / 2, y: cy - 1.5 * s, w: s, h: 3 * s, color: color))
        boxes.append(Box(x: cx - 1.5 * s, y: cy - s / 2, w: 3 * s, h: s, color: color))
    }
    // Sky, horizon, stars
    boxes.append(Box(x: 0, y: 0, w: BW, h: BH, color: 0x24294F))
    boxes.append(Box(x: 0, y: 236, w: BW, h: BH - 236, color: 0x2F3666))
    for (x, y) in [(40, 40), (300, 26), (350, 150), (560, 30), (1180, 60), (1230, 200), (1050, 270), (30, 250), (610, 280), (920, 24)] {
        boxes.append(Box(x: Double(x), y: Double(y), w: 6, h: 6, color: 0xFFFFFF, alpha: 0.45))
    }
    sparkle(1160, 130, 8, 0xFFD23F); sparkle(1225, 112, 4, 0xFFD23F); sparkle(250, 60, 4, 0xFFD23F)
    // Wizard, standing on the bottom edge
    let ws = 8.0, wx = 70.0, wy = BH - 32 * ws
    for (y, row) in appArt.enumerated() { for (x, ch) in row.enumerated() where ch != "." {
        boxes.append(Box(x: wx + Double(x) * ws, y: wy + Double(y) * ws, w: ws, h: ws, color: pal[ch]!))
    } }
    // Title with a hard shadow, subtitle, context meter
    let tx = 400.0
    text("USAGE WIZARD", tx + 9, 66 + 9, 9, shadow)
    text("USAGE WIZARD", tx, 66, 9, title)
    text("TOKENS, CONTEXT AND CACHE IN YOUR MENU BAR", tx, 160, 3, 0xC9CDD8)
    for i in 0..<36 {
        let c: UInt32 = i < 18 ? 0x3FBF6F : i < 23 ? 0xF0A030 : 0x3A4170
        boxes.append(Box(x: tx + Double(i) * 18, y: 212, w: 14, h: 14, color: c))
    }
    return boxes
}

func svg(_ boxes: [Box]) -> String {
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(Int(BW)) \(Int(BH))\" width=\"\(Int(BW))\" height=\"\(Int(BH))\" shape-rendering=\"crispEdges\">\n"
    s += "<title>Usage Wizard</title>\n<clipPath id=\"r\"><rect width=\"\(Int(BW))\" height=\"\(Int(BH))\" rx=\"24\"/></clipPath>\n<g clip-path=\"url(#r)\">\n"
    // Merge equal neighbours in a row into one rect to keep the file small
    var merged: [Box] = []
    for b in boxes {
        if var last = merged.last, last.y == b.y, last.h == b.h, last.color == b.color, last.alpha == b.alpha, last.x + last.w == b.x {
            last.w += b.w; merged[merged.count - 1] = last
        } else { merged.append(b) }
    }
    func num(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
    for b in merged {
        s += "<rect x=\"\(num(b.x))\" y=\"\(num(b.y))\" width=\"\(num(b.w))\" height=\"\(num(b.h))\" fill=\"\(hex(b.color))\"\(b.alpha < 1 ? " fill-opacity=\"\(b.alpha)\"" : "")/>\n"
    }
    return s + "</g>\n</svg>\n"
}

// MARK: - Main

let args = CommandLine.arguments
if args.count > 2, args[1] == "--banner" {
    let boxes = banner(palette, title: 0xF4F4F4, shadow: palette["H"]!)
    try svg(boxes).write(toFile: args[2], atomically: true, encoding: .utf8)
    print("Banner written to \(args[2])")
    exit(0)
}

let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try templatePNG(wizardTemplate).write(to: outDir.appendingPathComponent("WizardMenu.png"))
try templatePNG(pixelate(hat, sparkles: [(32, 14, 2), (4, 11, 2)])).write(to: outDir.appendingPathComponent("HatMenu.png"))
try templatePNG(wandTemplate(sparkles: [(8, 8, 2), (32, 29, 1), (17, 33, 1)])).write(to: outDir.appendingPathComponent("WandMenu.png"))

let set = FileManager.default.temporaryDirectory.appendingPathComponent("UsageWizard-\(getpid()).iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try appIcon(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try appIcon(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
if args.contains("--preview") {
    try appIcon(1024).write(to: outDir.appendingPathComponent("wizard_preview.png"))
    try pngData(wandPicture).write(to: outDir.appendingPathComponent("wand_picture.png"))
}
guard p.terminationStatus == 0 else { print("iconutil failed"); exit(1) }
print("Wizard icons written to \(outDir.path)")
