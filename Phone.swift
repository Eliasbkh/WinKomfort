// Android-Handy per USB: Verbindung, Übertragung und Fenster
import AppKit
import IOKit.usb
import IOUSBHost
import SwiftUI
import UniformTypeIdentifiers

// MARK: - USB

final class USBLink: MTPLink {
    private let iface: IOUSBHostInterface
    private let input: IOUSBHostPipe, output: IOUSBHostPipe
    let packet: Int

    private init(_ f: IOUSBHostInterface) throws {
        var i: IOUSBHostPipe?, o: IOUSBHostPipe?, size = 512
        var h = UnsafeRawPointer(f.interfaceDescriptor).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let e = IOUSBGetNextEndpointDescriptor(f.configurationDescriptor, f.interfaceDescriptor, h) {
            let a = e.pointee.bEndpointAddress
            if e.pointee.bmAttributes & 3 == 2 {
                let p = try f.copyPipe(withAddress: Int(a))
                if a & 0x80 != 0 { i = p } else { o = p; size = Int(UInt16(littleEndian: e.pointee.wMaxPacketSize) & 0x7FF) }
            }
            h = UnsafeRawPointer(e).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let i, let o else { f.destroy(); throw MTPError.broken }
        iface = f; input = i; output = o; packet = max(size, 64)
        while let d = try? read(timeout: 0.2), !d.isEmpty {} // Rest einer abgebrochenen Übertragung verwerfen
    }
    func write(_ d: Data) throws {
        let m = NSMutableData(data: d); var n = 0
        try output.__sendIORequest(with: m, bytesTransferred: &n, completionTimeout: 10)
        if n != d.count { throw MTPError.broken }
    }
    func read(timeout: TimeInterval) throws -> Data {
        let m = NSMutableData(length: MTPSession.chunk)!; var n = 0
        try input.__sendIORequest(with: m, bytesTransferred: &n, completionTimeout: timeout)
        return Data(bytes: m.bytes, count: n)
    }
    func destroy() { iface.destroy() }

    static func matches(_ s: io_service_t) -> Bool {
        (IORegistryEntryCreateCFProperty(s, "kUSBString" as CFString, nil, 0)?.takeRetainedValue() as? String)?.contains("MTP") == true
    }
    static func find() -> io_service_t? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &it) == 0 else { return nil }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 { if matches(s) { return s }; IOObjectRelease(s) }
        return nil
    }
    // macOS (Fotos/Digitale Bilder) hält die Schnittstelle meist schon fest → dessen Hilfsprozess beenden, macOS startet ihn bei Bedarf neu
    static func claim() throws -> USBLink {
        var last: Error = MTPError.broken
        for _ in 0..<400 {
            guard let s = find() else { usleep(10_000); continue }
            defer { IOObjectRelease(s) }
            do { return try USBLink(IOUSBHostInterface(__ioService: s, options: [], queue: nil, interestHandler: nil)) } catch {
                last = error
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); p.arguments = ["-9", "ptpcamerad"]
                p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
                if (try? p.run()) != nil { p.waitUntilExit() }
                usleep(5_000)
            }
        }
        throw last
    }
    // Wie einmal ab- und anstecken
    static func reset() {
        guard let s = find() else { return }
        defer { IOObjectRelease(s) }
        var dev: io_service_t = 0
        guard IORegistryEntryGetParentEntry(s, kIOServicePlane, &dev) == 0 else { return }
        defer { IOObjectRelease(dev) }
        guard let d = try? IOUSBHostDevice(__ioService: dev, options: [], queue: nil, interestHandler: nil) else { return }
        try? d.reset()
        d.destroy()
        usleep(600_000) // Handy meldet sich neu an
    }
}

// Steckt ein Handy? Ereignisse statt Abfragen
@MainActor final class PhoneWatch: ObservableObject {
    static let shared = PhoneWatch()
    @Published private(set) var connected = false
    private var port: IONotificationPortRef?
    private var iters: [io_iterator_t] = []
    private init() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        for n in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, n, IOServiceMatching("IOUSBHostInterface"), { _, it in
                while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }
                MainActor.assumeIsolated { PhoneWatch.shared.check() }
            }, nil, &it)
            while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }
            iters.append(it)
        }
        check()
    }
    private func check() {
        let s = USBLink.find(); if let s { IOObjectRelease(s) }
        if connected != (s != nil) { connected = s != nil }
    }
}

// MARK: - Modell

struct PhoneItem: Identifiable, Hashable {
    let id: UInt32
    let o: MTPObject
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
    var name: String { o.name }
    var size: Int64 { o.isDir ? -1 : o.size }
    var date: Date { o.modified ?? .distantPast }
    var type: UTType { o.isDir ? .folder : UTType(filenameExtension: (o.name as NSString).pathExtension) ?? .data }
}

private final class Flag: @unchecked Sendable { // über Threads: nur setzen und lesen
    private let l = NSLock(); private var v = false
    var on: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
}

@MainActor final class PhoneModel: ObservableObject {
    static let shared = PhoneModel()
    enum Phase: Equatable { case idle, connecting, ready, failed(String) }
    struct Crumb: Equatable { let storage: UInt32, parent: UInt32, title: String }
    @Published var phase = Phase.idle
    @Published var name = L("Handy", "Phone")
    @Published var path: [Crumb] = []
    @Published var items: [PhoneItem] = []
    @Published var loading = false
    @Published var selection: Set<UInt32> = []
    @Published var sort: [KeyPathComparator<PhoneItem>] = [KeyPathComparator(\PhoneItem.name, comparator: .localizedStandard)]
    @Published var showHidden = false
    @Published var job: String?
    @Published var progress: Double?
    @Published var free: Int64?
    @Published var error: String?

    private let queue = DispatchQueue(label: "winkomfort.mtp", qos: .userInitiated) // alle USB-Aufrufe nacheinander, nie auf dem Hauptthread
    nonisolated(unsafe) private var session: MTPSession? // nur auf `queue`
    nonisolated(unsafe) private var link: USBLink?
    private var loadID = Flag()
    private var cancelFlag = Flag()

    var visible: [PhoneItem] {
        let l = showHidden ? items : items.filter { !$0.name.hasPrefix(".") }
        let s = l.sorted(using: sort)
        return s.filter(\.o.isDir) + s.filter { !$0.o.isDir }
    }
    var picked: [PhoneItem] { visible.filter { selection.contains($0.id) } }

    private func work<T>(_ f: @escaping (MTPSession) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async {
                guard let s = self.session else { c.resume(throwing: MTPError.broken); return }
                c.resume(with: Result { try f(s) })
            }
        }
    }

    // MARK: Verbindung
    func connect() {
        guard phase != .connecting, phase != .ready else { return }
        phase = .connecting
        queue.async {
            var result: Result<(String?, [(id: UInt32, name: String, free: Int64)]), Error> = .failure(MTPError.broken)
            for attempt in 0..<2 {
                do {
                    let l = try USBLink.claim(), s = MTPSession(l)
                    do {
                        try s.open()
                        let st = try s.storages()
                        self.link = l; self.session = s
                        result = .success((s.deviceName(), st))
                    } catch { l.destroy(); throw error }
                    break
                } catch {
                    result = .failure(error)
                    if attempt == 0 { USBLink.reset() } // hängt noch in einem Auftrag von macOS
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.connected(result) } }
        }
    }
    private func connected(_ r: Result<(String?, [(id: UInt32, name: String, free: Int64)]), Error>) {
        switch r {
        case .failure:
            phase = .failed(L("Entsperre dein Handy und tippe in der USB-Benachrichtigung auf „Dateien übertragen“. Hilft das nicht, zieh das Kabel kurz ab.",
                              "Unlock your phone and choose “File transfer” in its USB notification. If that doesn't help, replug the cable."))
            disconnect(keepPhase: true)
        case .success(let (n, st)):
            if let n { name = n; PhoneWindow.window?.title = n }
            guard !st.isEmpty else {
                phase = .failed(L("Das Handy gibt seinen Speicher noch nicht frei. Entsperre es und wähle „Dateien übertragen“.",
                                  "The phone isn't sharing its storage yet. Unlock it and choose “File transfer”."))
                disconnect(keepPhase: true); return
            }
            phase = .ready
            roots = st
            open(Crumb(storage: st[0].id, parent: MTPSession.root, title: st.count > 1 ? st[0].name : name), at: 0)
        }
    }
    @Published var roots: [(id: UInt32, name: String, free: Int64)] = []
    func disconnect(keepPhase: Bool = false) {
        cancelFlag.on = true; loadID.on = true
        if !keepPhase { phase = .idle }
        items = []; path = []; selection = []; roots = []; job = nil; progress = nil; loading = false
        queue.async { // wartet auf den laufenden Auftrag, sonst hängt das Handy
            self.session?.close(); self.link?.destroy()
            self.session = nil; self.link = nil
        }
    }

    // MARK: Ordner
    func open(_ c: Crumb, at depth: Int) {
        path = Array(path.prefix(depth)) + [c]
        reload()
    }
    func openFolder(_ i: PhoneItem) { open(Crumb(storage: i.o.storage, parent: i.id, title: i.name), at: path.count) }
    func goBack() { if path.count > 1 { open(path[path.count - 2], at: path.count - 2) } }
    func reload() {
        guard let c = path.last else { return }
        loadID.on = true
        let mine = Flag(); loadID = mine
        items = []; selection = []; loading = true
        queue.async {
            guard let s = self.session else { return }
            var buf: [PhoneItem] = [], stamp = Date()
            func push(_ done: Bool) {
                let part = buf; buf = []
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard !mine.on else { return }
                    self.items += part
                    if done { self.loading = false }
                } }
            }
            do {
                if let f = (try? s.storages())?.first(where: { $0.id == c.storage })?.free { DispatchQueue.main.async { MainActor.assumeIsolated { self.free = f } } }
                for h in try s.handles(c.storage, c.parent) {
                    if mine.on { return }
                    do { let o = try s.info(h); buf.append(PhoneItem(id: h, o: o)) } catch MTPError.response { continue } // inzwischen gelöscht
                    if Date().timeIntervalSince(stamp) > 0.25 { push(false); stamp = Date() } // große Ordner füllen sich nach und nach
                }
                push(true)
            } catch { DispatchQueue.main.async { MainActor.assumeIsolated { if !mine.on { self.lost(error) } } } }
        }
    }
    private func lost(_ e: Error) {
        loading = false
        if case MTPError.response = e { error = text(e); return }
        phase = .failed(L("Verbindung zum Handy verloren.", "Lost the connection to the phone."))
        disconnect(keepPhase: true)
    }
    func text(_ e: Error) -> String {
        switch e {
        case MTPError.response(0x200C): L("Auf dem Handy ist kein Platz mehr.", "The phone is out of space.")
        case MTPError.response(0x200F), MTPError.response(0x200E): L("Das Handy erlaubt das hier nicht. Ist es entsperrt?", "The phone doesn't allow this here. Is it unlocked?")
        case MTPError.response(let c): L("Das Handy hat abgelehnt (Code \(String(c, radix: 16))).", "The phone refused (code \(String(c, radix: 16))).")
        case MTPError.tooBig: L("Dateien über 4 GB lassen sich nicht aufs Handy kopieren.", "Files over 4 GB can't be copied to the phone.")
        case is MTPError: L("Verbindung zum Handy verloren.", "Lost the connection to the phone.")
        default: e.localizedDescription
        }
    }

    // MARK: Übertragen
    func cancel() { cancelFlag.on = true }

    // Auf den Mac; nie überschreiben. Ergebnis: die angelegten Dateien
    func download(_ list: [PhoneItem], to dir: URL) async -> [URL] {
        let stop = begin(L("Kopiere auf den Mac …", "Copying to Mac …"))
        let total = list.reduce(Int64(0)) { $0 + ($1.o.isDir ? 0 : $1.o.size) }, anyDir = list.contains { $0.o.isDir }
        var made: [URL] = []
        do {
            for i in list {
                made.append(try await work { s in
                    var done: Int64 = 0, stamp = Date.distantPast
                    let base = made.reduce(Int64(0)) { a, u in a + Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
                    return try Self.fetch(s, i.o, to: dir, stop: stop) { n in
                        done += Int64(n)
                        guard !anyDir, total > 0, Date().timeIntervalSince(stamp) > 0.1 else { return }
                        stamp = Date(); let p = Double(base + done) / Double(total)
                        DispatchQueue.main.async { MainActor.assumeIsolated { if self.cancelFlag === stop, !stop.on { self.progress = min(p, 1) } } }
                    }
                })
            }
        } catch { finish(error, stop); return made }
        finish(nil, stop)
        return made
    }
    private nonisolated static func fetch(_ s: MTPSession, _ o: MTPObject, to dir: URL, stop: Flag, tick: @escaping (Int) -> Void) throws -> URL {
        if stop.on { throw MTPError.cancelled }
        let fm = FileManager.default
        let target = dir.appendingPathComponent(MTPSession.unique(o.name, taken: Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])))
        if o.isDir {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            for h in try s.handles(o.storage, o.handle) { _ = try fetch(s, s.info(h), to: target, stop: stop, tick: tick) }
            return target
        }
        // Erst vollständig laden, dann richtig benennen – nie eine halbe Datei unter dem echten Namen
        let part = dir.appendingPathComponent(".winkomfort-\(UUID().uuidString)")
        guard fm.createFile(atPath: part.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
        do {
            let f = try FileHandle(forWritingTo: part)
            defer { try? f.close() }
            var n: Int64 = 0
            try s.download(o.handle) { d in
                if stop.on { throw MTPError.cancelled }
                try f.write(contentsOf: d); n += Int64(d.count); tick(d.count)
            }
            if n != o.size { throw MTPError.broken }
        } catch { try? fm.removeItem(at: part); throw error }
        if let m = o.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: part.path) }
        try fm.moveItem(at: part, to: target)
        return target
    }

    func upload(_ urls: [URL]) {
        guard phase == .ready, let c = path.last, !urls.isEmpty, job == nil else { NSSound.beep(); return }
        let stop = begin(L("Kopiere aufs Handy …", "Copying to phone …"))
        Task {
            do {
                var taken = try await work { s in Set(try s.handles(c.storage, c.parent).compactMap { try? s.info($0).name }) }
                for (k, u) in urls.enumerated() {
                    if urls.count > 1 { progress = Double(k) / Double(urls.count) }
                    let n = MTPSession.unique(MTPSession.safe(u.lastPathComponent), taken: taken)
                    taken.insert(n)
                    let single = urls.count == 1
                    try await work { s in
                        try Self.put(s, u, name: n, storage: c.storage, parent: c.parent, stop: stop) { p in
                            guard single else { return }
                            DispatchQueue.main.async { MainActor.assumeIsolated { if self.cancelFlag === stop, !stop.on { self.progress = p } } }
                        }
                    }
                }
                finish(nil, stop)
            } catch { finish(error, stop) }
            if phase == .ready, path.last == c { reload() }
        }
    }
    private nonisolated static func put(_ s: MTPSession, _ u: URL, name: String, storage: UInt32, parent: UInt32, stop: Flag, tick: @escaping (Double) -> Void) throws {
        if stop.on { throw MTPError.cancelled }
        let v = try u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
        if v.isSymbolicLink == true { return }
        if v.isDirectory == true {
            let h = try s.create(name, size: 0, folder: true, storage: storage, parent: parent)
            for f in try FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil) where f.lastPathComponent != ".DS_Store" {
                try put(s, f, name: MTPSession.safe(f.lastPathComponent), storage: storage, parent: h, stop: stop, tick: { _ in })
            }
            return
        }
        let size = v.fileSize ?? 0
        let f = try FileHandle(forReadingFrom: u); defer { try? f.close() }
        var n = 0, stamp = Date.distantPast
        // Mitten in einer Datei wird nicht abgebrochen: das Handy wartet auf genau die angekündigten Bytes
        try s.create(name, size: size, folder: false, storage: storage, parent: parent) { k in
            let d = try f.read(upToCount: k) ?? Data()
            n += d.count
            if Date().timeIntervalSince(stamp) > 0.1 { stamp = Date(); tick(Double(n) / Double(max(size, 1))) }
            return d
        }
    }
    private func begin(_ t: String) -> Flag { let f = Flag(); cancelFlag = f; job = t; progress = nil; return f }
    private func finish(_ e: Error?, _ f: Flag) {
        guard cancelFlag === f else { return }
        job = nil; progress = nil
        guard let e, e as? MTPError != .cancelled, phase == .ready else { return }
        let usb = (e as NSError).domain.contains("IOUSBHost") || e as? MTPError == .broken
        if usb { lost(e) } else { error = text(e) }
    }

    // MARK: Aktionen
    private static let tempBase: URL = { // einmal je Programmstart aufräumen
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("WinKomfort-Handy")
        try? FileManager.default.removeItem(at: d)
        return d
    }()
    static var temp: URL {
        let d = tempBase.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func activate(_ ids: Set<UInt32>) {
        let l = visible.filter { ids.contains($0.id) }
        if l.count == 1, l[0].o.isDir { openFolder(l[0]); return }
        guard job == nil else { NSSound.beep(); return }
        Task { for u in await download(l.filter { !$0.o.isDir }, to: Self.temp) { NSWorkspace.shared.open(u) } }
    }
    func copyToClipboard(_ l: [PhoneItem]) {
        guard !l.isEmpty, job == nil else { NSSound.beep(); return }
        Task {
            let u = await download(l, to: Self.temp)
            guard u.count == l.count else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(u as [NSURL])
            Toast.show(L("Kopiert – mit ⌘V einfügen", "Copied – paste with ⌘V"), symbol: "doc.on.doc")
        }
    }
    func saveToMac(_ l: [PhoneItem], ask: Bool = false) {
        guard !l.isEmpty, job == nil else { NSSound.beep(); return }
        var dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        if ask {
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.prompt = L("Hierhin kopieren", "Copy here")
            guard p.runModal() == .OK, let u = p.url else { return }
            dir = u
        }
        saveToMac(l, dir: dir)
    }
    func saveToMac(_ l: [PhoneItem], dir: URL) {
        guard !l.isEmpty, job == nil else { NSSound.beep(); return }
        Task {
            let u = await download(l, to: dir)
            if u.count == l.count { Toast.show(L("Liegt jetzt in „\(dir.lastPathComponent)“", "Saved to “\(dir.lastPathComponent)”"), symbol: "checkmark.circle") }
        }
    }
    func pasteToPhone() {
        upload(NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
    }
    func chooseUpload() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.prompt = L("Aufs Handy kopieren", "Copy to phone")
        if p.runModal() == .OK { upload(p.urls) }
    }

    // Ziehen: in den eigenen Explorer als Verweis, in andere Apps als Dateiversprechen
    static let dragType = "de.winkomfort.phone-item"
    func dragProvider(_ i: PhoneItem) -> NSItemProvider {
        let p = NSItemProvider()
        p.suggestedName = i.o.isDir ? i.name : (i.name as NSString).deletingPathExtension
        let ids = (selection.contains(i.id) ? picked : [i]).map { String($0.id) }.joined(separator: ",")
        p.registerDataRepresentation(forTypeIdentifier: Self.dragType, visibility: .ownProcess) { done in done(Data(ids.utf8), nil); return nil }
        p.registerFileRepresentation(forTypeIdentifier: i.type.identifier, fileOptions: [], visibility: .all) { done in
            let pr = Progress(totalUnitCount: 1)
            Task { @MainActor in
                let u = await self.download([i], to: Self.temp).first
                pr.completedUnitCount = 1
                done(u, false, u == nil ? MTPError.broken : nil)
            }
            return pr
        }
        return p
    }
    func dropped(_ providers: [NSItemProvider], to dir: URL) -> Bool {
        guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(Self.dragType) }) else { return false }
        p.loadDataRepresentation(forTypeIdentifier: Self.dragType) { d, _ in
            let ids = Set(String(decoding: d ?? Data(), as: UTF8.self).split(separator: ",").compactMap { UInt32($0) })
            Task { @MainActor in self.saveToMac(self.visible.filter { ids.contains($0.id) }, dir: dir) }
        }
        return true
    }
}

// MARK: - Fenster

@MainActor enum PhoneWindow {
    static var window: NSWindow?
    private static var tokens: [NSObjectProtocol] = []
    static func show() {
        PhoneModel.shared.connect()
        if let window { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = PhoneModel.shared.name
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 320)
        w.tabbingMode = .disallowed // neben dem Explorer, damit man hin- und herziehen kann
        let host = NSHostingController(rootView: PhoneView(model: PhoneModel.shared))
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(NSSize(width: 820, height: 560))
        w.center(); w.setFrameAutosaveName("WinKomfortPhone")
        tokens = [NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                PhoneModel.shared.disconnect() // Handy wieder für andere Apps freigeben
                window = nil
                tokens.forEach { NotificationCenter.default.removeObserver($0) }; tokens = []
            }
        }]
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

// Zeile unter „Geräte“ im Explorer
struct PhoneRow: View {
    @ObservedObject private var model = PhoneModel.shared
    var body: some View {
        Button { PhoneWindow.show() } label: {
            Label(model.name, systemImage: "smartphone").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PhoneView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject private var watch = PhoneWatch.shared

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .ready: browser
            case .connecting, .idle:
                ProgressView(L("Verbinde mit dem Handy …", "Connecting to the phone …")).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let why):
                ContentUnavailableView {
                    Label(watch.connected ? L("Noch nicht verbunden", "Not connected yet") : L("Kein Handy gefunden", "No phone found"), systemImage: "smartphone")
                } description: { Text(why) } actions: {
                    Button(L("Erneut versuchen", "Try again")) { model.connect() }.buttonStyle(.borderedProminent).disabled(!watch.connected)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .onChange(of: watch.connected) { _, on in if on, case .failed = model.phase { model.connect() } }
        .alert(L("Das ging nicht", "That didn't work"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func tool(_ symbol: String, _ label: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) { Image(systemName: symbol).frame(width: 26, height: 24) }.buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                tool("chevron.left", L("Zurück", "Back")) { model.goBack() }.disabled(model.path.count < 2).keyboardShortcut(.leftArrow)
                if model.roots.count > 1 {
                    Menu { ForEach(model.roots, id: \.id) { r in Button(r.name) { model.open(.init(storage: r.id, parent: MTPSession.root, title: r.name), at: 0) } } }
                        label: { Image(systemName: "internaldrive") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("Speicher wählen", "Choose storage"))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(model.path.enumerated()), id: \.offset) { i, c in
                            if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true) }
                            let last = i == model.path.count - 1
                            Button { model.open(c, at: i) } label: { Text(c.title).lineLimit(1).fontWeight(last ? .semibold : .regular).padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle()) }
                                .buttonStyle(.plain).foregroundStyle(last ? .primary : .secondary)
                        }
                    }
                }
                tool("arrow.clockwise", L("Aktualisieren", "Refresh")) { model.reload() }.keyboardShortcut("r")
                Group {
                    Button { model.saveToMac(model.picked) } label: { Label(L("In Downloads", "To Downloads"), systemImage: "arrow.down.circle") }
                        .disabled(model.selection.isEmpty).help(L("Auswahl in den Ordner „Downloads“ kopieren", "Copy selection to Downloads"))
                    Button { model.chooseUpload() } label: { Label(L("Aufs Handy …", "To phone …"), systemImage: "arrow.up.circle") }
                        .help(L("Dateien vom Mac hierher kopieren", "Copy files from the Mac here"))
                }.disabled(model.job != nil)
                Menu {
                    Button(L("Kopieren", "Copy")) { model.copyToClipboard(model.picked) }.keyboardShortcut("c").disabled(model.selection.isEmpty)
                    Button(L("Auf den Mac kopieren nach …", "Copy to Mac folder …")) { model.saveToMac(model.picked, ask: true) }.disabled(model.selection.isEmpty)
                    Button(L("Vom Mac einfügen", "Paste from Mac")) { model.pasteToPhone() }.keyboardShortcut("v")
                    Divider()
                    Toggle(L("Versteckte Dateien zeigen", "Show hidden files"), isOn: $model.showHidden)
                } label: { Image(systemName: "line.3.horizontal") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("Mehr", "More"))
            }
            .padding(.horizontal, 10).frame(height: 44)
            Divider()
            table
            Divider()
            HStack(spacing: 8) {
                if let j = model.job {
                    Text(j)
                    if let p = model.progress { ProgressView(value: p).frame(width: 140) } else { ProgressView().controlSize(.small) }
                    Button(L("Abbrechen", "Cancel")) { model.cancel() }.buttonStyle(.link)
                } else {
                    Text(status)
                    if model.loading { ProgressView().controlSize(.small) }
                }
                Spacer()
                if let f = model.free { Text(L("\(bytes(f)) frei", "\(bytes(f)) free")) }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 26)
        }
    }
    private var status: String {
        let p = model.picked
        if p.isEmpty { return L("\(model.visible.count) Objekte", "\(model.visible.count) items") }
        return L("\(p.count) ausgewählt", "\(p.count) selected") + " · " + bytes(p.reduce(0) { $0 + max($1.size, 0) })
    }
    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private var table: some View {
        Table(of: PhoneItem.self, selection: $model.selection, sortOrder: $model.sort) {
            TableColumn(L("Name", "Name"), value: \.name) { i in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(for: i.type)).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                    Text(i.name).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn(L("Geändert", "Modified"), value: \.date) { i in
                Text(i.o.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "–").foregroundStyle(.secondary)
            }.width(min: 120, ideal: 160, max: 220)
            TableColumn(L("Größe", "Size"), value: \.size) { i in
                Text(i.o.isDir ? "–" : bytes(i.size)).foregroundStyle(.secondary).monospacedDigit()
            }.width(min: 70, ideal: 90, max: 120)
        } rows: {
            ForEach(model.visible) { i in TableRow(i).itemProvider { model.dragProvider(i) } }
        }
        .contextMenu(forSelectionType: UInt32.self) { ids in
            let l = model.visible.filter { ids.contains($0.id) }
            if !l.isEmpty {
                Button(L("Öffnen", "Open")) { model.activate(ids) }
                Button(L("Kopieren", "Copy")) { model.copyToClipboard(l) }
                Button(L("In „Downloads“ kopieren", "Copy to Downloads")) { model.saveToMac(l) }
                Button(L("Auf den Mac kopieren nach …", "Copy to Mac folder …")) { model.saveToMac(l, ask: true) }
            } else {
                Button(L("Vom Mac einfügen", "Paste from Mac")) { model.pasteToPhone() }
            }
        } primaryAction: { model.activate($0) }
        .overlay {
            if !model.loading, model.visible.isEmpty { ContentUnavailableView(L("Ordner ist leer", "Folder is empty"), systemImage: "folder", description: Text(L("Dateien vom Mac hierher ziehen.", "Drag files from the Mac here."))) }
        }
        .dropDestination(for: URL.self) { urls, _ in model.upload(urls.filter(\.isFileURL)); return true }
    }
}
