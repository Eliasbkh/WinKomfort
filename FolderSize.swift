// Ordnergrößen für den Explorer (wie Dolphin/WinDirStat): im Hintergrund, mit Zwischenspeicher, abbrechbar.
import Foundation

actor FolderSize {
    static let shared = FolderSize()
    private var cache: [URL: (size: Int64, at: Date)] = [:]

    // Belegter Speicher eines Ordners (wie „Informationen“ im Finder); nil, wenn abgebrochen
    func size(of url: URL) async -> Int64? {
        if let c = cache[url], Date().timeIntervalSince(c.at) < 300 { return c.size }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0, n = 0
        while let f = e.nextObject() as? URL {
            n += 1
            if n % 2000 == 0 {
                if Task.isCancelled { return nil } // Ordner gewechselt → aufhören
                await Task.yield()
            }
            guard let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        cache[url] = (total, Date())
        return total
    }
}
