import AppKit

/// "Limit reset" celebration: a short toast under the menu bar and a confetti burst, both click-through.
enum Celebration {
    static let toastDefaultsKey = "toastOnReset"
    static let confettiDefaultsKey = "confettiOnReset"

    static var toastEnabled: Bool {
        get { UserDefaults.standard.object(forKey: toastDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: toastDefaultsKey) }
    }
    static var confettiEnabled: Bool {
        get { UserDefaults.standard.object(forKey: confettiDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: confettiDefaultsKey) }
    }

    private static var windows: [NSWindow] = []

    static func celebrate(_ resets: [WatchedLimit], anchor: NSRect?) {
        guard !resets.isEmpty, toastEnabled || confettiEnabled, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let center = NSPoint(x: anchor?.midX ?? frame.midX, y: frame.maxY - 28)
        if confettiEnabled { show(confetti(on: screen, from: center), lifetime: 4.5) }
        if toastEnabled {
            let text = resets.count == 1 ? "\(resets[0].title) limit reset" : "\(resets.count) limits reset"
            show(toast(text, near: center, in: frame), lifetime: 4)
        }
    }

    private static func show(_ window: NSWindow, lifetime: TimeInterval) {
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        windows.append(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) {
            window.orderOut(nil)
            windows.removeAll { $0 === window }
        }
    }

    private static func overlay(_ frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        return window
    }

    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0.30, green: 0.58, blue: 0.46, alpha: 1), NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.80, blue: 0.47, alpha: 1), NSColor(srgbRed: 0.39, green: 0.58, blue: 0.75, alpha: 1),
        NSColor(srgbRed: 0.63, green: 0.55, blue: 0.78, alpha: 1), NSColor(srgbRed: 0.80, green: 0.46, blue: 0.46, alpha: 1)
    ]

    private static func particle(_ color: NSColor, size: CGFloat) -> CGImage? {
        let image = NSImage(size: NSSize(width: size, height: size * 0.6), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func confetti(on screen: NSScreen, from point: NSPoint) -> NSWindow {
        let window = overlay(screen.frame)
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)
        emitter.emitterShape = .point
        emitter.renderMode = .oldestFirst
        emitter.emitterCells = palette.compactMap { color in
            guard let image = particle(color, size: 12) else { return nil }
            let cell = CAEmitterCell()
            cell.contents = image
            cell.birthRate = 40
            cell.lifetime = 3.6
            cell.velocity = 420
            cell.velocityRange = 160
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 1.3
            cell.yAcceleration = -520
            cell.spin = 4
            cell.spinRange = 8
            cell.scale = 0.9
            cell.scaleRange = 0.5
            cell.alphaSpeed = -0.28
            return cell
        }
        view.layer?.addSublayer(emitter)
        window.contentView = view
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { emitter.birthRate = 0 }
        return window
    }

    private static func toast(_ text: String, near point: NSPoint, in screen: NSRect) -> NSWindow {
        let theme = PanelTheme.current(for: nil)
        let label = NSTextField(labelWithString: "🎉  \(text)")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = theme.primaryText
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 32, height: 36)
        let x = min(max(point.x - size.width / 2, screen.minX + 12), screen.maxX - size.width - 12)
        let window = overlay(NSRect(x: x, y: screen.maxY - 38 - size.height - 6, width: size.width, height: size.height))
        window.hasShadow = true
        let pill = NSView(frame: NSRect(origin: .zero, size: size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = theme.panelTint.cgColor
        pill.layer?.cornerRadius = size.height / 2
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = theme.panelEdge.cgColor
        label.frame.origin = NSPoint(x: 16, y: (size.height - label.frame.height) / 2)
        pill.addSubview(label)
        window.contentView = pill
        return window
    }
}
