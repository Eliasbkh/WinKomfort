// Formeln, Graphen, Diagramme, Ablaufpläne: Vorschau in der Suche und als scharfes Bild kopieren (OneNote, Word, Chats)
import AppKit
import SwiftUI
import WebKit
import Charts

@MainActor enum Export {
    static func put(_ img: NSImage, _ name: String) {
        guard let t = img.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        pb.setData(t, forType: .tiff)
        Toast.show(L("\(name) kopiert", "\(name) copied"), symbol: "doc.on.doc")
    }
    // Immer hell auf Weiß: passt auf Papier und in OneNote
    static func image<V: View>(_ v: V, _ size: CGSize) -> NSImage? {
        let r = ImageRenderer(content: v.frame(width: size.width, height: size.height).padding(16).background(.white).environment(\.colorScheme, .light))
        r.scale = 3
        return r.nsImage
    }
    static func copy<V: View>(_ v: V, _ size: CGSize, _ name: String) { if let i = image(v, size) { put(i, name) } }
    // Als echte Tabelle einfügbar (OneNote, Word, Excel)
    static func table(_ head: [String], _ rows: [[String]]) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let html = "<meta charset=\"utf-8\"><table border=\"1\" cellspacing=\"0\" cellpadding=\"4\"><tr>" + head.map { "<th>\(esc($0))</th>" }.joined() + "</tr>" + rows.map { "<tr>" + $0.map { "<td align=\"center\">\(esc($0))</td>" }.joined() + "</tr>" }.joined() + "</table>"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html, forType: .html)
        pb.setString(([head] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n"), forType: .string)
        Toast.show(L("Tabelle kopiert", "Table copied"), symbol: "tablecells")
    }
}

// MARK: Formel (macOS setzt MathML selbst)
@MainActor final class MathRenderer: NSObject, WKNavigationDelegate {
    private static var running: [MathRenderer] = []
    private let web: WKWebView
    private let done: (NSImage?) -> Void
    static func page(_ n: MathNode, _ css: String) -> String {
        "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"><style>html,body{margin:0}math{math-style:normal}\(css)</style><body><div id=\"f\">\(MathExpr.document(n))</div>"
    }
    private static var config: WKWebViewConfiguration { let c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent(); return c }
    private init(_ done: @escaping (NSImage?) -> Void) {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 2400, height: 900), configuration: Self.config)
        self.done = done
        super.init()
        web.navigationDelegate = self
    }
    static func image(_ n: MathNode, _ done: @escaping (NSImage?) -> Void) {
        let r = MathRenderer(done)
        running.append(r)
        r.web.loadHTMLString(page(n, "body{background:#fff;color:#000}#f{display:inline-block;padding:14px 18px;font-size:30px}math{display:inline-block}"), baseURL: nil)
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        w.evaluateJavaScript("(r=>[r.width,r.height])(document.getElementById('f').getBoundingClientRect())") { r, _ in
            let s = r as? [Double] ?? []
            guard s.count == 2, s[0] > 4, s[1] > 4 else { self.end(nil); return }
            let c = WKSnapshotConfiguration()
            c.rect = CGRect(x: 0, y: 0, width: min(s[0].rounded(.up), 2400), height: min(s[1].rounded(.up), 900))
            c.snapshotWidth = NSNumber(value: min(c.rect.width * 2, 4000))
            w.takeSnapshot(with: c) { i, _ in
                if let i { i.size = c.rect.size } // groß gerendert, normal groß eingefügt
                self.end(i)
            }
        }
    }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { end(nil) }
    private func end(_ i: NSImage?) { done(i); Self.running.removeAll { $0 === self } }
}

struct MathPreview: NSViewRepresentable {
    let node: MathNode
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .nonPersistent()
        c.defaultWebpagePreferences.allowsContentJavaScript = false
        let w = PassWeb(frame: .zero, configuration: c)
        w.setValue(false, forKey: "drawsBackground")
        return w
    }
    func updateNSView(_ w: WKWebView, context: Context) {
        let html = MathRenderer.page(node, "html,body{height:100%}body{display:flex;align-items:center;justify-content:center;background:transparent;color:\(scheme == .dark ? "#fff" : "#000");overflow:hidden}#f{font-size:clamp(18px,5vw,34px);padding:6px}")
        guard (w as? PassWeb)?.shown != html else { return }
        (w as? PassWeb)?.shown = html
        w.loadHTMLString(html, baseURL: nil)
    }
    final class PassWeb: WKWebView { // nimmt der Suche nie Klicks oder den Fokus weg
        var shown = ""
        override func hitTest(_ p: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
    }
}

// MARK: Graph
struct PlotSpec: Equatable {
    var functions: [MathNode], x: ClosedRange<Double>, y: ClosedRange<Double>
    static let colors: [Color] = [Color(red: 0.04, green: 0.4, blue: 1), Color(red: 0.87, green: 0.36, blue: 0.1), Color(red: 0.1, green: 0.6, blue: 0.35), Color(red: 0.6, green: 0.3, blue: 0.75)]
    // „sin(x); x^2 von -5 bis 5“
    static func parse(_ s: String) -> PlotSpec? {
        var t = s, r: ClosedRange<Double>?
        if let m = t.range(of: #"\s+(von|from)\s+(-?[\d.,]+)\s+(bis|to)\s+(-?[\d.,]+)\s*$"#, options: .regularExpression) {
            let n = t[m].split(separator: " ").compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
            guard n.count == 2, n[0] < n[1] else { return nil }
            r = n[0]...n[1]
            t.removeSubrange(m)
        }
        var f: [MathNode] = []
        for p in t.split(separator: ";").prefix(4) {
            guard var n = MathExpr.parse(String(p)) else { return nil }
            if let (a, b) = MathExpr.sides(n), [MathNode.id("y"), .mul([.id("f"), .paren("(", .id("x"), ")")])].contains(a) { n = b } // y = …, f(x) = …
            guard MathExpr.variables(n).isSubset(of: ["x"]) else { return nil }
            f.append(n)
        }
        let x = r ?? -10...10
        // y-Bereich ohne Ausreißer (Polstellen)
        let step = (x.upperBound - x.lowerBound) / 300
        var ys: [Double] = []
        for n in f { for i in 0...300 { if let v = MathExpr.eval(n, ["x": x.lowerBound + step * Double(i) + 1e-7]), v.isFinite, abs(v) < 1e6 { ys.append(v) } } }
        ys.sort()
        guard !f.isEmpty, ys.count > 2 else { return nil }
        ys = Array(ys[(ys.count / 12)...(ys.count - 1 - ys.count / 12)])
        var lo = ys.first!, hi = ys.last!
        let wide = x.upperBound - x.lowerBound
        if r == nil, hi - lo > wide * 4 { lo = max(lo, -wide); hi = min(hi, wide) }
        if hi <= lo { lo -= 1; hi = lo + 2 }
        let pad = max((hi - lo) * 0.15, 0.2)
        return PlotSpec(functions: f, x: x, y: min(lo - pad, 0 - pad * 0.3)...max(hi + pad, pad * 0.3))
    }
    var table: ([String], [[String]]) {
        let step = niceStep((x.upperBound - x.lowerBound) / 10), start = (x.lowerBound / step).rounded(.up) * step
        let xs = (0...12).map { start + Double($0) * step }.filter { $0 <= x.upperBound + 1e-9 }
        return (["x"] + functions.indices.map { functions.count == 1 ? "f(x)" : "f\($0 + 1)(x)" }, xs.map { v in [Calc.format((v * 1e6).rounded() / 1e6)] + functions.map { MathExpr.eval($0, ["x": v]).map { Calc.format(($0 * 1000).rounded() / 1000) } ?? "–" } })
    }
}
func niceStep(_ raw: Double) -> Double {
    guard raw > 0, raw.isFinite else { return 1 }
    let p = pow(10, floor(log10(raw))), f = raw / p
    return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * p
}

struct PlotView: View {
    let spec: PlotSpec
    var body: some View {
        Canvas { c, size in
            let x = spec.x, y = spec.y, w = x.upperBound - x.lowerBound, h = y.upperBound - y.lowerBound
            func px(_ v: Double) -> CGFloat { (v - x.lowerBound) / w * size.width }
            func py(_ v: Double) -> CGFloat { size.height - (v - y.lowerBound) / h * size.height }
            func line(_ a: CGPoint, _ b: CGPoint, _ o: Double, _ lw: CGFloat) { var p = Path(); p.move(to: a); p.addLine(to: b); c.stroke(p, with: .color(.primary.opacity(o)), lineWidth: lw) }
            let sx = niceStep(w / Double(max(size.width / 70, 2))), sy = niceStep(h / Double(max(size.height / 45, 2)))
            let ax = min(max(py(0), 0), size.height), ay = min(max(px(0), 0), size.width)
            var v = (x.lowerBound / sx).rounded(.up) * sx
            while v <= x.upperBound {
                line(CGPoint(x: px(v), y: 0), CGPoint(x: px(v), y: size.height), 0.1, 1)
                if abs(v) > sx / 2 { c.draw(Text(Calc.format((v * 1e6).rounded() / 1e6)).font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: px(v), y: min(ax + 9, size.height - 7))) }
                v += sx
            }
            v = (y.lowerBound / sy).rounded(.up) * sy
            while v <= y.upperBound {
                line(CGPoint(x: 0, y: py(v)), CGPoint(x: size.width, y: py(v)), 0.1, 1)
                if abs(v) > sy / 2 { c.draw(Text(Calc.format((v * 1e6).rounded() / 1e6)).font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: max(ay - 6, 26), y: py(v)), anchor: .trailing) }
                v += sy
            }
            line(CGPoint(x: 0, y: ax), CGPoint(x: size.width, y: ax), 0.7, 1.5)
            line(CGPoint(x: ay, y: 0), CGPoint(x: ay, y: size.height), 0.7, 1.5)
            for (k, f) in spec.functions.enumerated() {
                var p = Path(), pen = false, last = 0.0
                let n = Int(size.width * 1.5)
                for i in 0...max(n, 2) {
                    let xv = x.lowerBound + w * Double(i) / Double(max(n, 2))
                    guard let yv = MathExpr.eval(f, ["x": xv]), yv.isFinite else { pen = false; continue }
                    if pen, abs(yv - last) > h * 1.5 { pen = false } // Polstelle: nicht verbinden
                    let pt = CGPoint(x: px(xv), y: min(max(py(yv), -size.height), size.height * 2))
                    if pen { p.addLine(to: pt) } else { p.move(to: pt) }
                    pen = true
                    last = yv
                }
                c.stroke(p, with: .color(PlotSpec.colors[k % 4]), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            }
        }
        .accessibilityLabel(L("Funktionsgraph", "Function graph"))
    }
}

final class PlotState: ObservableObject { @Published var spec: PlotSpec; var base: PlotSpec?; init(_ s: PlotSpec) { spec = s } }
struct PlotWindow: View {
    @StateObject private var s: PlotState
    init(_ p: PlotSpec) { _s = StateObject(wrappedValue: PlotState(p)) }
    private func zoom(_ k: Double, _ from: PlotSpec) {
        func z(_ r: ClosedRange<Double>) -> ClosedRange<Double> { let m = (r.lowerBound + r.upperBound) / 2, h = min(max((r.upperBound - r.lowerBound) / 2 * k, 1e-4), 1e6); return (m - h)...(m + h) }
        s.spec.x = z(from.x)
        s.spec.y = z(from.y)
    }
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                PlotView(spec: s.spec).contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { d in
                        let b = s.base ?? s.spec
                        s.base = b
                        let dx = -d.translation.width / g.size.width * (b.x.upperBound - b.x.lowerBound), dy = d.translation.height / g.size.height * (b.y.upperBound - b.y.lowerBound)
                        s.spec.x = (b.x.lowerBound + dx)...(b.x.upperBound + dx)
                        s.spec.y = (b.y.lowerBound + dy)...(b.y.upperBound + dy)
                    }.onEnded { _ in s.base = nil })
                    .simultaneousGesture(MagnifyGesture().onChanged { m in let b = s.base ?? s.spec; s.base = b; zoom(1 / m.magnification, b) }.onEnded { _ in s.base = nil })
            }
            .padding(12)
            HStack {
                Button { zoom(0.7, s.spec) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel(L("Vergrößern", "Zoom in"))
                Button { zoom(1 / 0.7, s.spec) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel(L("Verkleinern", "Zoom out"))
                Spacer()
                Button(L("Wertetabelle kopieren", "Copy table")) { let t = s.spec.table; Export.table(t.0, t.1) }
                Button(L("Bild kopieren", "Copy image")) { Export.copy(PlotView(spec: s.spec), CGSize(width: 720, height: 460), L("Graph", "Graph")) }.keyboardShortcut("c")
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

// MARK: Diagramm
enum ChartKind: CaseIterable { case bar, line, pie }
struct ChartView: View {
    let data: [(String, Double)]
    let kind: ChartKind
    private struct P: Identifiable { let id: Int, name: String, v: Double }
    private var points: [P] { data.enumerated().map { P(id: $0, name: $1.0, v: $1.1) } }
    var body: some View {
        switch kind {
        case .bar: Chart(points) { p in BarMark(x: .value("x", p.name), y: .value("y", p.v)).foregroundStyle(PlotSpec.colors[0]).cornerRadius(4) }
        case .line: Chart(points) { p in LineMark(x: .value("x", p.name), y: .value("y", p.v)).foregroundStyle(PlotSpec.colors[0]).lineStyle(StrokeStyle(lineWidth: 3)); PointMark(x: .value("x", p.name), y: .value("y", p.v)).foregroundStyle(PlotSpec.colors[0]) }
        case .pie: Chart(points) { p in SectorMark(angle: .value("y", max(p.v, 0)), innerRadius: .ratio(0.5), angularInset: 1.5).foregroundStyle(by: .value("x", p.name)).cornerRadius(3) }
        }
    }
}

// MARK: Ablaufplan
struct FlowView: View {
    let flow: SchoolLogic.Flow
    static func size(_ f: SchoolLogic.Flow) -> CGSize {
        let l = SchoolLogic.levels(f), widest = Dictionary(grouping: l) { $0 }.values.map(\.count).max() ?? 1
        return CGSize(width: max(Double(widest) * 190, 260) + 80, height: Double((l.max() ?? 0) + 1) * 110)
    }
    var body: some View {
        Canvas { c, size in
            let l = SchoolLogic.levels(flow), full = Self.size(flow), k = min(size.width / full.width, size.height / full.height, 1)
            c.translateBy(x: (size.width - full.width * k) / 2, y: (size.height - full.height * k) / 2)
            c.scaleBy(x: k, y: k)
            var at: [CGPoint] = Array(repeating: .zero, count: flow.nodes.count)
            for (lv, ids) in Dictionary(grouping: flow.nodes.indices, by: { l[$0] }) {
                for (i, n) in ids.enumerated() { at[n] = CGPoint(x: full.width * (Double(i) + 0.5) / Double(ids.count), y: 55 + Double(lv) * 110) }
            }
            let w: CGFloat = 154, h: CGFloat = 52
            for e in flow.edges {
                let a = at[e.a], b = at[e.b]
                var p = Path()
                let end: CGPoint, dir: CGPoint
                if l[e.b] > l[e.a] {
                    let s = CGPoint(x: a.x, y: a.y + h / 2)
                    end = CGPoint(x: b.x, y: b.y - h / 2 - 2)
                    p.move(to: s)
                    p.addCurve(to: end, control1: CGPoint(x: s.x, y: s.y + 30), control2: CGPoint(x: end.x, y: end.y - 30))
                    dir = CGPoint(x: 0, y: 1)
                } else { // zurück oder gleiche Ebene: außen herum
                    let s = CGPoint(x: a.x + w / 2, y: a.y), out = full.width - 14
                    end = CGPoint(x: b.x + w / 2 + 2, y: b.y)
                    p.move(to: s)
                    p.addCurve(to: end, control1: CGPoint(x: out, y: s.y), control2: CGPoint(x: out, y: end.y))
                    dir = CGPoint(x: -1, y: 0)
                }
                c.stroke(p, with: .color(.primary.opacity(0.65)), lineWidth: 1.8)
                var t = Path()
                t.move(to: end)
                t.addLine(to: CGPoint(x: end.x - dir.x * 9 - dir.y * 5, y: end.y - dir.y * 9 - dir.x * 5))
                t.addLine(to: CGPoint(x: end.x - dir.x * 9 + dir.y * 5, y: end.y - dir.y * 9 + dir.x * 5))
                t.closeSubpath()
                c.fill(t, with: .color(.primary.opacity(0.65)))
                if !e.label.isEmpty, let m = p.trimmedPath(from: 0.5, to: 0.52).currentPoint {
                    let t = c.resolve(Text(e.label).font(.system(size: 13)).foregroundStyle(.primary)), z = t.measure(in: CGSize(width: 140, height: 30))
                    let q = CGRect(x: m.x - z.width / 2 - 4, y: m.y - z.height / 2 - 1, width: z.width + 8, height: z.height + 2)
                    c.fill(Path(roundedRect: q, cornerRadius: 4), with: .style(.background))
                    c.draw(t, at: CGPoint(x: q.midX, y: q.midY))
                }
            }
            for (n, name) in flow.nodes.enumerated() {
                let r = CGRect(x: at[n].x - w / 2, y: at[n].y - h / 2, width: w, height: h), ask = name.hasSuffix("?")
                let ends = !flow.edges.contains { $0.b == n } || !flow.edges.contains { $0.a == n }
                var p = Path()
                if ask { p.move(to: CGPoint(x: r.midX, y: r.minY - 6)); p.addLine(to: CGPoint(x: r.maxX + 8, y: r.midY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY + 6)); p.addLine(to: CGPoint(x: r.minX - 8, y: r.midY)); p.closeSubpath() }
                else { p.addRoundedRect(in: r, cornerSize: CGSize(width: ends ? 26 : 8, height: ends ? 26 : 8)) }
                let col = PlotSpec.colors[ask ? 1 : ends ? 2 : 0]
                c.fill(p, with: .color(col.opacity(0.14)))
                c.stroke(p, with: .color(col), lineWidth: 2)
                let t = c.resolve(Text(name).font(.system(size: name.count > 30 ? 12 : 14, weight: .medium)).foregroundStyle(.primary))
                let box = t.measure(in: CGSize(width: w - (ask ? 46 : 16), height: h - 4))
                c.draw(t, in: CGRect(x: r.midX - box.width / 2, y: r.midY - box.height / 2, width: box.width, height: box.height))
            }
        }
        .accessibilityLabel(L("Ablaufplan", "Flow chart"))
    }
}

struct TruthView: View {
    let vars: [String], rows: [[Bool]], title: String
    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow { ForEach(vars + [title], id: \.self) { Text($0).bold().lineLimit(1).frame(minWidth: 44).padding(.horizontal, 10).padding(.vertical, 4) } }
            Divider()
            ForEach(Array(rows.prefix(16).enumerated()), id: \.offset) { _, r in
                GridRow { ForEach(Array(r.enumerated()), id: \.offset) { i, b in Text(b ? "1" : "0").monospacedDigit().fontWeight(i == vars.count ? .bold : .regular).foregroundStyle(i == vars.count && b ? PlotSpec.colors[2] : .primary).frame(minWidth: 44).padding(.vertical, 2) } }
            }
        }
    }
}

@MainActor func studioWindow<V: View>(_ id: String, _ title: String, resizable: Bool = true, _ v: V) {
    windows[id]?.close()
    windows[id] = nil
    showWindow(id, title, onClose: { DispatchQueue.main.async { MainActor.assumeIsolated { if windows[id]?.isVisible == false { windows[id] = nil } } } }) { v }
    windows[id]?.title = title
    if !resizable { windows[id]?.styleMask.remove(.resizable) }
}
