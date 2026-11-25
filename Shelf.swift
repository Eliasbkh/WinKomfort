// Ablage: Dateien, Bilder und Text kurz parken – beim Ziehen an der Maus wackeln oder ⌃⌥D
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable { let id = UUID(); let url: URL }

@MainActor final class Shelf: ObservableObject {
    static let shared = Shelf()
    @Published var items: [ShelfItem] = []
    private var panel: KeyPanel?
    private var monitor: Any?
    private var dir: URL { let d = FileManager.default.temporaryDirectory.appendingPathComponent("WinKomfort-Ablage"); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }

    static var shake: Bool { UserDefaults.standard.object(forKey: "shelfShake") as? Bool ?? true }
    func setup() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard Self.shake else { return }
        var last = NSPoint.zero, dir = 0, turns: [Date] = [], count = -1, dragging = false
        // Nur Mausbewegung bei gedrückter Taste; ob wirklich Dateien gezogen werden, sagt die Zwischenablage fürs Ziehen
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown]) { e in
            MainActor.assumeIsolated {
                if e.type != .leftMouseDragged { turns = []; dir = 0; dragging = false; if e.type == .leftMouseDown { count = NSPasteboard(name: .drag).changeCount; last = NSEvent.mouseLocation }; return }
                if !dragging { // erst wenn sich die Zieh-Zwischenablage seit dem Drücken geändert hat
                    let pb = NSPasteboard(name: .drag)
                    guard pb.changeCount != count else { return }
                    guard pb.types?.contains(where: { [.fileURL, .png, .tiff, .string, .URL].contains($0) || $0.rawValue.contains("promise") }) == true else { return }
                    dragging = true; last = NSEvent.mouseLocation
                }
                let p = NSEvent.mouseLocation, dx = p.x - last.x
                guard abs(dx) > 14 else { return }
                let d = dx > 0 ? 1 : -1
                last = p
                if dir != 0, d != dir { turns = turns.filter { Date().timeIntervalSince($0) < 0.7 } + [Date()]; if turns.count >= 4 { turns = []; Shelf.shared.show(at: p) } }
                dir = d
            }
        }
    }
    func toggle() { if panel?.isVisible == true { hide() } else { show(at: nil) } }
    func hide() { panel?.orderOut(nil) }
    func show(at p: NSPoint?) {
        let w = panel ?? {
            let w = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 220), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
            w.level = .floating; w.isMovableByWindowBackground = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = fixedHost(ShelfView(s: self))
            panel = w
            return w
        }()
        let screen = NSScreen.screens.first { $0.frame.contains(p ?? NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0], v = screen.visibleFrame
        let o = p.map { NSPoint(x: $0.x + 24, y: $0.y - 240) } ?? NSPoint(x: v.maxX - 280, y: v.midY - 110)
        w.setFrameOrigin(NSPoint(x: min(max(o.x, v.minX + 8), v.maxX - 268), y: min(max(o.y, v.minY + 8), v.maxY - 228)))
        w.orderFrontRegardless()
    }
    func add(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u, u.isFileURL { Task { @MainActor in self.add(u) } } }
            } else if let t = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                _ = p.loadDataRepresentation(forTypeIdentifier: t) { d, _ in if let d { Task { @MainActor in self.store(d, p.suggestedName ?? L("Bild", "Image"), UTType(t)?.preferredFilenameExtension ?? "png") } } }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { s, _ in if let s, !s.isEmpty { Task { @MainActor in self.store(Data(s.utf8), String(s.prefix(24)), "txt") } } }
            }
        }
        return !providers.isEmpty
    }
    private func add(_ u: URL) { if !items.contains(where: { $0.url == u }) { items.append(ShelfItem(url: u)) } }
    private func store(_ d: Data, _ name: String, _ ext: String) {
        let sub = dir.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let base = MTPSession.safe(name.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))
        let u = sub.appendingPathComponent((base as NSString).pathExtension.lowercased() == ext ? base : base + "." + ext)
        if (try? d.write(to: u)) != nil { add(u) }
    }
    func park(_ u: [URL]) { u.forEach(add); show(at: nil) }
    func clear() { items = []; hide() }
    func drag(_ i: ShelfItem?, _ v: NSView, _ e: NSEvent) {
        let l = (i.map { [$0] } ?? items).filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if l.count < items.count, i == nil { items = l } // inzwischen gelöschte Dateien
        FileDrag.shared.begin(l.map { FileItem(url: $0.url, name: $0.url.lastPathComponent, isDir: false, isPackage: false, size: nil, modified: nil, kind: "") }, from: v, e)
    }
}

private struct ShelfDrag: NSViewRepresentable {
    let item: ShelfItem?
    func makeNSView(context: Context) -> V { let v = V(); v.item = item; return v }
    func updateNSView(_ v: V, context: Context) { v.item = item }
    final class V: NSView {
        var item: ShelfItem?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with e: NSEvent) { if e.clickCount == 2, let u = item?.url { NSWorkspace.shared.open(u) } }
        override func mouseDragged(with e: NSEvent) { MainActor.assumeIsolated { Shelf.shared.drag(item, self, e) } }
    }
}

struct ShelfView: View {
    @ObservedObject var s: Shelf
    @StateObject private var over = TextBox<Bool>()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Ablage", "Shelf")).font(.headline)
                Spacer()
                if !s.items.isEmpty { Button(L("Leeren", "Clear")) { s.clear() }.buttonStyle(.borderless) }
                Button { s.hide() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel(L("Schließen", "Close"))
            }
            .padding(10)
            if s.items.isEmpty {
                Text(L("Hier ablegen, später woanders wieder herausziehen", "Drop here, drag out somewhere else later")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { VStack(spacing: 2) { ForEach(s.items) { i in
                    HStack(spacing: 8) {
                        Image(nsImage: IconCache.shared.icon(i.url)).resizable().frame(width: 26, height: 26)
                        Text(i.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .overlay { ShelfDrag(item: i) }
                    .overlay(alignment: .trailing) { Button { s.items.removeAll { $0.id == i.id } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).padding(.trailing, 10).accessibilityLabel(L("\(i.url.lastPathComponent) entfernen", "Remove \(i.url.lastPathComponent)")) }
                } } }
                Text(s.items.count == 1 ? L("Herausziehen", "Drag out") : L("Alle \(s.items.count) herausziehen", "Drag all \(s.items.count)")).font(.callout.weight(.medium)).frame(maxWidth: .infinity).padding(9).background(.primary.opacity(0.07)).overlay { ShelfDrag(item: nil) }
            }
        }
        .frame(width: 260, height: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(over.value == true ? Color.accentColor : .primary.opacity(0.12), lineWidth: over.value == true ? 2 : 1) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onDrop(of: [.fileURL, .image, .text], isTargeted: Binding(get: { over.value ?? false }, set: { over.value = $0 })) { s.add($0) }
    }
}
