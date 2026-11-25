import SwiftUI
import UniformTypeIdentifiers

struct BIOSView: View {
    private struct BIOSFile: Identifiable {
        let name: String
        let system: String
        let note: String
        var id: String { name }
    }

    private let known: [BIOSFile] = [
        BIOSFile(name: "scph5501.bin", system: "PS1", note: "USA · consigliato"),
        BIOSFile(name: "scph5502.bin", system: "PS1", note: "Europa"),
        BIOSFile(name: "scph5500.bin", system: "PS1", note: "Giappone"),
        BIOSFile(name: "scph1001.bin", system: "PS1", note: "USA (alternativo)"),
        BIOSFile(name: "gba_bios.bin", system: "GBA", note: "Opzionale"),
        BIOSFile(name: "disksys.rom", system: "NES", note: "Solo Famicom Disk System"),
    ]

    @State private var showImporter = false
    @State private var refresh = UUID()
    @State private var message: String?

    var body: some View {
        List {
            Section {
                ForEach(known) { f in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).font(.body.monospaced())
                            Text("\(f.system) · \(f.note)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if exists(f.name) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("La PS1 funziona anche senza BIOS (BIOS emulato), ma con quello originale la compatibilità è migliore. PS2 (Play!) e PSP non richiedono BIOS. Estrai i BIOS dalla tua console.")
            }
            .id(refresh)

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("Importa BIOS…", systemImage: "square.and.arrow.down")
                }
            }

            Section("File presenti") {
                let files = installedFiles()
                if files.isEmpty {
                    Text("Nessun file").foregroundStyle(.secondary)
                } else {
                    ForEach(files, id: \.self) { name in
                        Text(name).font(.footnote.monospaced())
                    }
                    .onDelete { idx in
                        for i in idx { try? FileManager.default.removeItem(at: Paths.system.appendingPathComponent(files[i])) }
                        refresh = UUID()
                    }
                }
            }
            .id(refresh)
        }
        .navigationTitle("BIOS")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item, .data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var count = 0
            for url in urls {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                let dest = Paths.system.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { count += 1 }
            }
            message = "Importati \(count) file."
            refresh = UUID()
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: Paths.system.appendingPathComponent(name).path)
    }

    private func installedFiles() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: Paths.system.path)) ?? []
        return items.filter { !$0.hasPrefix(".") && $0 != "PPSSPP" }.sorted()
    }
}
