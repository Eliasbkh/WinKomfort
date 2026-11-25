// Skizzenblock: zeichnen, als Bild kopieren
import AppKit
import SwiftUI

enum SketchTool: CaseIterable {
    case pen, marker, line, arrow, rect, oval, eraser
    var symbol: String { switch self { case .pen: "pencil.tip"; case .marker: "highlighter"; case .line: "line.diagonal"; case .arrow: "arrow.up.right"; case .rect: "rectangle"; case .oval: "circle"; case .eraser: "eraser" } }
    var title: String { switch self { case .pen: L("Stift", "Pen"); case .marker: L("Marker", "Highlighter"); case .line: L("Linie", "Line"); case .arrow: L("Pfeil", "Arrow"); case .rect: L("Rechteck", "Rectangle"); case .oval: L("Ellipse", "Ellipse"); case .eraser: L("Radierer", "Eraser") } }
}
struct SketchStroke { var tool: SketchTool, color: Color, width: CGFloat, pts: [CGPoint] }

final class SketchModel: ObservableObject {
    @Published var strokes: [SketchStroke] = []
    @Published var undone: [SketchStroke] = []
    @Published var tool = SketchTool.pen
    @Published var color = Color.black
    @Published var width: CGFloat = 3
    @Published var grid = false
    var drawing = false
    var size = CGSize(width: 820, height: 520)
    func drag(_ p: CGPoint) {
        if tool == .eraser { strokes.removeAll { s in s.pts.contains { hypot($0.x - p.x, $0.y - p.y) < 14 } || s.pts.count == 2 && Self.near(p, s.pts[0], s.pts[1]) }; return }
        if !drawing { drawing = true; undone = []; strokes.append(SketchStroke(tool: tool, color: color, width: tool == .marker ? width * 5 : width, pts: [p])); return }
        guard !strokes.isEmpty else { return }
        let i = strokes.count - 1
        if tool == .pen || tool == .marker { strokes[i].pts.append(p) } else { strokes[i].pts = [strokes[i].pts[0], p] }
    }
    private static func near(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Bool {
        let d = hypot(b.x - a.x, b.y - a.y)
        guard d > 1 else { return false }
        let t = min(max(((p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y)) / (d * d), 0), 1)
        return hypot(p.x - a.x - t * (b.x - a.x), p.y - a.y - t * (b.y - a.y)) < 12
    }
    func undo() { if let s = strokes.popLast() { undone.append(s) } }
    func redo() { if let s = undone.popLast() { strokes.append(s) } }
}

struct SketchCanvas: View {
    let strokes: [SketchStroke], grid: Bool
    var body: some View {
        Canvas { c, size in
            if grid {
                var p = Path()
                for x in stride(from: 0, through: size.width, by: 24) { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }
                for y in stride(from: 0, through: size.height, by: 24) { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
                c.stroke(p, with: .color(.blue.opacity(0.15)), lineWidth: 1)
            }
            for s in strokes {
                guard let a = s.pts.first, let b = s.pts.last else { continue }
                var p = Path()
                switch s.tool {
                case .pen, .marker, .eraser:
                    p.move(to: a)
                    if s.pts.count == 1 { p.addLine(to: CGPoint(x: a.x + 0.1, y: a.y)) }
                    for i in 1..<max(s.pts.count, 1) { let m = CGPoint(x: (s.pts[i - 1].x + s.pts[i].x) / 2, y: (s.pts[i - 1].y + s.pts[i].y) / 2); p.addQuadCurve(to: m, control: s.pts[i - 1]) }
                    p.addLine(to: b)
                case .line, .arrow:
                    p.move(to: a)
                    p.addLine(to: b)
                    if s.tool == .arrow {
                        let t = atan2(b.y - a.y, b.x - a.x), l = 10 + s.width * 2
                        for d in [2.6, -2.6] { p.move(to: b); p.addLine(to: CGPoint(x: b.x + cos(t + d) * l, y: b.y + sin(t + d) * l)) }
                    }
                case .rect: p.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
                case .oval: p.addEllipse(in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
                }
                c.stroke(p, with: .color(s.color.opacity(s.tool == .marker ? 0.35 : 1)), style: StrokeStyle(lineWidth: s.width, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct SketchView: View {
    @StateObject private var m = SketchModel()
    private let colors: [Color] = [.black, Color(red: 0.04, green: 0.4, blue: 1), Color(red: 0.86, green: 0.16, blue: 0.14), Color(red: 0.1, green: 0.6, blue: 0.3), Color(red: 0.95, green: 0.62, blue: 0.1)]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(SketchTool.allCases, id: \.self) { t in
                    Button { m.tool = t } label: { Image(systemName: t.symbol).frame(width: 26, height: 24) }
                        .buttonStyle(.bordered).tint(m.tool == t ? .accentColor : nil).help(t.title).accessibilityLabel(t.title).accessibilityAddTraits(m.tool == t ? .isSelected : [])
                }
                Divider().frame(height: 20)
                ForEach(Array(colors.enumerated()), id: \.offset) { i, c in
                    Button { m.color = c } label: { Circle().fill(c).frame(width: 20, height: 20).overlay(Circle().strokeBorder(.primary.opacity(m.color == c ? 0.9 : 0.2), lineWidth: m.color == c ? 3 : 1)) }
                        .buttonStyle(.plain).accessibilityLabel(L("Farbe \(i + 1)", "Color \(i + 1)"))
                }
                Slider(value: $m.width, in: 1...12) { Text(L("Strichstärke", "Stroke width")) }.labelsHidden().frame(width: 90)
                Toggle(isOn: $m.grid) { Image(systemName: "grid") }.toggleStyle(.button).help(L("Kästchen", "Grid")).accessibilityLabel(L("Kästchen", "Grid"))
                Spacer()
                Button { m.undo() } label: { Image(systemName: "arrow.uturn.backward") }.keyboardShortcut("z").disabled(m.strokes.isEmpty).accessibilityLabel(L("Rückgängig", "Undo"))
                Button { m.redo() } label: { Image(systemName: "arrow.uturn.forward") }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(m.undone.isEmpty).accessibilityLabel(L("Wiederholen", "Redo"))
                Button(L("Bild kopieren", "Copy image")) { Export.copy(SketchCanvas(strokes: m.strokes, grid: m.grid), m.size, L("Skizze", "Sketch")) }.keyboardShortcut("c").buttonStyle(.borderedProminent).disabled(m.strokes.isEmpty)
            }
            .padding(10)
            GeometryReader { g in
                SketchCanvas(strokes: m.strokes, grid: m.grid).background(.white).contentShape(Rectangle()).environment(\.colorScheme, .light)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { m.drag($0.location) }.onEnded { _ in m.drawing = false })
                    .onAppear { m.size = g.size }.onChange(of: g.size) { _, s in m.size = s }
                    .accessibilityLabel(L("Zeichenfläche", "Drawing area"))
            }
        }
        .frame(minWidth: 960, minHeight: 560)
    }
}
