#!/usr/bin/env swift
// 生成 Codex 模型切换器 应用图标（AppIcon.iconset）
// 用法: swiftc -O -framework AppKit -o /tmp/icon_gen Support/generate_app_icon.swift
//       /tmp/icon_gen <输出目录>
//
// 设计：深色 Codex 风格圆角方形底 + 三色(绿→蓝→紫)圆形切换箭头 + 白色六边形节点。
// 三种颜色代表三个可切换模型状态（ChatGPT / DeepSeek High / DeepSeek Max）。

import AppKit
import Foundation

// MARK: - 颜色工具

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha)
}

func lerpColor(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let t = max(0, min(1, t))
    return NSColor(calibratedRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                   green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                   blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                   alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t)
}

/// 三停靠点分段线性采样
func gradient3(_ stops: [NSColor], _ positions: [CGFloat], _ t: CGFloat) -> NSColor {
    let t = max(0, min(1, t))
    for i in 0..<(stops.count - 1) {
        if t <= positions[i + 1] {
            let span = positions[i + 1] - positions[i]
            let local = span > 0 ? (t - positions[i]) / span : 0
            return lerpColor(stops[i], stops[i + 1], local)
        }
    }
    return stops.last!
}

// MARK: - 几何

/// macOS 连续曲率圆角方形（超椭圆近似，n=5）
func squirclePath(cx: CGFloat, cy: CGFloat, half: CGFloat, inset: CGFloat = 0) -> CGMutablePath {
    let a = max(half - inset, 0)
    let n: Double = 5.0
    let steps = 1024
    let p = CGMutablePath()
    for i in 0..<steps {
        let t = Double(i) / Double(steps) * 2.0 * Double.pi
        let c = cos(t), s = sin(t)
        let x = cx + CGFloat(copysign(pow(abs(c), 2.0 / n), c)) * a
        let y = cy + CGFloat(copysign(pow(abs(s), 2.0 / n), s)) * a
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

/// 屏幕坐标（y 向下）：角度按数学惯例，随角度增大在屏幕上逆时针旋转
func pointOn(_ center: CGPoint, _ angleDeg: CGFloat, _ radius: CGFloat) -> CGPoint {
    let t = angleDeg * .pi / 180
    return CGPoint(x: center.x + radius * cos(t), y: center.y - radius * sin(t))
}

/// 圆弧环带：fromAngle → toAngle（角度递减，即屏幕上顺时针扫过）
func arcBandPath(center: CGPoint, rOuter: CGFloat, rInner: CGFloat,
                 fromAngle: CGFloat, toAngle: CGFloat) -> CGMutablePath {
    let p = CGMutablePath()
    let steps = 300
    var first = true
    for i in 0...steps {
        let a = fromAngle + (toAngle - fromAngle) * CGFloat(i) / CGFloat(steps)
        let pt = pointOn(center, a, rOuter)
        if first { p.move(to: pt); first = false } else { p.addLine(to: pt) }
    }
    for i in stride(from: steps, through: 0, by: -1) {
        let a = fromAngle + (toAngle - fromAngle) * CGFloat(i) / CGFloat(steps)
        p.addLine(to: pointOn(center, a, rInner))
    }
    p.closeSubpath()
    return p
}

/// 圆角多边形（尖角朝上的六边形）
func roundedPolygon(center: CGPoint, radius: CGFloat, corners: Int,
                    rotationDeg: CGFloat, cornerRadius: CGFloat) -> CGMutablePath {
    let p = CGMutablePath()
    var pts: [CGPoint] = []
    for i in 0..<corners {
        let a = (rotationDeg + CGFloat(i) * 360.0 / CGFloat(corners)) * .pi / 180
        pts.append(CGPoint(x: center.x + radius * cos(a), y: center.y - radius * sin(a)))
    }
    func edgeVec(_ i: Int) -> CGPoint {
        let a = pts[(i + 1) % corners], b = pts[i]
        let d = max(hypot(a.x - b.x, a.y - b.y), 0.0001)
        return CGPoint(x: (a.x - b.x) / d, y: (a.y - b.y) / d)
    }
    for i in 0..<corners {
        let prev = edgeVec((i - 1 + corners) % corners)
        let next = edgeVec(i)
        let start = CGPoint(x: pts[i].x + prev.x * cornerRadius, y: pts[i].y + prev.y * cornerRadius)
        let end = CGPoint(x: pts[i].x + next.x * cornerRadius, y: pts[i].y + next.y * cornerRadius)
        if i == 0 { p.move(to: start) } else { p.addLine(to: start) }
        p.addArc(tangent1End: pts[i], tangent2End: end, radius: cornerRadius)
    }
    p.closeSubpath()
    return p
}

// MARK: - 渐变填充

func fillLinear(_ cg: CGContext, in path: CGPath, stops: [NSColor], positions: [CGFloat],
                start: CGPoint, end: CGPoint) {
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: cs, colors: stops.map { $0.cgColor } as CFArray,
                          locations: positions)!
    cg.drawLinearGradient(grad, start: start, end: end,
                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
}

func fillRadial(_ cg: CGContext, in path: CGPath, center: CGPoint, r0: CGFloat, r1: CGFloat,
                stops: [NSColor]) {
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: cs, colors: stops.map { $0.cgColor } as CFArray,
                          locations: [0, 1])!
    cg.drawRadialGradient(grad, startCenter: center, startRadius: r0,
                          endCenter: center, endRadius: r1,
                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
}

// MARK: - 图标绘制

let ringStops = [rgb(0x8FE8B0), rgb(0x8FB4FF), rgb(0xB7A0FF)]
let ringPositions: [CGFloat] = [0, 0.5, 1]

func drawIcon(_ cg: CGContext, _ size: CGFloat) {
    let s = size / 1024.0
    func S(_ v: CGFloat) -> CGFloat { v * s }
    let cx = size / 2, cy = size / 2

    let squircle = squirclePath(cx: cx, cy: cy, half: S(412), inset: 0)

    // 深色基底渐变
    fillLinear(cg, in: squircle,
               stops: [rgb(0x3A3F78), rgb(0x23264E), rgb(0x13142A)],
               positions: [0, 0.55, 1],
               start: CGPoint(x: S(150), y: S(96)),
               end: CGPoint(x: S(874), y: S(928)))

    // 顶部高光
    fillRadial(cg, in: squircle, center: CGPoint(x: cx, y: S(300)), r0: 0, r1: S(680),
               stops: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)])

    // 底部暗角
    fillRadial(cg, in: squircle, center: CGPoint(x: cx, y: S(930)), r0: 0, r1: S(620),
               stops: [rgb(0x000000, 0.16), rgb(0x000000, 0)])

    // 中心环境紫光
    fillRadial(cg, in: squircle, center: CGPoint(x: cx, y: cy), r0: S(60), r1: S(400),
               stops: [rgb(0x7D8CFF, 0.22), rgb(0x7D8CFF, 0)])

    // ---- 圆形切换箭头 ----
    let bold = size < 64 ? 1.22 : 1.0
    let bandW = S(46) * CGFloat(bold)
    let rOuter = S(252)
    let rInner = rOuter - bandW
    let rMid = (rOuter + rInner) / 2
    let center = CGPoint(x: cx, y: cy)
    let band = arcBandPath(center: center, rOuter: rOuter, rInner: rInner,
                           fromAngle: 408, toAngle: 128)

    // 两端圆帽
    let cap1 = pointOn(center, 48, rMid)
    let cap2 = pointOn(center, 128, rMid)
    let capR = bandW / 2

    // 箭头（位于 128° 端，顺时针切线方向）
    let tAng: CGFloat = 128
    let tRad = tAng * .pi / 180
    let tangent = CGPoint(x: sin(tRad), y: cos(tRad))
    let normal = CGPoint(x: cos(tRad), y: -sin(tRad))
    let headBase = pointOn(center, tAng, rOuter)
    let tip = CGPoint(x: headBase.x + tangent.x * S(60),
                      y: headBase.y + tangent.y * S(60))
    let b1 = CGPoint(x: headBase.x - tangent.x * S(6) + normal.x * S(28),
                     y: headBase.y - tangent.y * S(6) + normal.y * S(28))
    let b2 = CGPoint(x: headBase.x - tangent.x * S(6) - normal.x * S(28),
                     y: headBase.y - tangent.y * S(6) - normal.y * S(28))
    let arrow = CGMutablePath()
    arrow.move(to: tip)
    arrow.addLine(to: b1)
    arrow.addLine(to: b2)
    arrow.closeSubpath()

    // 发光层（纯色 + 阴影）
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: S(26), color: rgb(0xFFFFFF, 0.30).cgColor)
    cg.setFillColor(rgb(0xFFFFFF).cgColor)
    cg.addPath(band)
    cg.fillPath()
    cg.fillEllipse(in: CGRect(x: cap1.x - capR, y: cap1.y - capR, width: capR * 2, height: capR * 2))
    cg.fillEllipse(in: CGRect(x: cap2.x - capR, y: cap2.y - capR, width: capR * 2, height: capR * 2))
    cg.addPath(arrow)
    cg.fillPath()
    cg.restoreGState()

    // 渐变层：三色环带
    fillLinear(cg, in: band, stops: ringStops, positions: ringPositions,
               start: CGPoint(x: cx, y: cy - rOuter),
               end: CGPoint(x: cx, y: cy + rOuter))

    let yTop = cy - rOuter, yBot = cy + rOuter
    func ringColor(at y: CGFloat) -> NSColor {
        gradient3(ringStops, ringPositions, (y - yTop) / (yBot - yTop))
    }
    cg.saveGState()
    cg.setFillColor(ringColor(at: cap1.y).cgColor)
    cg.fillEllipse(in: CGRect(x: cap1.x - capR, y: cap1.y - capR, width: capR * 2, height: capR * 2))
    cg.setFillColor(ringColor(at: cap2.y).cgColor)
    cg.fillEllipse(in: CGRect(x: cap2.x - capR, y: cap2.y - capR, width: capR * 2, height: capR * 2))
    cg.setFillColor(ringColor(at: tip.y).cgColor)
    cg.addPath(arrow)
    cg.fillPath()
    cg.restoreGState()

    // ---- 中央白色六边形节点 ----
    let hex = roundedPolygon(center: center, radius: S(132), corners: 6,
                             rotationDeg: 90, cornerRadius: S(30))
    fillRadial(cg, in: squircle, center: center, r0: S(60), r1: S(235),
               stops: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)])
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: S(22), color: rgb(0xFFFFFF, 0.55).cgColor)
    cg.setFillColor(rgb(0xFFFFFF).cgColor)
    cg.addPath(hex)
    cg.fillPath()
    cg.restoreGState()
    fillLinear(cg, in: hex,
               stops: [rgb(0xFFFFFF), rgb(0xE2E6FF)],
               positions: [0, 1],
               start: CGPoint(x: cx, y: cy - S(132)),
               end: CGPoint(x: cx, y: cy + S(132)))

    // ---- 内侧描边 ----
    let border = squirclePath(cx: cx, cy: cy, half: S(412), inset: S(2.0))
    cg.saveGState()
    cg.addPath(border)
    cg.setStrokeColor(rgb(0xFFFFFF, 0.16).cgColor)
    cg.setLineWidth(S(2.5))
    cg.strokePath()
    cg.restoreGState()
}

// MARK: - 输出

func renderIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ns = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ns
    let cg = ns.cgContext
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high
    cg.translateBy(x: 0, y: CGFloat(size))
    cg.scaleBy(x: 1, y: -1)
    drawIcon(cg, CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    let rep = renderIcon(size: px)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: outDir.appendingPathComponent(name))
}
print("已生成 \(specs.count) 个图标 PNG 到 \(outDir.path)")
