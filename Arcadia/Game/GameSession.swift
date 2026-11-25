import Foundation
import QuartzCore

@MainActor
final class GameSession: ObservableObject {
    enum Phase: Equatable {
        case waitingForScreen
        case jitWarning
        case loading
        case running
        case failed(String)
    }

    let game: Game
    let stateStore: StateStore
    let emulator: ARCEmulator?

    @Published var phase: Phase = .waitingForScreen
    @Published var isMenuOpen = false
    @Published var toast: String?
    @Published var speed: Double

    private var layer: CAEAGLLayer?
    private var jitWarningAccepted = false
    private var isStopping = false
    private var toastTask: Task<Void, Never>?
    private var pendingExit: (() -> Void)?

    init(game: Game) {
        self.game = game
        self.stateStore = StateStore(game: game)
        let settings = AppSettings.shared
        self.speed = settings.gameSpeed

        if let core = Paths.coreURL(for: game.system) {
            let saveDir = Paths.saves.appendingPathComponent(game.system.rawValue, isDirectory: true)
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            let emu = ARCEmulator(corePath: core.path, systemDirectory: Paths.system.path, saveDirectory: saveDir.path)
            emu.optionOverrides = game.system.optionOverrides(jit: ARCEmulator.isJITAvailable())
            emu.portDevice = game.system.portDevice
            emu.smoothFiltering = settings.smoothFiltering
            emu.speed = settings.gameSpeed
            self.emulator = emu
        } else {
            self.emulator = nil
            self.phase = .failed("Il core \(game.system.coreDisplayName) per \(game.system.name) non è incluso in questa build dell'app.")
        }

        emulator?.messageHandler = { [weak self] msg in
            self?.showToast(msg)
        }
        emulator?.shutdownHandler = { [weak self] in
            self?.isMenuOpen = true
        }
    }

    var jitAvailable: Bool { ARCEmulator.isJITAvailable() }

    // MARK: Avvio

    func screenReady(_ layer: CAEAGLLayer) {
        self.layer = layer
        guard phase == .waitingForScreen else { return }
        if game.system.requiresJIT && !jitAvailable && !jitWarningAccepted {
            phase = .jitWarning
            return
        }
        start()
    }

    func acceptJITWarning() {
        jitWarningAccepted = true
        phase = .waitingForScreen
        if let layer = layer { screenReady(layer) }
    }

    private func start() {
        guard let emu = emulator, let layer = layer else { return }
        phase = .loading
        emu.layer = layer
        let state = AppSettings.shared.resumeFromAutoSave ? stateStore.load(.auto) : nil
        let sram = stateStore.loadSaveRAM()
        emu.start(withGamePath: game.fileURL.path, initialState: state, saveRAM: sram) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.phase = .failed(error.localizedDescription)
            } else {
                self.phase = .running
                LibraryStore.shared.markPlayed(self.game.id)
                if state != nil { self.showToast("Ripreso da dove avevi lasciato") }
            }
            if let exit = self.pendingExit {
                self.pendingExit = nil
                self.saveAndExit(exit)
            }
        }
    }

    func layerResized() { emulator?.layerDidResize() }

    // MARK: Menu

    func openMenu() {
        guard phase == .running, !isMenuOpen else { return }
        isMenuOpen = true
        emulator?.pause()
    }

    func closeMenu() {
        isMenuOpen = false
        if phase == .running { emulator?.resume() }
    }

    func setSpeed(_ value: Double) {
        speed = value
        emulator?.speed = value
        AppSettings.shared.gameSpeed = value
    }

    func reset() {
        emulator?.resetGame()
        closeMenu()
    }

    // MARK: Salvataggi

    func save(to slot: SaveSlot) {
        guard let emu = emulator, phase == .running else { return }
        emu.captureState { [weak self] state, sram in
            guard let self = self else { return }
            if let sram = sram { self.stateStore.writeSaveRAM(sram) }
            if let state = state {
                self.stateStore.write(state, slot: slot)
                self.showToast("Salvato in \(slot.title)")
            } else {
                self.showToast("Questo core non supporta gli stati salvati")
            }
            self.objectWillChange.send()
        }
    }

    func load(_ slot: SaveSlot) {
        guard let emu = emulator, let data = stateStore.load(slot) else {
            showToast("Nessun salvataggio in \(slot.title)")
            return
        }
        emu.loadState(data) { [weak self] ok in
            self?.showToast(ok ? "Caricato: \(slot.title)" : "Impossibile caricare lo stato")
            if ok { self?.closeMenu() }
        }
    }

    /// Salvataggio automatico quando l'app va in background (sovrascrive, il precedente diventa backup).
    func appWillBackground() {
        guard let emu = emulator, phase == .running, !isStopping else { return }
        emu.captureState { [weak self] state, sram in
            guard let self = self else { return }
            if let sram = sram { self.stateStore.writeSaveRAM(sram) }
            if let state = state { self.stateStore.writeAuto(state) }
        }
        if !isMenuOpen {
            isMenuOpen = true
            emu.pause()
        }
    }

    /// Salva automaticamente ed esce.
    func saveAndExit(_ done: @escaping () -> Void) {
        if phase == .loading {
            // Aspetta la fine del caricamento, poi esci.
            pendingExit = done
            return
        }
        guard !isStopping else { return }
        isStopping = true
        guard let emu = emulator, emu.isRunning else { done(); return }
        emu.stop { [weak self] state, sram in
            if let self = self {
                if let sram = sram { self.stateStore.writeSaveRAM(sram) }
                if let state = state { self.stateStore.writeAuto(state) }
            }
            done()
        }
    }

    // MARK: Toast

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}
