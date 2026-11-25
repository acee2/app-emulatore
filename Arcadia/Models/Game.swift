import Foundation

struct Game: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var system: GameSystem
    /// Nome del file principale da avviare, dentro la cartella del gioco.
    var fileName: String
    var dateAdded: Date
    var lastPlayed: Date?
    /// Cambia quando si aggiorna la copertina (per invalidare la cache).
    var coverVersion: Int?

    var folderURL: URL { Paths.games.appendingPathComponent(id.uuidString, isDirectory: true) }
    var fileURL: URL { folderURL.appendingPathComponent(fileName) }
    var coverURL: URL { folderURL.appendingPathComponent("cover.jpg") }
    var hasCover: Bool { coverVersion != nil && FileManager.default.fileExists(atPath: coverURL.path) }
}

enum Paths {
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let games = documents.appendingPathComponent("Giochi", isDirectory: true)
    static let saves = documents.appendingPathComponent("Salvataggi", isDirectory: true)
    static let states = documents.appendingPathComponent("Stati", isDirectory: true)
    static let system = documents.appendingPathComponent("BIOS", isDirectory: true)
    static let library = documents.appendingPathComponent("libreria.json")
    static let importTemp = FileManager.default.temporaryDirectory.appendingPathComponent("Importazione", isDirectory: true)

    static func prepare() {
        let fm = FileManager.default
        for dir in [games, saves, states, system] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        installBundledSystemFiles()
    }

    /// Copia gli asset inclusi nell'app (es. PPSSPP) nella cartella BIOS senza sovrascrivere.
    private static func installBundledSystemFiles() {
        guard let bundled = Bundle.main.url(forResource: "System", withExtension: nil) else { return }
        let fm = FileManager.default
        let marker = system.appendingPathComponent(".asset-version")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        if let existing = try? String(contentsOf: marker, encoding: .utf8), existing == version { return }
        guard let enumerator = fm.enumerator(at: bundled, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let basePath = bundled.standardizedFileURL.path
        for case let url as URL in enumerator {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(basePath) else { continue }
            let relative = String(full.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            let dest = system.appendingPathComponent(relative)
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            } else if !fm.fileExists(atPath: dest.path) {
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: url, to: dest)
            }
        }
        try? version.write(to: marker, atomically: true, encoding: .utf8)
    }

    static func coreURL(for system: GameSystem) -> URL? {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let url = frameworks
            .appendingPathComponent("\(system.coreFramework).framework", isDirectory: true)
            .appendingPathComponent(system.coreFramework)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
