import SwiftUI

struct GameScreen: View {
    @StateObject private var session: GameSession
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var gamepads = GamepadManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var isExiting = false

    init(game: Game) {
        _session = StateObject(wrappedValue: GameSession(game: game))
    }

    private var controlsVisible: Bool {
        guard settings.showTouchControls else { return false }
        if settings.hideControlsWithController && gamepads.isConnected { return false }
        return true
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            EmulatorView(session: session,
                         showControls: controlsVisible && session.phase == .running && !session.isMenuOpen,
                         movementStyle: settings.movementStyle,
                         showSticks: settings.showAnalogSticks,
                         opacity: settings.controlsOpacity,
                         scale: settings.controlsScale,
                         autoHide: settings.autoHideControls,
                         haptics: settings.haptics)
                .ignoresSafeArea()

            // Pulsante menu
            if session.phase == .running && !session.isMenuOpen {
                VStack {
                    Button {
                        session.openMenu()
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 46, height: 30)
                            .background(.white.opacity(0.14), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                    }
                    .padding(.top, 10)
                    Spacer()
                }
            }

            stateOverlay

            if session.isMenuOpen {
                PauseMenuView(session: session, onExit: exit)
                    .transition(.opacity)
            }

            if let toast = session.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if isExiting {
                Color.black.opacity(0.6).ignoresSafeArea()
                ProgressView("Salvataggio…").tint(.white).foregroundStyle(.white)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.isMenuOpen)
        .animation(.easeInOut(duration: 0.2), value: session.toast)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            Orientation.lock(.landscape)
            GamepadManager.shared.emulator = session.emulator
            GamepadManager.shared.onMenuCombo = { [weak s = session] in s?.openMenu() }
        }
        .onDisappear {
            GamepadManager.shared.emulator = nil
            GamepadManager.shared.onMenuCombo = nil
            Orientation.lock(.allButUpsideDown)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                session.appWillBackground()
            }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch session.phase {
        case .waitingForScreen, .loading:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Avvio di \(session.game.title)…").foregroundStyle(.secondary)
            }
        case .jitWarning:
            MessagePanel(
                icon: "bolt.slash",
                title: "JIT non attivo",
                message: "\(session.game.system.name) ha bisogno del JIT per funzionare a velocità decente. Attivalo con StikDebug e riapri il gioco, oppure prova ad avviarlo comunque (potrebbe essere lentissimo o bloccarsi).",
                primary: ("Avvia comunque", { session.acceptJITWarning() }),
                secondary: ("Torna alla libreria", exit)
            )
        case .failed(let msg):
            MessagePanel(
                icon: "exclamationmark.triangle",
                title: "Impossibile avviare il gioco",
                message: msg,
                primary: ("Torna alla libreria", exit),
                secondary: nil
            )
        case .running:
            EmptyView()
        }
    }

    private func exit() {
        guard !isExiting else { return }
        isExiting = true
        session.saveAndExit {
            dismiss()
        }
    }
}

private struct MessagePanel: View {
    let icon: String
    let title: String
    let message: String
    let primary: (String, () -> Void)
    let secondary: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.orange)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                if let secondary = secondary {
                    Button(secondary.0, action: secondary.1).buttonStyle(.bordered)
                }
                Button(primary.0, action: primary.1).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding()
    }
}
