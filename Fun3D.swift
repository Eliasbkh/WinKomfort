// Würfel, Münze und Glücksrad mit echter Animation (SceneKit, nur solange das Fenster offen ist)
import AppKit
import SwiftUI
import SceneKit

@MainActor final class DiceModel: NSObject, ObservableObject {
    @Published var result: [Int] = []
    @Published var rolling = false
    let n: Int, sides: Int
    let scene = SCNScene()
    private var dice: [SCNNode] = []
    private var timer: Timer?
    private var calm = 0, ticks = 0
    private var last: [(SCNVector3, SCNVector3)] = []
    private static func close(_ a: SCNVector3, _ b: SCNVector3, _ e: CGFloat) -> Bool { abs(a.x - b.x) < e && abs(a.y - b.y) < e && abs(a.z - b.z) < e }
    private static let faces = [1, 2, 6, 5, 3, 4] // vorne, rechts, hinten, links, oben, unten – gegenüber immer 7

    init(_ n: Int, _ sides: Int) {
        self.n = n
        self.sides = sides
        super.init()
        guard sides == 6 else { return }
        scene.background.contents = NSColor(red: 0.07, green: 0.30, blue: 0.24, alpha: 1)
        scene.physicsWorld.gravity = SCNVector3(0, -30, 0)
        let floor = SCNNode(geometry: SCNFloor())
        floor.geometry?.firstMaterial?.diffuse.contents = NSColor(red: 0.09, green: 0.38, blue: 0.30, alpha: 1)
        (floor.geometry as? SCNFloor)?.reflectivity = 0
        floor.physicsBody = .static()
        floor.physicsBody?.friction = 0.8
        scene.rootNode.addChildNode(floor)
        for (x, z, w, d) in [(4.6, 0.0, 0.4, 9.0), (-4.6, 0, 0.4, 9), (0, 2.7, 11, 0.4), (0, -2.9, 11, 0.4)] {
            let wall = SCNNode()
            wall.physicsBody = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: SCNBox(width: w, height: 30, length: d, chamferRadius: 0)))
            wall.position = SCNVector3(x, 10, z)
            scene.rootNode.addChildNode(wall)
        }
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 42
        cam.position = SCNVector3(0, 8.6, 5.2)
        cam.look(at: SCNVector3(0, 0, 0.2))
        scene.rootNode.addChildNode(cam)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.castsShadow = true
        sun.light?.shadowMode = .forward
        sun.light?.automaticallyAdjustsShadowProjection = true
        sun.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.light?.shadowRadius = 6
        sun.light?.shadowSampleCount = 16
        sun.light?.shadowColor = NSColor(white: 0, alpha: 0.5)
        sun.light?.intensity = 900
        sun.eulerAngles = SCNVector3(-1.1, 0.5, 0)
        scene.rootNode.addChildNode(sun)
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 450
        scene.rootNode.addChildNode(amb)
        let mats = Self.faces.map { f -> SCNMaterial in
            let m = SCNMaterial()
            m.diffuse.contents = Self.face(f)
            m.specular.contents = NSColor(white: 0.5, alpha: 1)
            m.shininess = 0.6
            return m
        }
        let size: CGFloat = n > 6 ? 1.1 : 1.35
        for _ in 0..<n {
            let g = SCNBox(width: size, height: size, length: size, chamferRadius: size * 0.13)
            g.chamferSegmentCount = 8
            g.materials = mats
            let d = SCNNode(geometry: g)
            d.physicsBody = SCNPhysicsBody(type: .dynamic, shape: SCNPhysicsShape(geometry: g))
            d.physicsBody?.restitution = 0.35
            d.physicsBody?.friction = 0.6
            d.physicsBody?.angularDamping = 0.25
            scene.rootNode.addChildNode(d)
            dice.append(d)
        }
    }
    private static func face(_ n: Int) -> NSImage {
        NSImage(size: NSSize(width: 256, height: 256), flipped: false) { r in
            NSColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1).setFill()
            r.fill()
            (n == 1 ? NSColor(red: 0.8, green: 0.13, blue: 0.13, alpha: 1) : NSColor(white: 0.1, alpha: 1)).setFill()
            let p: [(CGFloat, CGFloat)] = [[(0.5, 0.5)], [(0.27, 0.27), (0.73, 0.73)], [(0.25, 0.25), (0.5, 0.5), (0.75, 0.75)], [(0.28, 0.28), (0.72, 0.28), (0.28, 0.72), (0.72, 0.72)],
                                           [(0.26, 0.26), (0.74, 0.26), (0.26, 0.74), (0.74, 0.74), (0.5, 0.5)], [(0.29, 0.23), (0.29, 0.5), (0.29, 0.77), (0.71, 0.23), (0.71, 0.5), (0.71, 0.77)]][n - 1]
            let s: CGFloat = n == 1 ? 64 : 46
            for (x, y) in p { NSBezierPath(ovalIn: NSRect(x: x * 256 - s / 2, y: y * 256 - s / 2, width: s, height: s)).fill() }
            return true
        }
    }

    func roll(animated: Bool) {
        timer?.invalidate()
        guard sides == 6 else { number(animated: animated); return }
        result = []
        rolling = true
        calm = 0
        ticks = 0
        last = []
        var r = SystemRandomNumberGenerator()
        for (i, d) in dice.enumerated() {
            d.physicsBody?.clearAllForces()
            d.position = SCNVector3(-3.4 + CGFloat(i % 5) * 1.7, 3.6 + CGFloat(i / 5) * 1.7, -1.2 + CGFloat(i / 5) * 1.2)
            // zufällige Startlage auf ganzer Kugel, damit jede Seite gleich wahrscheinlich ist
            let q = (0..<4).map { _ in Double.random(in: -1...1, using: &r) }, l = max(sqrt(q.reduce(0) { $0 + $1 * $1 }), 0.01)
            d.orientation = SCNQuaternion(q[0] / l, q[1] / l, q[2] / l, q[3] / l)
            d.physicsBody?.resetTransform()
            d.physicsBody?.velocity = SCNVector3(Double.random(in: -3...5, using: &r), -2, Double.random(in: 0...5, using: &r))
            d.physicsBody?.angularVelocity = SCNVector4(Double.random(in: -1...1, using: &r), Double.random(in: -1...1, using: &r), Double.random(in: -1...1, using: &r), Double.random(in: 10...22, using: &r))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { self.check() } }
    }
    private func check() {
        ticks += 1
        // Ruhe daran erkennen, dass sich wirklich nichts mehr bewegt (die Physik meldet oft noch kleine Geschwindigkeiten)
        let now = dice.map { (Self.up($0), $0.presentation.position) }
        let still = last.count == now.count && zip(last, now).allSatisfy { o, n in Self.close(o.0, n.0, 0.01) && Self.close(o.1, n.1, 0.01) } && dice.allSatisfy(Self.flat)
        last = now
        calm = still ? calm + 1 : 0
        if calm >= 3 {
            timer?.invalidate()
            rolling = false
            result = dice.map { Self.top($0).value }
        } else if ticks == 70 || ticks == 110 { // verkantet: anstupsen
            for d in dice where !Self.flat(d) { d.physicsBody?.applyForce(SCNVector3(Double.random(in: -2...2), 4, Double.random(in: -2...2)), asImpulse: true) }
        } else if ticks > 160 { roll(animated: true) }
    }
    private static func up(_ d: SCNNode) -> SCNVector3 { d.presentation.convertVector(SCNVector3(0, 1, 0), from: nil) }
    private static func flat(_ d: SCNNode) -> Bool { let u = up(d); return max(abs(u.x), abs(u.y), abs(u.z)) > 0.985 }
    private static func top(_ d: SCNNode) -> (value: Int, _: Void) {
        let u = up(d), k = [(u.z, 0), (u.x, 1), (-u.z, 2), (-u.x, 3), (u.y, 4), (-u.y, 5)].max { $0.0 < $1.0 }!.1
        return (faces[k], ())
    }
    // Andere Würfel (W4, W20 …): Zahlen laufen durch und bleiben stehen
    private func number(animated: Bool) {
        rolling = true
        var t = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.result = (0..<self.n).map { _ in Int.random(in: 1...self.sides) }
                t += 1
                if t > 18 || !animated { self.timer?.invalidate(); self.rolling = false }
            }
        }
    }
    func stop() { timer?.invalidate() }
}

struct DiceView: View {
    @StateObject private var m: DiceModel
    @Environment(\.accessibilityReduceMotion) private var calm
    init(_ n: Int, _ sides: Int) { _m = StateObject(wrappedValue: DiceModel(n, sides)) }
    var body: some View {
        VStack(spacing: 0) {
            if m.sides == 6 { SceneView(scene: m.scene, options: [.rendersContinuously], antialiasingMode: .multisampling4X).frame(height: 380).onTapGesture { m.roll(animated: !calm) } }
            else {
                HStack(spacing: 14) {
                    ForEach(Array(m.result.prefix(5).enumerated()), id: \.offset) { _, v in
                        Text("\(v)").font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.4).foregroundStyle(.white)
                            .frame(width: 120, height: 120).background(PlotSpec.colors[0].gradient, in: RoundedRectangle(cornerRadius: 26)).scaleEffect(m.rolling && !calm ? 0.94 : 1).animation(.spring(response: 0.3, dampingFraction: 0.5), value: m.rolling)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 240)
            }
            HStack {
                Text(m.rolling ? L("Würfelt …", "Rolling…") : m.result.count > 1 ? m.result.map(String.init).joined(separator: " + ") + " = \(m.result.reduce(0, +))" : m.result.first.map { "\($0)" } ?? "")
                    .font(.title.weight(.semibold)).monospacedDigit()
                Spacer()
                Button(L("Nochmal (Leertaste)", "Roll again (Space)")) { m.roll(animated: !calm) }.keyboardShortcut(.space, modifiers: []).controlSize(.large).disabled(m.rolling)
            }
            .padding(16)
        }
        .frame(width: 620)
        .onAppear { m.roll(animated: !calm) }
        .onDisappear { m.stop() }
    }
}

@MainActor final class CoinModel: ObservableObject {
    @Published var heads: Bool?
    @Published var flipping = false
    let scene = SCNScene()
    private let coin: SCNNode
    private var angle = 0.0
    init() {
        func side(_ t: String) -> NSImage {
            NSImage(size: NSSize(width: 512, height: 512), flipped: false) { r in
                NSColor(red: 0.86, green: 0.67, blue: 0.22, alpha: 1).setFill(); r.fill()
                NSColor(red: 0.66, green: 0.47, blue: 0.10, alpha: 1).setStroke()
                let p = NSBezierPath(ovalIn: r.insetBy(dx: 34, dy: 34)); p.lineWidth = 12; p.stroke()
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 130, weight: .heavy), .foregroundColor: NSColor(red: 0.50, green: 0.34, blue: 0.05, alpha: 1)]
                let s = (t as NSString).size(withAttributes: a)
                (t as NSString).draw(at: NSPoint(x: (512 - s.width) / 2, y: (512 - s.height) / 2), withAttributes: a)
                return true
            }
        }
        let g = SCNCylinder(radius: 1.6, height: 0.22)
        g.radialSegmentCount = 96
        g.materials = [NSColor(red: 0.72, green: 0.53, blue: 0.14, alpha: 1), side(L("KOPF", "HEADS")), side(L("ZAHL", "TAILS"))].map { c -> SCNMaterial in
            let m = SCNMaterial()
            m.diffuse.contents = c
            if c is NSImage { m.diffuse.contentsTransform = SCNMatrix4MakeScale(1, -1, 1); m.diffuse.wrapT = .repeat } // sonst steht die Schrift Kopf
            m.specular.contents = NSColor.white
            m.shininess = 0.8
            return m
        }
        coin = SCNNode(geometry: g)
        coin.eulerAngles.y = -.pi / 2 // Schrift gerade
        let tilt = SCNNode()
        tilt.addChildNode(coin)
        tilt.eulerAngles.x = .pi / 2
        spin.addChildNode(tilt)
        scene.rootNode.addChildNode(spin)
        scene.background.contents = NSColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 1)
        let cam = SCNNode(); cam.camera = SCNCamera(); cam.position = SCNVector3(0, 0, 5.6); scene.rootNode.addChildNode(cam)
        let l = SCNNode(); l.light = SCNLight(); l.light?.type = .omni; l.light?.intensity = 1100; l.position = SCNVector3(3, 4, 6); scene.rootNode.addChildNode(l)
        let a = SCNNode(); a.light = SCNLight(); a.light?.type = .ambient; a.light?.intensity = 420; scene.rootNode.addChildNode(a)
    }
    private let spin = SCNNode()
    func flip(_ calm: Bool) {
        let h = Bool.random()
        heads = nil
        flipping = true
        let to = h ? 0 : Double.pi, by = (calm ? 0 : 16 * Double.pi) + (to - angle), d = calm ? 0.05 : 1.6
        spin.removeAllActions()
        let rot = SCNAction.rotateBy(x: by, y: 0, z: 0, duration: d)
        rot.timingMode = .easeOut
        let up = SCNAction.moveBy(x: 0, y: calm ? 0 : 0.9, z: 0, duration: d / 2), down = SCNAction.moveBy(x: 0, y: calm ? 0 : -0.9, z: 0, duration: d / 2)
        up.timingMode = .easeOut
        down.timingMode = .easeIn
        spin.runAction(.group([rot, .sequence([up, down])]))
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.25) {
            MainActor.assumeIsolated {
                self.spin.removeAllActions()
                self.spin.eulerAngles = SCNVector3(to, 0, 0) // genau auf die Seite, egal wie gerendert wurde
                self.spin.position = SCNVector3(0, 0, 0)
                self.angle = to
                self.heads = h
                self.flipping = false
            }
        }
    }
}
struct CoinView: View {
    @StateObject private var m = CoinModel()
    @Environment(\.accessibilityReduceMotion) private var calm
    var body: some View {
        VStack(spacing: 0) {
            SceneView(scene: m.scene, options: [.rendersContinuously], antialiasingMode: .multisampling4X).frame(height: 320)
            HStack {
                Text(m.heads.map { $0 ? L("Kopf", "Heads") : L("Zahl", "Tails") } ?? L("Wirft …", "Flipping…")).font(.title.weight(.semibold))
                Spacer()
                Button(L("Nochmal (Leertaste)", "Flip again (Space)")) { m.flip(calm) }.keyboardShortcut(.space, modifiers: []).controlSize(.large).disabled(m.flipping)
            }
            .padding(16)
        }
        .frame(width: 440).onAppear { m.flip(calm) }
    }
}

@MainActor final class WheelModel: ObservableObject {
    @Published var angle = 0.0
    @Published var winner: String?
    @Published var spinning = false
    let items: [String]
    init(_ i: [String]) { items = i }
    func spin(_ calm: Bool) {
        winner = nil
        spinning = true
        let n = Double(items.count), k = Int.random(in: 0..<items.count)
        // Feld k unter den Zeiger oben; etwas Streuung innerhalb des Felds
        let target = -(Double(k) + 0.5 + Double.random(in: -0.35...0.35)) * 360 / n
        let base = (angle / 360).rounded(.up) * 360 + (calm ? 0 : 5 * 360)
        withAnimation(calm ? nil : .timingCurve(0.12, 0.8, 0.12, 1, duration: 4.2)) { angle = base + 360 + target }
        DispatchQueue.main.asyncAfter(deadline: .now() + (calm ? 0.05 : 4.3)) { MainActor.assumeIsolated { self.winner = self.items[k]; self.spinning = false } }
    }
}
struct WheelView: View {
    @StateObject private var m: WheelModel
    @Environment(\.accessibilityReduceMotion) private var calm
    init(_ items: [String]) { _m = StateObject(wrappedValue: WheelModel(items)) }
    private let colors: [Color] = [Color(red: 0.12, green: 0.35, blue: 0.40), Color(red: 0.94, green: 0.63, blue: 0.23), Color(red: 0.20, green: 0.50, blue: 0.55), Color(red: 0.80, green: 0.42, blue: 0.20), Color(red: 0.10, green: 0.24, blue: 0.30)]
    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .top) {
                Canvas { c, size in
                    let n = m.items.count, r = min(size.width, size.height) / 2, mid = CGPoint(x: size.width / 2, y: size.height / 2)
                    for (i, t) in m.items.enumerated() {
                        let a = -90 + 360 * Double(i) / Double(n), b = -90 + 360 * Double(i + 1) / Double(n)
                        var p = Path()
                        p.move(to: mid)
                        p.addArc(center: mid, radius: r, startAngle: .degrees(a), endAngle: .degrees(b), clockwise: false)
                        p.closeSubpath()
                        c.fill(p, with: .color(colors[(i == n - 1 && n % colors.count == 1 ? i + 2 : i) % colors.count]))
                        var cc = c
                        cc.translateBy(x: mid.x, y: mid.y)
                        cc.rotate(by: .degrees((a + b) / 2))
                        cc.draw(Text(t.prefix(16)).font(.system(size: n > 12 ? 12 : 16, weight: .semibold)).foregroundStyle(.white), at: CGPoint(x: r * 0.92, y: 0), anchor: .trailing)
                    }
                    c.fill(Path(ellipseIn: CGRect(x: mid.x - 22, y: mid.y - 22, width: 44, height: 44)), with: .color(.white))
                }
                .frame(width: 380, height: 380).rotationEffect(.degrees(m.angle)).padding(.top, 14)
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 34)).foregroundStyle(.red).shadow(radius: 2).accessibilityHidden(true)
            }
            .accessibilityLabel(L("Glücksrad", "Wheel")).accessibilityValue(m.winner ?? "")
            HStack {
                Text(m.winner ?? (m.spinning ? L("Dreht …", "Spinning…") : "")).font(.title.weight(.semibold)).lineLimit(1)
                Spacer()
                Button(L("Drehen (Leertaste)", "Spin (Space)")) { m.spin(calm) }.keyboardShortcut(.space, modifiers: []).controlSize(.large).disabled(m.spinning)
            }
        }
        .padding(18).frame(width: 440).onAppear { m.spin(calm) }
    }
}
