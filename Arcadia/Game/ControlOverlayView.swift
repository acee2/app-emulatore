import UIKit

/// Controlli touch disegnati sopra al gioco. Gestisce il multitouch, lo scorrimento
/// tra pulsanti, croce a 8 direzioni, stick analogici e la scomparsa automatica.
final class ControlOverlayView: UIView {

    // MARK: Tipi

    enum Kind {
        case button(ARCButton)
        case dpad
        case stick(index: Int, alsoDpad: Bool)
        case cButtons
    }

    enum Look {
        case face(symbol: String, color: UIColor)
        case shoulder
        case pill
    }

    enum Slot {
        case movement, lowerLeft, lowerRight
        case face(dx: CGFloat, dy: CGFloat, diameter: CGFloat)
        case cluster(dx: CGFloat, dy: CGFloat, size: CGFloat)
        case shoulderLeft(row: Int), shoulderRight(row: Int)
        case topCenter(side: Int)       // -1 = sinistra (Select), 1 = destra (Start)
        case bottomCenter(side: Int)    // L3 / R3
    }

    final class Element {
        let kind: Kind
        let look: Look
        let slot: Slot
        let label: String
        let view: ElementView
        init(kind: Kind, look: Look, slot: Slot, label: String) {
            self.kind = kind; self.look = look; self.slot = slot; self.label = label
            self.view = ElementView(kind: kind, look: look, label: label)
        }
    }

    private struct Tracked {
        let elementIndex: Int
        var buttons: Set<Int>          // pulsanti premuti da questo tocco
        var cDirection: (Float, Float) = (0, 0)
    }

    // MARK: Configurazione

    weak var emulator: ARCEmulator?
    var system: GameSystem = .ps1 { didSet { rebuild() } }
    var movementStyle: MovementStyle = .dpad { didSet { if oldValue != movementStyle { rebuild() } } }
    var showSticks: Bool = true { didSet { if oldValue != showSticks { rebuild() } } }
    var controlsScale: CGFloat = 1 { didSet { setNeedsLayout() } }
    var opacity: CGFloat = 0.6 { didSet { if !isFaded { container.alpha = opacity } } }
    var autoHide: Bool = false { didSet { wake() } }
    var haptics: Bool = true

    private let container = UIView()
    private var elements: [Element] = []
    private var tracked: [UITouch: Tracked] = [:]
    private var pressCounts: [Int: Int] = [:]
    private var hideTimer: Timer?
    private var isFaded = false
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        container.isUserInteractionEnabled = false
        container.alpha = opacity
        addSubview(container)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    // MARK: Costruzione

    private func rebuild() {
        releaseAll()
        elements.forEach { $0.view.removeFromSuperview() }
        elements = makeElements()
        elements.forEach { container.addSubview($0.view) }
        setNeedsLayout()
    }

    private func makeElements() -> [Element] {
        var list: [Element] = []
        let family = system.family
        let analog = system.hasAnalogSticks && showSticks
        let pill = Look.pill
        let shoulder = Look.shoulder

        // Movimento
        if family == .n64 {
            list.append(Element(kind: .stick(index: 0, alsoDpad: false), look: pill, slot: .movement, label: ""))
            list.append(Element(kind: .dpad, look: pill, slot: .lowerLeft, label: ""))
        } else if movementStyle == .stick {
            list.append(Element(kind: .stick(index: 0, alsoDpad: true), look: pill, slot: .movement, label: ""))
        } else {
            list.append(Element(kind: .dpad, look: pill, slot: .movement, label: ""))
            if analog {
                list.append(Element(kind: .stick(index: 0, alsoDpad: false), look: pill, slot: .lowerLeft, label: ""))
            }
        }
        if analog && system.hasRightStick {
            list.append(Element(kind: .stick(index: 1, alsoDpad: false), look: pill, slot: .lowerRight, label: ""))
        }

        // Pulsanti frontali
        let green = UIColor(red: 0.30, green: 0.90, blue: 0.70, alpha: 1)
        let red = UIColor(red: 1.00, green: 0.40, blue: 0.45, alpha: 1)
        let blue = UIColor(red: 0.45, green: 0.65, blue: 1.00, alpha: 1)
        let pink = UIColor(red: 1.00, green: 0.55, blue: 0.85, alpha: 1)
        let white = UIColor.white
        let d: CGFloat = 58, o: CGFloat = 56

        switch family {
        case .playstation, .psp:
            list.append(Element(kind: .button(.x), look: .face(symbol: "△", color: green), slot: .face(dx: 0, dy: -o, diameter: d), label: "△"))
            list.append(Element(kind: .button(.a), look: .face(symbol: "○", color: red), slot: .face(dx: o, dy: 0, diameter: d), label: "○"))
            list.append(Element(kind: .button(.b), look: .face(symbol: "✕", color: blue), slot: .face(dx: 0, dy: o, diameter: d), label: "✕"))
            list.append(Element(kind: .button(.y), look: .face(symbol: "□", color: pink), slot: .face(dx: -o, dy: 0, diameter: d), label: "□"))
        case .snes:
            list.append(Element(kind: .button(.x), look: .face(symbol: "X", color: blue), slot: .face(dx: 0, dy: -o, diameter: d), label: "X"))
            list.append(Element(kind: .button(.a), look: .face(symbol: "A", color: red), slot: .face(dx: o, dy: 0, diameter: d), label: "A"))
            list.append(Element(kind: .button(.b), look: .face(symbol: "B", color: UIColor.systemYellow), slot: .face(dx: 0, dy: o, diameter: d), label: "B"))
            list.append(Element(kind: .button(.y), look: .face(symbol: "Y", color: green), slot: .face(dx: -o, dy: 0, diameter: d), label: "Y"))
        case .nes, .gba:
            list.append(Element(kind: .button(.b), look: .face(symbol: "B", color: white), slot: .face(dx: -40, dy: 24, diameter: 68), label: "B"))
            list.append(Element(kind: .button(.a), look: .face(symbol: "A", color: white), slot: .face(dx: 40, dy: -24, diameter: 68), label: "A"))
        case .genesis:
            list.append(Element(kind: .button(.y), look: .face(symbol: "A", color: white), slot: .face(dx: -64, dy: 22, diameter: d), label: "A"))
            list.append(Element(kind: .button(.b), look: .face(symbol: "B", color: white), slot: .face(dx: 0, dy: 0, diameter: d), label: "B"))
            list.append(Element(kind: .button(.a), look: .face(symbol: "C", color: white), slot: .face(dx: 64, dy: -22, diameter: d), label: "C"))
        case .n64:
            list.append(Element(kind: .button(.b), look: .face(symbol: "A", color: blue), slot: .face(dx: -22, dy: 44, diameter: 64), label: "A"))
            list.append(Element(kind: .button(.y), look: .face(symbol: "B", color: green), slot: .face(dx: -86, dy: 0, diameter: 56), label: "B"))
            list.append(Element(kind: .cButtons, look: .face(symbol: "C", color: UIColor.systemYellow), slot: .cluster(dx: 50, dy: -42, size: 104), label: "C"))
        }

        // Dorsali
        switch family {
        case .playstation:
            list.append(Element(kind: .button(.l), look: shoulder, slot: .shoulderLeft(row: 0), label: "L1"))
            list.append(Element(kind: .button(.l2), look: shoulder, slot: .shoulderLeft(row: 1), label: "L2"))
            list.append(Element(kind: .button(.r), look: shoulder, slot: .shoulderRight(row: 0), label: "R1"))
            list.append(Element(kind: .button(.r2), look: shoulder, slot: .shoulderRight(row: 1), label: "R2"))
        case .psp, .snes, .gba:
            list.append(Element(kind: .button(.l), look: shoulder, slot: .shoulderLeft(row: 0), label: "L"))
            list.append(Element(kind: .button(.r), look: shoulder, slot: .shoulderRight(row: 0), label: "R"))
        case .n64:
            list.append(Element(kind: .button(.l), look: shoulder, slot: .shoulderLeft(row: 0), label: "L"))
            list.append(Element(kind: .button(.l2), look: shoulder, slot: .shoulderLeft(row: 1), label: "Z"))
            list.append(Element(kind: .button(.r), look: shoulder, slot: .shoulderRight(row: 0), label: "R"))
        case .nes, .genesis:
            break
        }

        // Select / Start
        switch family {
        case .n64:
            list.append(Element(kind: .button(.start), look: pill, slot: .topCenter(side: 1), label: "START"))
        case .genesis:
            list.append(Element(kind: .button(.select), look: pill, slot: .topCenter(side: -1), label: "MODE"))
            list.append(Element(kind: .button(.start), look: pill, slot: .topCenter(side: 1), label: "START"))
        default:
            list.append(Element(kind: .button(.select), look: pill, slot: .topCenter(side: -1), label: "SELECT"))
            list.append(Element(kind: .button(.start), look: pill, slot: .topCenter(side: 1), label: "START"))
        }

        if family == .playstation && analog {
            list.append(Element(kind: .button(.l3), look: pill, slot: .bottomCenter(side: -1), label: "L3"))
            list.append(Element(kind: .button(.r3), look: pill, slot: .bottomCenter(side: 1), label: "R3"))
        }
        return list
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        container.frame = bounds
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }
        let u = min(H / 390, 1.25) * controlsScale
        let safe = safeAreaInsets
        let leftX = safe.left + 22 * u
        let rightX = W - safe.right - 22 * u
        let midY = H * 0.52

        let dpadSize = 150 * u
        let movementCenter = CGPoint(x: leftX + dpadSize / 2, y: midY)
        let faceCenter = CGPoint(x: rightX - 88 * u, y: midY)
        let stickSize = 120 * u
        let lowerY = H - safe.bottom - stickSize / 2 - 8 * u
        let lowerLeftCenter = CGPoint(x: movementCenter.x + 150 * u, y: lowerY)
        let lowerRightCenter = CGPoint(x: faceCenter.x - 150 * u, y: lowerY)

        func rect(center: CGPoint, size: CGSize) -> CGRect {
            CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }

        for e in elements {
            var frame: CGRect
            switch e.slot {
            case .movement:
                frame = rect(center: movementCenter, size: CGSize(width: dpadSize, height: dpadSize))
            case .lowerLeft:
                let s: CGFloat = system.family == .n64 ? 110 * u : stickSize
                frame = rect(center: lowerLeftCenter, size: CGSize(width: s, height: s))
            case .lowerRight:
                frame = rect(center: lowerRightCenter, size: CGSize(width: stickSize, height: stickSize))
            case let .face(dx, dy, diameter):
                frame = rect(center: CGPoint(x: faceCenter.x + dx * u, y: faceCenter.y + dy * u),
                             size: CGSize(width: diameter * u, height: diameter * u))
            case let .cluster(dx, dy, size):
                frame = rect(center: CGPoint(x: faceCenter.x + dx * u, y: faceCenter.y + dy * u),
                             size: CGSize(width: size * u, height: size * u))
            case let .shoulderLeft(row):
                frame = CGRect(x: safe.left + 16 * u, y: max(safe.top, 0) + 12 * u + CGFloat(row) * 48 * u, width: 96 * u, height: 38 * u)
            case let .shoulderRight(row):
                frame = CGRect(x: W - safe.right - 16 * u - 96 * u, y: max(safe.top, 0) + 12 * u + CGFloat(row) * 48 * u, width: 96 * u, height: 38 * u)
            case let .topCenter(side):
                let w = 76 * u, h = 30 * u
                let x = side < 0 ? W / 2 - 40 * u - w : W / 2 + 40 * u
                frame = CGRect(x: x, y: max(safe.top, 0) + 12 * u, width: w, height: h)
            case let .bottomCenter(side):
                let w = 52 * u, h = 30 * u
                let x = side < 0 ? W / 2 - 10 * u - w : W / 2 + 10 * u
                frame = CGRect(x: x, y: H - safe.bottom - h - 8 * u, width: w, height: h)
            }
            e.view.frame = frame
            e.view.setNeedsDisplay()
        }
    }

    // MARK: Pressione pulsanti

    private func press(_ id: Int) {
        let c = pressCounts[id, default: 0]
        pressCounts[id] = c + 1
        if c == 0 {
            if let b = ARCButton(rawValue: id) { emulator?.setButton(b, pressed: true, source: .touch) }
            if haptics { feedback.impactOccurred(intensity: 0.6) }
        }
    }

    private func release(_ id: Int) {
        let c = pressCounts[id, default: 0]
        guard c > 0 else { return }
        pressCounts[id] = c - 1
        if c == 1, let b = ARCButton(rawValue: id) {
            emulator?.setButton(b, pressed: false, source: .touch)
        }
    }

    func releaseAll() {
        for (_, t) in tracked { t.buttons.forEach { release($0) } }
        tracked.removeAll()
        pressCounts.removeAll()
        emulator?.clearInput(for: .touch)
        elements.forEach { $0.view.reset() }
    }

    // MARK: Tocchi

    private func elementIndex(at p: CGPoint, buttonsOnly: Bool = false) -> Int? {
        var best: (Int, CGFloat)?
        for (i, e) in elements.enumerated() {
            if buttonsOnly {
                guard case .button = e.kind else { continue }
            }
            let hit = e.view.frame.insetBy(dx: -10, dy: -10)
            guard hit.contains(p) else { continue }
            let c = CGPoint(x: e.view.frame.midX, y: e.view.frame.midY)
            let dist = hypot(p.x - c.x, p.y - c.y)
            if best == nil || dist < best!.1 { best = (i, dist) }
        }
        return best?.0
    }

    private func dpadButtons(for p: CGPoint, in frame: CGRect) -> Set<Int> {
        let dx = p.x - frame.midX, dy = p.y - frame.midY
        let r = frame.width / 2
        guard hypot(dx, dy) > r * 0.18 else { return [] }
        let angle = atan2(dy, dx)
        var sector = Int((angle / (.pi / 4)).rounded())
        if sector < 0 { sector += 8 }
        switch sector % 8 {
        case 0: return [ARCButton.right.rawValue]
        case 1: return [ARCButton.right.rawValue, ARCButton.down.rawValue]
        case 2: return [ARCButton.down.rawValue]
        case 3: return [ARCButton.down.rawValue, ARCButton.left.rawValue]
        case 4: return [ARCButton.left.rawValue]
        case 5: return [ARCButton.left.rawValue, ARCButton.up.rawValue]
        case 6: return [ARCButton.up.rawValue]
        default: return [ARCButton.up.rawValue, ARCButton.right.rawValue]
        }
    }

    private func stickVector(for p: CGPoint, in frame: CGRect) -> CGVector {
        let r = frame.width / 2
        var dx = (p.x - frame.midX) / r
        var dy = (p.y - frame.midY) / r
        let len = hypot(dx, dy)
        if len > 1 { dx /= len; dy /= len }
        return CGVector(dx: dx, dy: dy)
    }

    private func cDirection(for p: CGPoint, in frame: CGRect) -> (Float, Float) {
        let dx = p.x - frame.midX, dy = p.y - frame.midY
        if abs(dx) > abs(dy) { return (dx > 0 ? 1 : -1, 0) }
        return (0, dy > 0 ? 1 : -1)
    }

    private func updateCButtons() {
        var x: Float = 0, y: Float = 0
        for (_, t) in tracked {
            if case .cButtons = elements[t.elementIndex].kind {
                x += t.cDirection.0; y += t.cDirection.1
            }
        }
        emulator?.setAnalogStick(1, x: max(-1, min(1, x)), y: max(-1, min(1, y)), source: .touch)
    }

    private func apply(_ touch: UITouch, began: Bool) {
        let p = touch.location(in: self)
        if began {
            guard let idx = elementIndex(at: p) else { return }
            tracked[touch] = Tracked(elementIndex: idx, buttons: [])
        }
        guard var t = tracked[touch] else { return }
        let e = elements[t.elementIndex]

        switch e.kind {
        case .button(let b):
            if began {
                t.buttons = [b.rawValue]
                press(b.rawValue)
                e.view.pressed = true
            } else if let newIdx = elementIndex(at: p, buttonsOnly: true), newIdx != t.elementIndex,
                      case .button(let nb) = elements[newIdx].kind {
                // scorrimento verso un altro pulsante
                t.buttons.forEach { release($0) }
                e.view.pressed = false
                t = Tracked(elementIndex: newIdx, buttons: [nb.rawValue])
                press(nb.rawValue)
                elements[newIdx].view.pressed = true
            }
        case .dpad:
            let newSet = dpadButtons(for: p, in: e.view.frame)
            for b in t.buttons.subtracting(newSet) { release(b) }
            for b in newSet.subtracting(t.buttons) { press(b) }
            t.buttons = newSet
            e.view.dpadPressed = newSet
        case let .stick(index, alsoDpad):
            let v = stickVector(for: p, in: e.view.frame)
            e.view.knobOffset = v
            if system.hasAnalogSticks {
                emulator?.setAnalogStick(index, x: Float(v.dx), y: Float(v.dy), source: .touch)
            }
            if alsoDpad {
                var newSet = Set<Int>()
                if v.dx > 0.45 { newSet.insert(ARCButton.right.rawValue) }
                if v.dx < -0.45 { newSet.insert(ARCButton.left.rawValue) }
                if v.dy > 0.45 { newSet.insert(ARCButton.down.rawValue) }
                if v.dy < -0.45 { newSet.insert(ARCButton.up.rawValue) }
                for b in t.buttons.subtracting(newSet) { release(b) }
                for b in newSet.subtracting(t.buttons) { press(b) }
                t.buttons = newSet
            }
        case .cButtons:
            t.cDirection = cDirection(for: p, in: e.view.frame)
            e.view.cPressed = t.cDirection
            tracked[touch] = t
            updateCButtons()
            return
        }
        tracked[touch] = t
    }

    private func end(_ touch: UITouch) {
        guard let t = tracked.removeValue(forKey: touch) else { return }
        t.buttons.forEach { release($0) }
        let e = elements[t.elementIndex]
        switch e.kind {
        case .button:
            e.view.pressed = tracked.values.contains { $0.elementIndex == t.elementIndex }
        case .dpad:
            e.view.dpadPressed = []
        case let .stick(index, _):
            e.view.knobOffset = .zero
            if system.hasAnalogSticks { emulator?.setAnalogStick(index, x: 0, y: 0, source: .touch) }
        case .cButtons:
            e.view.cPressed = (0, 0)
            updateCButtons()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        wake()
        touches.forEach { apply($0, began: true) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.forEach { apply($0, began: false) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.forEach { end($0) }
        wake()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.forEach { end($0) }
    }

    // MARK: Scomparsa automatica

    private func wake() {
        hideTimer?.invalidate()
        if isFaded {
            isFaded = false
            UIView.animate(withDuration: 0.15) { self.container.alpha = self.opacity }
        } else {
            container.alpha = opacity
        }
        guard autoHide else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self = self, self.tracked.isEmpty else { return }
            self.isFaded = true
            UIView.animate(withDuration: 0.6) { self.container.alpha = 0 }
        }
    }
}

// MARK: - Disegno di un elemento

final class ElementView: UIView {
    let kind: ControlOverlayView.Kind
    let look: ControlOverlayView.Look
    let label: String

    var pressed = false { didSet { if pressed != oldValue { setNeedsDisplay() } } }
    var dpadPressed: Set<Int> = [] { didSet { if dpadPressed != oldValue { setNeedsDisplay() } } }
    var knobOffset: CGVector = .zero { didSet { setNeedsDisplay() } }
    var cPressed: (Float, Float) = (0, 0) { didSet { setNeedsDisplay() } }

    init(kind: ControlOverlayView.Kind, look: ControlOverlayView.Look, label: String) {
        self.kind = kind; self.look = look; self.label = label
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        pressed = false
        dpadPressed = []
        knobOffset = .zero
        cPressed = (0, 0)
    }

    private let fill = UIColor(white: 1, alpha: 0.16)
    private let fillPressed = UIColor(white: 1, alpha: 0.5)
    private let stroke = UIColor(white: 1, alpha: 0.55)

    override func draw(_ rect: CGRect) {
        let b = bounds.insetBy(dx: 2, dy: 2)
        switch kind {
        case .button:
            switch look {
            case .face(let symbol, let color):
                let path = UIBezierPath(ovalIn: b)
                (pressed ? fillPressed : fill).setFill(); path.fill()
                stroke.setStroke(); path.lineWidth = 1.5; path.stroke()
                drawText(symbol, in: b, size: b.height * 0.45, color: color, weight: .bold)
            case .shoulder, .pill:
                let path = UIBezierPath(roundedRect: b, cornerRadius: b.height / 2)
                (pressed ? fillPressed : fill).setFill(); path.fill()
                stroke.setStroke(); path.lineWidth = 1.5; path.stroke()
                drawText(label, in: b, size: b.height * (look.isPill ? 0.38 : 0.45), color: .white, weight: .semibold)
            }
        case .dpad:
            drawDpad(in: b)
        case .stick:
            let base = UIBezierPath(ovalIn: b)
            fill.setFill(); base.fill()
            stroke.setStroke(); base.lineWidth = 1.5; base.stroke()
            let knobD = b.width * 0.46
            let maxOff = (b.width - knobD) / 2
            let c = CGPoint(x: b.midX + knobOffset.dx * maxOff, y: b.midY + knobOffset.dy * maxOff)
            let knob = UIBezierPath(ovalIn: CGRect(x: c.x - knobD / 2, y: c.y - knobD / 2, width: knobD, height: knobD))
            (knobOffset == .zero ? UIColor(white: 1, alpha: 0.35) : fillPressed).setFill(); knob.fill()
            stroke.setStroke(); knob.stroke()
        case .cButtons:
            let d = b.width * 0.36
            let positions: [(CGFloat, CGFloat, Float, Float, String)] = [
                (0, -1, 0, -1, "▲"), (1, 0, 1, 0, "▶"), (0, 1, 0, 1, "▼"), (-1, 0, -1, 0, "◀")
            ]
            for (px, py, vx, vy, sym) in positions {
                let c = CGPoint(x: b.midX + px * (b.width / 2 - d / 2), y: b.midY + py * (b.height / 2 - d / 2))
                let r = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
                let path = UIBezierPath(ovalIn: r)
                let active = cPressed.0 == vx && cPressed.1 == vy && (vx != 0 || vy != 0)
                (active ? fillPressed : fill).setFill(); path.fill()
                stroke.setStroke(); path.lineWidth = 1.2; path.stroke()
                drawText(sym, in: r, size: d * 0.4, color: .systemYellow, weight: .bold)
            }
        }
    }

    private func drawDpad(in b: CGRect) {
        let t = b.width / 3
        let arms: [(CGRect, Int, String)] = [
            (CGRect(x: b.minX + t, y: b.minY, width: t, height: t + 2), ARCButton.up.rawValue, "▲"),
            (CGRect(x: b.minX + t, y: b.maxY - t - 2, width: t, height: t + 2), ARCButton.down.rawValue, "▼"),
            (CGRect(x: b.minX, y: b.minY + t, width: t + 2, height: t), ARCButton.left.rawValue, "◀"),
            (CGRect(x: b.maxX - t - 2, y: b.minY + t, width: t + 2, height: t), ARCButton.right.rawValue, "▶")
        ]
        let cross = UIBezierPath()
        cross.append(UIBezierPath(roundedRect: CGRect(x: b.minX + t, y: b.minY, width: t, height: b.height), cornerRadius: 8))
        cross.append(UIBezierPath(roundedRect: CGRect(x: b.minX, y: b.minY + t, width: b.width, height: t), cornerRadius: 8))
        fill.setFill(); cross.fill()
        for (r, id, sym) in arms {
            if dpadPressed.contains(id) {
                fillPressed.setFill()
                UIBezierPath(roundedRect: r, cornerRadius: 8).fill()
            }
            drawText(sym, in: r, size: t * 0.35, color: UIColor(white: 1, alpha: 0.8), weight: .bold)
        }
        stroke.setStroke()
        let outline = UIBezierPath()
        let x0 = b.minX, x1 = b.minX + t, x2 = b.minX + 2 * t, x3 = b.maxX
        let y0 = b.minY, y1 = b.minY + t, y2 = b.minY + 2 * t, y3 = b.maxY
        outline.move(to: CGPoint(x: x1, y: y0))
        outline.addLine(to: CGPoint(x: x2, y: y0)); outline.addLine(to: CGPoint(x: x2, y: y1))
        outline.addLine(to: CGPoint(x: x3, y: y1)); outline.addLine(to: CGPoint(x: x3, y: y2))
        outline.addLine(to: CGPoint(x: x2, y: y2)); outline.addLine(to: CGPoint(x: x2, y: y3))
        outline.addLine(to: CGPoint(x: x1, y: y3)); outline.addLine(to: CGPoint(x: x1, y: y2))
        outline.addLine(to: CGPoint(x: x0, y: y2)); outline.addLine(to: CGPoint(x: x0, y: y1))
        outline.addLine(to: CGPoint(x: x1, y: y1)); outline.close()
        outline.lineWidth = 1.5
        outline.stroke()
    }

    private func drawText(_ text: String, in r: CGRect, size: CGFloat, color: UIColor, weight: UIFont.Weight) {
        let font = UIFont.systemFont(ofSize: max(8, size), weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }
}

private extension ControlOverlayView.Look {
    var isPill: Bool { if case .pill = self { return true }; return false }
}
