// CPU- und Speicher-Anzeige in der Menüleiste (wie Stats/iStat) – ein Messpunkt alle 3 s, nur wenn eingeschaltet.
// Klick öffnet den Task-Manager.
import AppKit
import Darwin

@MainActor final class SystemMonitor: NSObject {
    static let shared = SystemMonitor()
    private var item: NSStatusItem?
    private var timer: Timer?
    private var last: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "sysMonitor") }

    func update() { SystemMonitor.enabled ? start() : stop() }

    private func start() {
        guard item == nil else { return }
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        i.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        i.button?.target = self
        i.button?.action = #selector(click)
        i.button?.setAccessibilityLabel(L("Systemauslastung", "System load"))
        item = i
        tick()
        let t = Timer(timeInterval: 3, repeats: true) { _ in MainActor.assumeIsolated { SystemMonitor.shared.tick() } }
        t.tolerance = 1 // Energiesparen: macOS darf den Takt bündeln
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func stop() {
        timer?.invalidate(); timer = nil
        if let i = item { NSStatusBar.system.removeStatusItem(i) }
        item = nil; last = nil
    }
    @objc private func click() { openTaskManager() }

    private func tick() {
        let cpu = cpuPercent(), mem = memPercent()
        item?.button?.title = "CPU \(cpu.map { "\($0)" } ?? "–") %  RAM \(mem) %"
        item?.button?.toolTip = L("CPU- und Speicherauslastung – klicken für den Task-Manager", "CPU and memory load – click for Task Manager")
    }

    // CPU: Anteil der nicht-leerlauf Ticks seit der letzten Messung
    private func cpuPercent() -> Int? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        guard r == KERN_SUCCESS else { return nil }
        let now = (UInt32(info.cpu_ticks.0), UInt32(info.cpu_ticks.1), UInt32(info.cpu_ticks.2), UInt32(info.cpu_ticks.3)) // user, system, idle, nice
        defer { last = (now.0, now.1, now.2, now.3) }
        guard let l = last else { return nil }
        // &- : die Zähler laufen nach Wochen über – ohne Absturz weiterrechnen
        let busy = Double(now.0 &- l.user) + Double(now.1 &- l.sys) + Double(now.3 &- l.nice), idle = Double(now.2 &- l.idle)
        return busy + idle > 0 ? Int((busy / (busy + idle) * 100).rounded()) : 0
    }

    // Speicher wie in der Aktivitätsanzeige: belegt = aktiv + nicht auslagerbar + komprimiert
    private func memPercent() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        guard r == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return Int((Double(used) / Double(ProcessInfo.processInfo.physicalMemory) * 100).rounded())
    }
}
