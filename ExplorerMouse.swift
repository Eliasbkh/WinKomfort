// Explorer-Maus wie unter Windows: Rahmen aufziehen, mehrere Dateien auf einmal ziehen
import AppKit
import SwiftUI

// Lage der gerade geladenen Kacheln im Raster
final class TileFrames: ObservableObject { var frames: [URL: CGRect] = [:] }

struct GridMouse: NSViewRepresentable {
    let model: ExplorerModel
    let tiles: TileFrames
    func makeNSView(context: Context) -> GridMouseView { let v = GridMouseView(); v.model = model; v.tiles = tiles; return v }
    func updateNSView(_ v: GridMouseView, context: Context) { v.model = model; v.tiles = tiles }
}

// Zieht alle ausgewählten Dateien als Stapel am Zeiger
@MainActor final class FileDrag: NSObject, @preconcurrency NSDraggingSource {
    static let shared = FileDrag()
    func begin(_ items: [FileItem], from view: NSView, _ e: NSEvent) {
        let p = view.convert(e.locationInWindow, from: nil)
        let drag = items.enumerated().map { n, f -> NSDraggingItem in
            let d = NSDraggingItem(pasteboardWriter: f.url as NSURL)
            let side: CGFloat = 48, o = CGFloat(min(n, 5)) * 6
            d.setDraggingFrame(NSRect(x: p.x - side / 2 + o, y: p.y - side / 2 + o, width: side, height: side), contents: n < 6 ? IconCache.shared.icon(f.url) : nil)
            return d
        }
        guard !drag.isEmpty else { return }
        view.beginDraggingSession(with: drag, event: e, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { [.copy, .move, .link, .generic] }
}

final class GridMouseView: NSView {
    weak var model: ExplorerModel?
    var tiles: TileFrames?
    private var start = NSPoint.zero
    private var pressed: FileItem?
    private var collapse = false                // Klick (ohne Ziehen) auf eine von mehreren → nur diese auswählen
    private var base: Set<URL>?                 // Auswahl vor dem Aufziehen
    private var band = NSRect.zero
    private var seen: [URL: CGRect] = [:]       // beim Aufziehen auch Kacheln, die inzwischen weggescrollt sind

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Nur linke Klicks; Rechtsklick-Menü, Scrollen und Ablegen bleiben bei SwiftUI
    override func hitTest(_ p: NSPoint) -> NSView? {
        guard let e = NSApp.currentEvent, [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(e.type), !e.modifierFlags.contains(.control) else { return nil }
        return super.hitTest(p)
    }
    private func item(at p: NSPoint) -> FileItem? { model?.visible.first { tiles?.frames[$0.url]?.contains(p) == true } }

    override func mouseDown(with e: NSEvent) {
        guard let m = model else { return }
        window?.makeFirstResponder(nil)
        start = convert(e.locationInWindow, from: nil)
        pressed = item(at: start)
        collapse = false
        base = nil
        let mods = e.modifierFlags.intersection([.command, .shift])
        if let it = pressed {
            if e.clickCount == 2, mods.isEmpty { m.activate(it); pressed = nil; return }
            if mods.isEmpty, m.selection.contains(it.url) { collapse = true } else { m.click(it, e.modifierFlags) }
        } else {
            if mods.isEmpty { m.selection = [] }
            base = m.selection
            seen = [:]
        }
    }
    override func mouseDragged(with e: NSEvent) {
        guard let m = model else { return }
        let p = convert(e.locationInWindow, from: nil)
        if let it = pressed {
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            pressed = nil
            if !m.selection.contains(it.url) { m.selection = [it.url] } // ⌘-Klick hatte sie gerade abgewählt
            FileDrag.shared.begin(m.selectedItems, from: self, e)
            return
        }
        guard let base else { return }
        autoscroll(with: e)
        let q = convert(e.locationInWindow, from: nil)
        band = NSRect(x: min(start.x, q.x), y: min(start.y, q.y), width: abs(q.x - start.x), height: abs(q.y - start.y))
        needsDisplay = true
        seen.merge(tiles?.frames ?? [:]) { $1 }
        let hit = Set(m.visible.map(\.url).filter { seen[$0]?.intersects(band) == true })
        let sel = e.modifierFlags.contains(.command) ? base.symmetricDifference(hit) : base.union(hit)
        if sel != m.selection { m.selection = sel }
    }
    override func mouseUp(with e: NSEvent) {
        if collapse, let it = pressed { model?.selection = [it.url] }
        pressed = nil
        base = nil
        band = .zero
        needsDisplay = true
    }
    override func draw(_ r: NSRect) {
        guard !band.isEmpty else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        band.fill()
        NSColor.controlAccentColor.setStroke()
        NSBezierPath(rect: band.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

// Liste: Ziehen am Namen oder an ausgewählten Zeilen zieht die Dateien; sonst wählt Ziehen mehrere Zeilen aus
extension ExplorerWindow {
    @MainActor func listBand(_ e: NSEvent, _ m: ExplorerModel) -> Bool {
        guard !m.grid, e.clickCount <= 2, e.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
              let root = contentView?.superview, var v = root.hitTest(root.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow) else { return false }
        while !(v is NSTableView), let up = v.superview { v = up }
        var table = v as? NSTableView
        if table == nil, let clip = root.hitTest(e.locationInWindow)?.enclosingScrollView { table = clip.documentView as? NSTableView }
        guard let t = table, t.numberOfColumns >= 4, t.numberOfRows == m.visible.count else { return false }
        let p = t.convert(e.locationInWindow, from: nil)
        guard t.visibleRect.contains(p) else { return false }
        let first = t.row(at: p)
        guard first < 0 || m.visible.indices.contains(first) else { return false }
        if e.clickCount == 2 {
            if first >= 0 { m.selection = [m.visible[first].url]; m.openSelection() }
            return true
        }
        let files = first >= 0 && (t.column(at: p) == 0 || t.selectedRowIndexes.contains(first))
        var dragged = false
        while let n = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), n.type != .leftMouseUp {
            let q = t.convert(n.locationInWindow, from: nil)
            if !dragged, abs(q.y - p.y) < 4, abs(q.x - p.x) < 4 { continue }
            dragged = true
            if files {
                let u = m.visible[first].url
                if !m.selection.contains(u) { m.selection = [u] }
                FileDrag.shared.begin(m.selectedItems, from: t, n)
                break
            }
            t.autoscroll(with: n)
            let now = t.convert(n.locationInWindow, from: nil)
            let rows = t.rows(in: NSRect(x: 0, y: min(p.y, now.y), width: t.bounds.width, height: max(abs(now.y - p.y), 1)))
            let sel = Set((rows.location..<(rows.location + rows.length)).filter { m.visible.indices.contains($0) }.map { m.visible[$0].url })
            if sel != m.selection { m.selection = sel }
        }
        if !dragged { m.selection = first >= 0 ? [m.visible[first].url] : [] }
        makeFirstResponder(t)
        return true
    }
}

// Dock-Symbol wie bei einer normalen App, solange ein richtiges Fenster offen ist (Schnellnotiz, Suche, Startmenü sind Panels und zählen nicht)
@MainActor enum DockIcon {
    private static var tokens: [NSObjectProtocol] = []
    static var appWindows: [NSWindow] {
        NSApp.windows.filter { !($0 is NSPanel) && $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
    }
    static func setup() {
        guard tokens.isEmpty else { return }
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { update() } } // beim Schließen ist das Fenster erst danach weg
            })
        }
        // ⌘Q schließt die Fenster, WinKomfort selbst läuft weiter (ganz beenden: Menüleiste oder Dock › Beenden)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.charactersIgnoringModifiers == "q", e.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  MainActor.assumeIsolated({ !appWindows.isEmpty }) else { return e }
            MainActor.assumeIsolated { appWindows.forEach { $0.performClose(nil) } }
            return nil
        }
    }
    private static func update() {
        if NSApp.isHidden { return } // ausgeblendet: Fenster gelten als unsichtbar, das Symbol muss bleiben
        let want: NSApplication.ActivationPolicy = appWindows.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != want else { return }
        let key = NSApp.keyWindow
        NSApp.setActivationPolicy(want)
        if want == .regular { NSApp.activate(ignoringOtherApps: true); key?.makeKeyAndOrderFront(nil) }
    }
    // Klick aufs Dock-Symbol
    static func reopen() {
        let w = appWindows
        if w.isEmpty { openSettingsWindow(); return }
        if !w.contains(where: { !$0.isMiniaturized }) { w.last?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }
}
