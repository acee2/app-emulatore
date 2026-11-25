import Foundation
import ZIPFoundation
import PLzmaSDK

enum ArchiveExtractor {
    static let archiveExtensions: Set<String> = ["zip", "7z"]

    static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased())
    }

    /// Estrae l'archivio nella cartella indicata.
    static func extract(_ archive: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        switch archive.pathExtension.lowercased() {
        case "zip":
            try FileManager.default.unzipItem(at: archive, to: destination)
        case "7z":
            let path = try PLzmaSDK.Path(archive.path)
            let stream = try PLzmaSDK.InStream(path: path)
            let decoder = try PLzmaSDK.Decoder(stream: stream, fileType: .sevenZ, delegate: nil)
            guard try decoder.open() else {
                throw ImportError.message("Impossibile aprire l'archivio 7z.")
            }
            let outDir = try PLzmaSDK.Path(destination.path)
            guard try decoder.extract(to: outDir) else {
                throw ImportError.message("Estrazione 7z non riuscita.")
            }
        default:
            break
        }
    }
}

enum ImportError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}
