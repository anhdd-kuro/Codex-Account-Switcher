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
        if confettiEnabled { show(fireworks(on: screen, from: center), lifetime: 4.5) }
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

    private static func spark(_ color: NSColor, diameter: CGFloat) -> CGImage? {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// A few soft firework bursts under the status item, staggered over about a second.
    private static func fireworks(on screen: NSScreen, from point: NSPoint) -> NSWindow {
        let window = overlay(screen.frame)
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let bursts: [(dx: CGFloat, drop: CGFloat, delay: TimeInterval)] = [(-150, 170, 0), (130, 230, 0.35), (-20, 130, 0.7), (-260, 260, 1.0), (240, 150, 1.25)]
        for (index, burst) in bursts.enumerated() {
            let color = palette[index % palette.count]
            let center = CGPoint(x: min(max(point.x + burst.dx, screen.frame.minX + 60), screen.frame.maxX - 60) - screen.frame.minX,
                                 y: point.y - burst.drop - screen.frame.minY)
            DispatchQueue.main.asyncAfter(deadline: .now() + burst.delay) {
                let emitter = CAEmitterLayer()
                emitter.emitterPosition = center
                emitter.emitterShape = .point
                emitter.renderMode = .additive
                emitter.emitterCells = [(5, 150, 1.1), (3, 90, 0.9)].compactMap { diameter, velocity, lifetime in
                    guard let image = spark(color, diameter: CGFloat(diameter)) else { return nil }
                    let cell = CAEmitterCell()
                    cell.contents = image
                    cell.birthRate = 120
                    cell.lifetime = Float(lifetime)
                    cell.velocity = CGFloat(velocity)
                    cell.velocityRange = CGFloat(velocity) * 0.35
                    cell.emissionRange = .pi * 2
                    cell.yAcceleration = -110
                    cell.alphaSpeed = -0.85
                    cell.scaleSpeed = -0.25
                    return cell
                }
                view.layer?.addSublayer(emitter)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { emitter.birthRate = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { emitter.removeFromSuperlayer() }
            }
        }
        window.contentView = view
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
