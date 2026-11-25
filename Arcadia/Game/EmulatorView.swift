import SwiftUI
import UIKit
import OpenGLES

/// Vista OpenGL ES su cui il core disegna.
final class GLView: UIView {
    override class var layerClass: AnyClass { CAEAGLLayer.self }
    var eaglLayer: CAEAGLLayer { layer as! CAEAGLLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        contentScaleFactor = UIScreen.main.nativeScale
        eaglLayer.isOpaque = true
        eaglLayer.drawableProperties = [
            kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        ]
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class EmulatorContainerView: UIView {
    let glView = GLView()
    let overlay = ControlOverlayView()
    var onScreenReady: ((CAEAGLLayer) -> Void)?
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        addSubview(glView)
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        glView.frame = bounds
        overlay.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        if lastSize == .zero {
            lastSize = bounds.size
            onScreenReady?(glView.eaglLayer)
        } else if lastSize != bounds.size {
            lastSize = bounds.size
            onResize?()
        }
    }
}

struct EmulatorView: UIViewRepresentable {
    let session: GameSession
    let showControls: Bool
    let movementStyle: MovementStyle
    let showSticks: Bool
    let opacity: Double
    let scale: Double
    let autoHide: Bool
    let haptics: Bool

    func makeUIView(context: Context) -> EmulatorContainerView {
        let view = EmulatorContainerView()
        view.overlay.emulator = session.emulator
        view.overlay.system = session.game.system
        view.onScreenReady = { [weak s = session] layer in
            DispatchQueue.main.async { s?.screenReady(layer) }
        }
        view.onResize = { [weak s = session] in s?.layerResized() }
        apply(to: view)
        return view
    }

    func updateUIView(_ view: EmulatorContainerView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: EmulatorContainerView) {
        let o = view.overlay
        o.movementStyle = movementStyle
        o.showSticks = showSticks
        o.opacity = CGFloat(opacity)
        o.controlsScale = CGFloat(scale)
        o.haptics = haptics
        if o.autoHide != autoHide { o.autoHide = autoHide }
        if o.isHidden == showControls {
            o.isHidden = !showControls
            if !showControls { o.releaseAll() }
        }
    }
}
