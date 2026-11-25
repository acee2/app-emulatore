import Foundation
import GameController

/// Collega i controller fisici (DualShock, DualSense, Xbox, MFi) all'emulatore.
final class GamepadManager: ObservableObject {
    static let shared = GamepadManager()

    @Published private(set) var isConnected = false
    @Published private(set) var controllerName: String?

    /// Emulatore che riceve l'input.
    weak var emulator: ARCEmulator?
    /// Chiamato quando si premono insieme L3 + R3 (apre il menu).
    var onMenuCombo: (() -> Void)?

    private init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        refresh()
    }

    func refresh() {
        let controllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        isConnected = !controllers.isEmpty
        controllerName = controllers.first?.vendorName
        for c in controllers { bind(c) }
        if controllers.isEmpty { emulator?.clearInput(for: .controller) }
    }

    private func bind(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        pad.valueChangedHandler = { [weak self] pad, _ in
            self?.handle(pad)
        }
    }

    private func handle(_ pad: GCExtendedGamepad) {
        guard let emu = emulator else { return }
        func set(_ b: ARCButton, _ pressed: Bool) { emu.setButton(b, pressed: pressed, source: .controller) }
        // Posizioni: sotto = B (Croce), destra = A (Cerchio), sinistra = Y (Quadrato), sopra = X (Triangolo)
        set(.b, pad.buttonA.isPressed)
        set(.a, pad.buttonB.isPressed)
        set(.y, pad.buttonX.isPressed)
        set(.x, pad.buttonY.isPressed)
        set(.l, pad.leftShoulder.isPressed)
        set(.r, pad.rightShoulder.isPressed)
        set(.l2, pad.leftTrigger.isPressed)
        set(.r2, pad.rightTrigger.isPressed)
        let l3 = pad.leftThumbstickButton?.isPressed ?? false
        let r3 = pad.rightThumbstickButton?.isPressed ?? false
        set(.l3, l3)
        set(.r3, r3)
        set(.start, pad.buttonMenu.isPressed)
        set(.select, pad.buttonOptions?.isPressed ?? false)
        set(.up, pad.dpad.up.isPressed)
        set(.down, pad.dpad.down.isPressed)
        set(.left, pad.dpad.left.isPressed)
        set(.right, pad.dpad.right.isPressed)
        emu.setAnalogStick(0, x: pad.leftThumbstick.xAxis.value, y: -pad.leftThumbstick.yAxis.value, source: .controller)
        emu.setAnalogStick(1, x: pad.rightThumbstick.xAxis.value, y: -pad.rightThumbstick.yAxis.value, source: .controller)
        if l3 && r3 { onMenuCombo?() }
    }
}
