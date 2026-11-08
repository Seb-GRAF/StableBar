import SwiftUI

struct FeltPen {
    static let ink = Color(red: 0.949, green: 0.933, blue: 1)
    let boil: Double

    init(time: Double) {
        boil = Double(Int(time * 7) % 3)
    }

    func line(from start: CGPoint, to end: CGPoint, width: Double, seed: Double) -> Path {
        ribbon(evenlySpaced([start, end]), width: width, seed: seed)
    }

    func loop(around rect: CGRect, cornerRadius: Double, width: Double, seed: Double) -> Path {
        let radius = min(cornerRadius, rect.height / 2, rect.width / 2)
        let centers = [CGPoint(x: rect.maxX - radius, y: rect.minY + radius), CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                       CGPoint(x: rect.minX + radius, y: rect.maxY - radius), CGPoint(x: rect.minX + radius, y: rect.minY + radius)]
        var corners: [CGPoint] = []
        for (index, center) in centers.enumerated() {
            for step in 0...6 {
                let angle = (Double(index) - 1 + Double(step) / 6) * .pi / 2
                corners.append(CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
            }
        }
        let outline = Array(evenlySpaced(corners + [corners[0]]).dropLast())
        let first = Int(seed * 7919) % outline.count, over = max(2, outline.count * 8 / 100)
        let points = (0...(outline.count + over)).map { index in
            let point = outline[(first + index) % outline.count]
            guard index > outline.count else { return point }
            let push = Double(index - outline.count) / Double(over) * 1.6
            let dx = point.x - rect.midX, dy = point.y - rect.midY, distance = hypot(dx, dy)
            return CGPoint(x: point.x + dx / distance * push, y: point.y + dy / distance * push)
        }
        return ribbon(points, width: width, seed: seed)
    }

    private func ribbon(_ points: [CGPoint], width: Double, seed: Double) -> Path {
        var lengths = [0.0]
        for index in points.indices.dropFirst() {
            lengths.append(lengths[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
        }
        let total = lengths.last! > 0 ? lengths.last! : 1
        let shift = boil * 7.13 + seed * 3.71
        let landing = min(total * 0.4, 9), lifting = min(total * 0.5, 15)
        var left: [CGPoint] = [], right: [CGPoint] = [], ends: [(center: CGPoint, tx: Double, ty: Double, half: Double)] = []
        for index in points.indices {
            let a = points[max(index - 1, 0)], b = points[min(index + 1, points.count - 1)]
            let distance = hypot(b.x - a.x, b.y - a.y), length = distance > 0 ? distance : 1
            let tx = (b.x - a.x) / length, ty = (b.y - a.y) / length
            let s = lengths[index]
            let wobble = 0.85 * (noise(s / 70 + shift) * 0.9 + noise(s / 19 + shift * 1.7 + 5) * 0.28)
            let center = CGPoint(x: points[index].x - ty * wobble, y: points[index].y + tx * wobble)
            let pressure = (0.4 + 0.6 * easeOut(min(s / landing, 1))) * (0.22 + 0.78 * easeOut(min((total - s) / lifting, 1)))
                * (1 + 0.15 * noise(s / 43 + shift * 0.6 + 17))
            let half = width / 2 * pressure
            left.append(CGPoint(x: center.x - ty * half, y: center.y + tx * half))
            right.append(CGPoint(x: center.x + ty * half, y: center.y - tx * half))
            if index == 0 || index == points.count - 1 { ends.append((center, tx, ty, half)) }
        }
        return Path { path in
            path.move(to: left[0])
            for point in left.dropFirst() { path.addLine(to: point) }
            let end = ends[ends.count - 1]
            for step in 1..<5 {
                let angle = Double(step) / 5 * .pi
                path.addLine(to: CGPoint(x: end.center.x + end.half * (-end.ty * cos(angle) + end.tx * sin(angle)),
                                         y: end.center.y + end.half * (end.tx * cos(angle) + end.ty * sin(angle))))
            }
            for point in right.reversed() { path.addLine(to: point) }
            let start = ends[0]
            for step in 1..<5 {
                let angle = Double(step) / 5 * .pi
                path.addLine(to: CGPoint(x: start.center.x + start.half * (start.ty * cos(angle) - start.tx * sin(angle)),
                                         y: start.center.y + start.half * (-start.tx * cos(angle) - start.ty * sin(angle))))
            }
            path.closeSubpath()
        }
    }

    private func evenlySpaced(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let count = max(1, Int((hypot(b.x - a.x, b.y - a.y) / 8).rounded(.up)))
            for step in 0..<count {
                let f = Double(step) / Double(count)
                out.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        return out + [points[points.count - 1]]
    }

    private func easeOut(_ t: Double) -> Double {
        t * (2 - t)
    }

    private func noise(_ x: Double) -> Double {
        let i = x.rounded(.down), f = x - i, u = f * f * (3 - 2 * f)
        return (hash(i) + (hash(i + 1) - hash(i)) * u) * 2 - 1
    }

    private func hash(_ n: Double) -> Double {
        let s = sin(n * 127.1 + 311.7) * 43758.5453
        return s - s.rounded(.down)
    }
}

/// Shantell Sans from the app's resources, or the system font outside the app bundle, as when tests draw setup.
func shantellSans(_ file: String, size: Double) -> CTFont {
    guard let url = Bundle.main.url(forResource: file, withExtension: "woff2"),
          let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first else {
        return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}
