import Foundation
import Combine

enum MovementStyle: String, CaseIterable, Identifiable {
    case dpad, stick
    var id: String { rawValue }
    var title: String { self == .dpad ? "Croce direzionale" : "Stick analogico" }
}

/// Impostazioni globali, salvate in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var showTouchControls: Bool { didSet { d.set(showTouchControls, forKey: "showTouchControls") } }
    @Published var hideControlsWithController: Bool { didSet { d.set(hideControlsWithController, forKey: "hideControlsWithController") } }
    @Published var movementStyle: MovementStyle { didSet { d.set(movementStyle.rawValue, forKey: "movementStyle") } }
    @Published var showAnalogSticks: Bool { didSet { d.set(showAnalogSticks, forKey: "showAnalogSticks") } }
    @Published var autoHideControls: Bool { didSet { d.set(autoHideControls, forKey: "autoHideControls") } }
    @Published var controlsOpacity: Double { didSet { d.set(controlsOpacity, forKey: "controlsOpacity") } }
    @Published var controlsScale: Double { didSet { d.set(controlsScale, forKey: "controlsScale") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    @Published var gameSpeed: Double { didSet { d.set(gameSpeed, forKey: "gameSpeed") } }
    @Published var resumeFromAutoSave: Bool { didSet { d.set(resumeFromAutoSave, forKey: "resumeFromAutoSave") } }
    @Published var smoothFiltering: Bool { didSet { d.set(smoothFiltering, forKey: "smoothFiltering") } }

    private init() {
        d.register(defaults: [
            "showTouchControls": true,
            "hideControlsWithController": true,
            "movementStyle": MovementStyle.dpad.rawValue,
            "showAnalogSticks": true,
            "autoHideControls": false,
            "controlsOpacity": 0.6,
            "controlsScale": 1.0,
            "haptics": true,
            "gameSpeed": 1.0,
            "resumeFromAutoSave": true,
            "smoothFiltering": false
        ])
        showTouchControls = d.bool(forKey: "showTouchControls")
        hideControlsWithController = d.bool(forKey: "hideControlsWithController")
        movementStyle = MovementStyle(rawValue: d.string(forKey: "movementStyle") ?? "") ?? .dpad
        showAnalogSticks = d.bool(forKey: "showAnalogSticks")
        autoHideControls = d.bool(forKey: "autoHideControls")
        controlsOpacity = d.double(forKey: "controlsOpacity")
        controlsScale = d.double(forKey: "controlsScale")
        haptics = d.bool(forKey: "haptics")
        gameSpeed = d.double(forKey: "gameSpeed")
        resumeFromAutoSave = d.bool(forKey: "resumeFromAutoSave")
        smoothFiltering = d.bool(forKey: "smoothFiltering")
    }

    static let speedOptions: [Double] = [1, 2, 3, 4]
}
