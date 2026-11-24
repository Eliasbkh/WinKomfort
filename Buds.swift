// Galaxy Buds am Mac: Akku, Geräuschsteuerung, Mikrofon. Verbunden wird nur, solange die Seite offen ist oder du etwas umschaltest.
import AppKit
import SwiftUI
import IOBluetooth
import CoreBluetooth
import CoreAudio

@MainActor final class Buds: NSObject, ObservableObject, @preconcurrency IOBluetoothRFCOMMChannelDelegate, @preconcurrency CBCentralManagerDelegate {
    static let shared = Buds()
    @Published private(set) var name: String?
    @Published private(set) var status = BudsStatus()
    @Published private(set) var message = ""
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "buds") }
    static let modes: [(Int, String, String)] = [(0, "Aus", "Off"), (1, "Geräuschunterdrückung", "Noise cancelling"), (2, "Umgebung", "Ambient"), (3, "Adaptiv", "Adaptive")]
    private var channel: IOBluetoothRFCOMMChannel?
    private var isOpen = false
    private var buffer: [UInt8] = []
    private var pending: [UInt8]?
    private var users = 0
    private var closing: DispatchWorkItem?

    func appear() { users += 1; connect() }
    func disappear() { users = max(0, users - 1); closeSoon() }

    func connect(tries: Int = 5) {
        guard Self.enabled else { return }
        closing?.cancel()
        guard channel == nil else { return }
        // Erst ohne zu blockieren um Erlaubnis fragen – IOBluetooth würde sonst die ganze App anhalten, bis du antwortest
        switch CBCentralManager.authorization {
        case .allowedAlways: break
        case .notDetermined:
            message = L("Bitte Bluetooth erlauben", "Please allow Bluetooth")
            if asker == nil { asker = CBCentralManager(delegate: self, queue: .main) }
            return
        default: message = L("Bluetooth ist für WinKomfort nicht erlaubt", "Bluetooth isn't allowed for WinKomfort"); pending = nil; return
        }
        let audio = BudsMic.bluetoothNames() // isConnected() stimmt auf macOS 27 nicht; als Audiogerät da = verbunden
        guard let dev = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: { ($0.name ?? "").contains("Buds") && ($0.isConnected() || audio.contains($0.name ?? "")) }) else {
            // Direkt nach dem Start kennt macOS den Verbindungsstand noch nicht
            if tries > 0 {
                message = L("Sucht …", "Searching…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { if self.users > 0 || self.pending != nil { self.connect(tries: tries - 1) } } }
                return
            }
            name = nil; status = BudsStatus(); message = L("Keine Galaxy Buds verbunden", "No Galaxy Buds connected"); pending = nil
            return
        }
        name = dev.name
        var id: BluetoothRFCOMMChannelID = 0
        guard let rec = (dev.services as? [IOBluetoothSDPServiceRecord])?.first(where: { $0.getServiceName() == "GEARMANAGER" }), rec.getRFCOMMChannelID(&id) == kIOReturnSuccess else {
            message = L("Diese Buds lassen sich nicht auslesen", "These Buds can't be read"); return
        }
        message = L("Verbindet …", "Connecting…")
        var c: IOBluetoothRFCOMMChannel?
        if dev.openRFCOMMChannelAsync(&c, withChannelID: id, delegate: self) == kIOReturnSuccess { channel = c } else { message = L("Verbindung fehlgeschlagen", "Connection failed") }
    }
    private var asker: CBCentralManager?
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard CBCentralManager.authorization != .notDetermined else { return }
        asker = nil
        connect()
    }
    private func closeSoon() {
        closing?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { if self.users == 0 { self.close() } } }
        closing = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }
    private func close() { _ = channel?.close(); channel = nil; isOpen = false; buffer = []; pending = nil }

    func setMode(_ m: Int) {
        let msg = BudsProtocol.message(0x78, [UInt8(m)])
        if isOpen { send(msg) } else { pending = msg; connect() }
        closeSoon()
    }
    private func send(_ m: [UInt8]) {
        var d = m
        if channel?.writeAsync(&d, length: UInt16(d.count), refcon: nil) != kIOReturnSuccess { message = L("Umschalten fehlgeschlagen", "Switching failed") }
    }

    func rfcommChannelOpenComplete(_ c: IOBluetoothRFCOMMChannel!, status e: IOReturn) {
        guard e == kIOReturnSuccess else { channel = nil; message = L("Verbindung fehlgeschlagen", "Connection failed"); pending = nil; return }
        isOpen = true
        message = ""
        if let p = pending { pending = nil; send(p) }
    }
    func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data p: UnsafeMutableRawPointer!, length n: Int) {
        buffer += UnsafeRawBufferPointer(start: p, count: n)
        for m in BudsProtocol.take(&buffer) { BudsProtocol.apply(m.id, m.data, to: &status) }
    }
    func rfcommChannelClosed(_ c: IOBluetoothRFCOMMChannel!) {
        channel = nil; isOpen = false; buffer = []
        if users > 0 { message = L("Getrennt", "Disconnected") }
    }
}

// Nutzt macOS die Buds auch als Mikrofon, klingt Musik dumpf (Telefon-Modus). Auf Wunsch bleibt das Mac-Mikrofon aktiv.
enum BudsMic {
    private static var listening = false
    private static var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    static func update() {
        guard UserDefaults.standard.bool(forKey: "budsMic") else { return }
        if !listening {
            listening = true
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                if UserDefaults.standard.bool(forKey: "budsMic") { fix() }
            }
        }
        fix()
    }
    private static func transport(_ d: AudioDeviceID) -> UInt32 {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0, n = UInt32(4)
        AudioObjectGetPropertyData(d, &a, 0, nil, &n, &v)
        return v
    }
    private static func hasInput(_ d: AudioDeviceID) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var n: UInt32 = 0
        return AudioObjectGetPropertyDataSize(d, &a, 0, nil, &n) == noErr && n > 0
    }
    private static func devices() -> [AudioDeviceID] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
        AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids)
        return ids
    }
    static func bluetoothNames() -> Set<String> {
        Set(devices().filter { transport($0) == kAudioDeviceTransportTypeBluetooth }.compactMap { d in
            var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var n = UInt32(MemoryLayout<CFString?>.size)
            return AudioObjectGetPropertyData(d, &a, 0, nil, &n, &name) == noErr ? name?.takeRetainedValue() as String? : nil
        })
    }
    private static func fix() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var cur = AudioDeviceID(0), n = UInt32(4)
        guard AudioObjectGetPropertyData(sys, &address, 0, nil, &n, &cur) == noErr, transport(cur) == kAudioDeviceTransportTypeBluetooth else { return }
        let ids = devices()
        guard var mic = ids.first(where: { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }) else { return }
        AudioObjectSetPropertyData(sys, &address, 0, nil, 4, &mic)
    }
}
