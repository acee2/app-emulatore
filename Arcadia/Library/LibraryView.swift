import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var store = LibraryStore.shared
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var filter: GameSystem?
    @State private var playing: Game?

    @State private var coverTarget: Game?
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?

    @State private var renameTarget: Game?
    @State private var renameText = ""
    @State private var deleteTarget: Game?

    private var visibleGames: [Game] {
        let all = store.sortedGames
        guard let f = filter else { return all }
        return all.filter { $0.system == f }
    }

    private var systemsInLibrary: [GameSystem] {
        GameSystem.allCases.filter { s in store.games.contains { $0.system == s } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.games.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        if systemsInLibrary.count > 1 { filterBar }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)], spacing: 18) {
                            ForEach(visibleGames) { game in
                                GameCard(game: game)
                                    .onTapGesture { playing = game }
                                    .contextMenu { contextMenu(for: game) }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 30)
                    }
                }
            }
            .navigationTitle("Libreria")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Impostazioni")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Importa gioco")
                        .disabled(store.isImporting)
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.importFiles(urls) }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: Binding(
            get: { !store.pendingAssignments.isEmpty && !store.isImporting },
            set: { if !$0 { store.pendingAssignments = [] } }
        )) {
            AssignmentSheet(assignments: store.pendingAssignments)
        }
        .fullScreenCover(item: $playing) { game in
            GameScreen(game: game)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item = item, let target = coverTarget else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    store.setCover(target.id, imageData: data)
                }
                photoItem = nil
                coverTarget = nil
            }
        }
        .alert("Rinomina", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Titolo", text: $renameText)
            Button("Annulla", role: .cancel) {}
            Button("Salva") {
                if let g = renameTarget { store.rename(g.id, to: renameText) }
            }
        }
        .confirmationDialog("Eliminare il gioco?",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Elimina gioco e salvataggi", role: .destructive) {
                if let g = deleteTarget { store.delete(g.id) }
            }
        } message: {
            Text("Verranno eliminati il file del gioco, la copertina e tutti i salvataggi.")
        }
        .alert("Attenzione", isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
        .overlay {
            if store.isImporting {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(store.importStatus).font(.footnote).multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: 300)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nessun gioco", systemImage: "gamecontroller")
        } description: {
            Text("Tocca + in alto a destra per importare i giochi dall'app File.\nFormati: ISO, CHD, CSO, BIN/CUE, PBP, M3U, ZIP, 7z e ROM.")
        } actions: {
            Button("Importa giochi") { showImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "Tutti", selected: filter == nil) { filter = nil }
                ForEach(systemsInLibrary) { s in
                    FilterChip(title: s.shortName, selected: filter == s) { filter = s }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func contextMenu(for game: Game) -> some View {
        Button { playing = game } label: { Label("Gioca", systemImage: "play.fill") }
        Button {
            coverTarget = game
            showPhotoPicker = true
        } label: { Label("Scegli copertina", systemImage: "photo") }
        if game.hasCover {
            Button { store.removeCover(game.id) } label: { Label("Rimuovi copertina", systemImage: "photo.badge.minus") }
        }
        Button {
            renameText = game.title
            renameTarget = game
        } label: { Label("Rinomina", systemImage: "pencil") }
        let options = GameSystem.systems(forExtension: (game.fileName as NSString).pathExtension)
        if options.count > 1 {
            Menu {
                ForEach(options) { s in
                    Button {
                        store.setSystem(game.id, s)
                    } label: {
                        if s == game.system { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                    }
                }
            } label: { Label("Console", systemImage: "gamecontroller") }
        }
        Divider()
        Button(role: .destructive) { deleteTarget = game } label: { Label("Elimina", systemImage: "trash") }
    }
}

private struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? Color.accentColor : Color.white.opacity(0.1), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct GameCard: View {
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    Text(game.system.shortName)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            Text(game.title)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
            if let last = game.lastPlayed {
                Text(last.formatted(.relative(presentation: .named)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        if game.hasCover, let image = UIImage(contentsOfFile: game.coverURL.path) {
            Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill())
                .id(game.coverVersion)
        } else {
            ZStack {
                LinearGradient(colors: [game.system.accent, game.system.accent.opacity(0.35), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 8) {
                    Image(systemName: game.system.symbol)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(game.title)
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 8)
                }
            }
        }
    }
}
