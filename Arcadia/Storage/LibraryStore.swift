import Foundation
import UIKit

struct PendingAssignment: Identifiable, Hashable {
    let id: UUID
    let title: String
    let options: [GameSystem]
    var selected: GameSystem
}

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var games: [Game] = []
    @Published var isImporting = false
    @Published var importStatus = ""
    @Published var pendingAssignments: [PendingAssignment] = []
    @Published var alertMessage: String?

    private init() {
        Paths.prepare()
        load()
    }

    // MARK: Persistenza

    private func load() {
        guard let data = try? Data(contentsOf: Paths.library) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        games = (try? decoder.decode([Game].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(games) {
            try? data.write(to: Paths.library, options: .atomic)
        }
    }

    var sortedGames: [Game] {
        games.sorted { a, b in
            switch (a.lastPlayed, b.lastPlayed) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    func game(id: UUID) -> Game? { games.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout Game) -> Void) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        change(&games[i])
        save()
    }

    // MARK: Modifiche

    func markPlayed(_ id: UUID) { update(id) { $0.lastPlayed = Date() } }

    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        update(id) { $0.title = t }
    }

    func setSystem(_ id: UUID, _ system: GameSystem) { update(id) { $0.system = system } }

    func delete(_ id: UUID) {
        guard let game = game(id: id) else { return }
        try? FileManager.default.removeItem(at: game.folderURL)
        StateStore(game: game).deleteAll()
        games.removeAll { $0.id == id }
        save()
    }

    func setCover(_ id: UUID, imageData: Data) {
        guard let game = game(id: id), let image = UIImage(data: imageData) else { return }
        let maxSide: CGFloat = 700
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return }
        try? jpeg.write(to: game.coverURL, options: .atomic)
        update(id) { $0.coverVersion = ($0.coverVersion ?? 0) + 1 }
    }

    func removeCover(_ id: UUID) {
        guard let game = game(id: id) else { return }
        try? FileManager.default.removeItem(at: game.coverURL)
        update(id) { $0.coverVersion = nil }
    }

    func confirmAssignments(_ assignments: [PendingAssignment]) {
        for a in assignments { setSystem(a.id, a.selected) }
        pendingAssignments = []
    }

    // MARK: Importazione

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        importStatus = "Importazione in corso…"
        Task.detached(priority: .userInitiated) {
            let result = Importer.run(urls: urls) { status in
                Task { @MainActor in LibraryStore.shared.importStatus = status }
            }
            await MainActor.run {
                let store = LibraryStore.shared
                store.games.append(contentsOf: result.games)
                store.save()
                store.isImporting = false
                store.pendingAssignments = result.pending
                if !result.errors.isEmpty {
                    store.alertMessage = result.errors.joined(separator: "\n")
                } else if result.games.isEmpty {
                    store.alertMessage = "Nessun gioco riconosciuto nei file selezionati."
                }
            }
        }
    }
}

/// Logica di importazione (eseguita fuori dal main thread).
enum Importer {
    struct Result {
        var games: [Game] = []
        var pending: [PendingAssignment] = []
        var errors: [String] = []
    }

    static func run(urls: [URL], status: @escaping (String) -> Void) -> Result {
        let fm = FileManager.default
        var result = Result()
        let staging = Paths.importTemp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 1. Copia ed estrazione
        for (index, url) in urls.enumerated() {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            status("Importazione \(index + 1) di \(urls.count): \(url.lastPathComponent)")
            if ext == "pkg" {
                result.errors.append("\(url.lastPathComponent): i giochi PS4 (.pkg) non sono supportati.")
                continue
            }
            do {
                if ArchiveExtractor.isArchive(url) {
                    status("Estrazione di \(url.lastPathComponent)…")
                    let dest = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try ArchiveExtractor.extract(url, to: dest)
                } else {
                    let dest = uniqueURL(staging.appendingPathComponent(url.lastPathComponent))
                    try fm.copyItem(at: url, to: dest)
                }
            } catch {
                result.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // 2. Elenco file
        var files: [URL] = []
        if let en = fm.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let u as URL in en {
                if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    files.append(u.standardizedFileURL)
                }
            }
        }
        // Archivi annidati (es. zip dentro 7z): estrai un livello
        for f in files where ArchiveExtractor.isArchive(f) {
            let dest = f.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
            if (try? ArchiveExtractor.extract(f, to: dest)) != nil {
                if let en = fm.enumerator(at: dest, includingPropertiesForKeys: [.isRegularFileKey]) {
                    for case let u as URL in en where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        files.append(u.standardizedFileURL)
                    }
                }
            }
        }
        files.removeAll { ArchiveExtractor.isArchive($0) || $0.lastPathComponent.hasPrefix(".") }

        var byName: [String: URL] = [:]
        for f in files { byName[f.lastPathComponent.lowercased()] = f }

        func resolve(_ ref: String, relativeTo base: URL) -> URL? {
            let cleaned = ref.replacingOccurrences(of: "\\", with: "/")
            let candidate = base.deletingLastPathComponent().appendingPathComponent(cleaned).standardizedFileURL
            if fm.fileExists(atPath: candidate.path) { return candidate }
            return byName[(cleaned as NSString).lastPathComponent.lowercased()]
        }

        func cueRefs(_ cue: URL) -> [URL] {
            guard let text = readText(cue) else { return [] }
            var refs: [URL] = []
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.uppercased().hasPrefix("FILE") else { continue }
                var name: String?
                if let first = t.firstIndex(of: "\""), let last = t.lastIndex(of: "\""), first < last {
                    name = String(t[t.index(after: first)..<last])
                } else {
                    let parts = t.split(separator: " ")
                    if parts.count >= 2 { name = String(parts[1]) }
                }
                if let n = name, let u = resolve(n, relativeTo: cue) { refs.append(u) }
            }
            return refs
        }

        func sidecars(_ primary: URL) -> [URL] {
            let base = primary.deletingPathExtension().lastPathComponent.lowercased()
            return files.filter {
                ["sbi", "sub", "img", "ccd"].contains($0.pathExtension.lowercased()) &&
                $0.deletingPathExtension().lastPathComponent.lowercased() == base && $0 != primary
            }
        }

        var consumed = Set<URL>()
        var groups: [[URL]] = []

        // m3u (multi-disco)
        for m3u in files where m3u.pathExtension.lowercased() == "m3u" {
            var group = [m3u]
            if let text = readText(m3u) {
                for line in text.components(separatedBy: .newlines) {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, !t.hasPrefix("#"), let u = resolve(t, relativeTo: m3u) else { continue }
                    group.append(u)
                    if u.pathExtension.lowercased() == "cue" { group.append(contentsOf: cueRefs(u)) }
                }
            }
            group.forEach { consumed.insert($0) }
            groups.append(group)
        }
        // cue / ccd
        for f in files where !consumed.contains(f) {
            let ext = f.pathExtension.lowercased()
            if ext == "cue" {
                var group = [f] + cueRefs(f)
                group.append(contentsOf: sidecars(f).filter { !group.contains($0) })
                group.forEach { consumed.insert($0) }
                groups.append(group)
            } else if ext == "ccd" {
                let group = [f] + sidecars(f)
                group.forEach { consumed.insert($0) }
                groups.append(group)
            }
        }
        // file singoli
        let playable = GameSystem.allExtensions
        for f in files where !consumed.contains(f) {
            let ext = f.pathExtension.lowercased()
            guard playable.contains(ext), ext != "sub" else { continue }
            consumed.insert(f)
            groups.append([f])
        }

        // 3. Crea i giochi
        for group in groups {
            guard let primary = group.first else { continue }
            let id = UUID()
            let folder = Paths.games.appendingPathComponent(id.uuidString, isDirectory: true)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                var seen = Set<String>()
                for f in group where !seen.contains(f.lastPathComponent) {
                    seen.insert(f.lastPathComponent)
                    let dest = folder.appendingPathComponent(f.lastPathComponent)
                    try? fm.removeItem(at: dest)
                    try fm.moveItem(at: f, to: dest)
                }
            } catch {
                result.errors.append("\(primary.lastPathComponent): \(error.localizedDescription)")
                try? fm.removeItem(at: folder)
                continue
            }

            let ext = primary.pathExtension.lowercased()
            let size = group.reduce(Int64(0)) { sum, f in
                let attrs = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(f.lastPathComponent).path)
                let s = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                return sum + s
            }
            let options = GameSystem.systems(forExtension: ext)
            let guess = guessSystem(ext: ext, size: size, options: options)
            let title = cleanTitle(primary.deletingPathExtension().lastPathComponent)
            let game = Game(id: id, title: title, system: guess, fileName: primary.lastPathComponent,
                            dateAdded: Date(), lastPlayed: nil, coverVersion: nil)
            result.games.append(game)
            if options.count > 1 {
                result.pending.append(PendingAssignment(id: id, title: title, options: options, selected: guess))
            }
        }
        return result
    }

    static func guessSystem(ext: String, size: Int64, options: [GameSystem]) -> GameSystem {
        let gb: Int64 = 1_073_741_824
        switch ext {
        case "cue", "bin", "img", "m3u", "ccd", "mdf", "toc":
            return size > gb ? .ps2 : .ps1
        case "iso":
            return size > Int64(1.9 * Double(gb)) ? .ps2 : .psp
        case "chd":
            return size > 850_000_000 ? .ps2 : .ps1
        case "cso", "pbp", "prx":
            return .psp
        case "elf":
            return .ps2
        default:
            return options.first ?? .ps1
        }
    }

    static func cleanTitle(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? raw : s
    }

    private static func readText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(i)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}
