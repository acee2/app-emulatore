import Foundation

/// Gestisce stati salvati (automatico, backup, slot manuali) e SRAM di un gioco.
enum SaveSlot: Hashable, Identifiable {
    case auto
    case backup
    case manual(Int)

    static let manualSlots = 1...5

    var id: String { fileName }

    var fileName: String {
        switch self {
        case .auto: return "automatico.state"
        case .backup: return "automatico-precedente.state"
        case .manual(let n): return "slot\(n).state"
        }
    }

    var title: String {
        switch self {
        case .auto: return "Salvataggio automatico"
        case .backup: return "Backup (versione precedente)"
        case .manual(let n): return "Slot \(n)"
        }
    }
}

struct StateStore {
    let game: Game

    var directory: URL { Paths.states.appendingPathComponent(game.id.uuidString, isDirectory: true) }
    var saveRAMURL: URL { Paths.saves.appendingPathComponent("\(game.id.uuidString).srm") }

    func url(for slot: SaveSlot) -> URL { directory.appendingPathComponent(slot.fileName) }

    func date(for slot: SaveSlot) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url(for: slot).path)
        return attrs?[.modificationDate] as? Date
    }

    func load(_ slot: SaveSlot) -> Data? { try? Data(contentsOf: url(for: slot)) }

    /// Salva lo stato automatico; il precedente diventa il backup.
    func writeAuto(_ data: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let auto = url(for: .auto)
        let backup = url(for: .backup)
        if fm.fileExists(atPath: auto.path) {
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: auto, to: backup)
        }
        try? data.write(to: auto, options: .atomic)
    }

    func write(_ data: Data, slot: SaveSlot) {
        if case .auto = slot { writeAuto(data); return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: slot), options: .atomic)
    }

    func loadSaveRAM() -> Data? { try? Data(contentsOf: saveRAMURL) }

    func writeSaveRAM(_ data: Data) {
        try? data.write(to: saveRAMURL, options: .atomic)
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: saveRAMURL)
    }
}
