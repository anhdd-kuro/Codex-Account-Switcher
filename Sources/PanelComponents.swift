import AppKit
import Foundation

// MARK: - Layout primitives

final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

func textWidth(_ text: String, font: NSFont) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: font]).width)
}

func makeLabel(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor,
    alignment: NSTextAlignment = .left,
    monospacedDigits: Bool = false,
    kern: CGFloat? = nil
) -> NSTextField {
    let font: NSFont = monospacedDigits
        ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
        : .systemFont(ofSize: size, weight: weight)
    let field = NSTextField(labelWithString: text)
    field.font = font
    field.textColor = color
    field.alignment = alignment
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.cell?.truncatesLastVisibleLine = true
    if let kern {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: kern,
            .paragraphStyle: paragraph
        ])
    }
    field.sizeToFit()
    return field
}

extension NSView {
    /// Adds a label at a position, optionally constraining its width, and returns its frame.
    @discardableResult
    func place(_ view: NSView, x: CGFloat, y: CGFloat, width: CGFloat? = nil, height: CGFloat? = nil) -> NSRect {
        var frame = view.frame
        frame.origin = NSPoint(x: x, y: y)
        if let width { frame.size.width = max(0, width) }
        if let height { frame.size.height = height }
        view.frame = frame
        addSubview(view)
        return frame
    }
}

// MARK: - Panel surface

/// The panel's Vitesse surface: a blurred backdrop under a tint whose opacity is the Glass opacity setting.
final class GlassPanelBackground: NSView {
    let contentView: FlippedContainerView
    private let tint = NSView()
    private let theme: PanelTheme

    deinit { NotificationCenter.default.removeObserver(self) }

    private func applyOpacity() {
        tint.layer?.backgroundColor = theme.panelTint.withAlphaComponent(PanelTheme.glassOpacity).cgColor
    }

    init(frame: NSRect, theme: PanelTheme, cornerRadius: CGFloat = 16) {
        self.theme = theme
        contentView = FlippedContainerView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.autoresizingMask = [.width, .height]
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true

        let surface = NSView(frame: bounds)
        surface.autoresizingMask = [.width, .height]
        surface.wantsLayer = true
        let blur = NSVisualEffectView(frame: bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        surface.addSubview(blur)
        tint.frame = bounds
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        surface.addSubview(tint)
        applyOpacity()
        NotificationCenter.default.addObserver(forName: PanelTheme.glassOpacityDidChange, object: nil, queue: .main) { [weak self] _ in self?.applyOpacity() }
        surface.layer?.cornerRadius = cornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = theme.panelEdge.cgColor
        surface.layer?.masksToBounds = true
        surface.addSubview(contentView)
        addSubview(surface)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Darkened outer edge plus a bright top highlight, for systems without NSGlassEffectView.
final class PanelEdgeView: NSView {
    private let theme: PanelTheme
    private let cornerRadius: CGFloat

    init(frame: NSRect, theme: PanelTheme, cornerRadius: CGFloat) {
        self.theme = theme
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: cornerRadius, yRadius: cornerRadius)
        outer.lineWidth = 0.5
        theme.panelEdge.setStroke()
        outer.stroke()

        let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: cornerRadius - 0.5, yRadius: cornerRadius - 0.5)
        inner.lineWidth = 0.5
        theme.panelHighlight.withAlphaComponent(theme.isDark ? 0.10 : 0.6).setStroke()
        inner.stroke()
    }
}

// MARK: - Tiles

/// A rounded glass tile. With an action it behaves like a large button (hover, click, VoiceOver press).
final class TileView: NSView {
    private var fillColor: NSColor
    private let hoverFillColor: NSColor?
    private let action: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var pressed = false

    init(
        frame: NSRect,
        fill: NSColor,
        border: NSColor? = nil,
        borderWidth: CGFloat = 0.5,
        cornerRadius: CGFloat = 12,
        hoverFill: NSColor? = nil,
        shadow: NSColor? = nil,
        accessibilityLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.fillColor = fill
        self.hoverFillColor = hoverFill
        self.action = action
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = fill.cgColor
        if let border {
            layer?.borderColor = border.cgColor
            layer?.borderWidth = borderWidth
        }
        if let shadow {
            layer?.shadowColor = shadow.cgColor
            layer?.shadowOpacity = 1
            layer?.shadowRadius = 1.5
            layer?.shadowOffset = NSSize(width: 0, height: -1)
        }
        if action != nil {
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(accessibilityLabel)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard hoverFillColor != nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard let hoverFillColor else { return }
        layer?.backgroundColor = hoverFillColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = fillColor.cgColor
        pressed = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard action != nil, let hit = super.hitTest(point) else { return super.hitTest(point) }
        return hit is NSControl ? hit : self
    }

    private var restingAlpha: CGFloat = 1

    override func mouseDown(with event: NSEvent) {
        guard action != nil else { return super.mouseDown(with: event) }
        pressed = true
        restingAlpha = alphaValue
        alphaValue = restingAlpha * 0.82
    }

    override func mouseUp(with event: NSEvent) {
        guard let action else { return super.mouseUp(with: event) }
        alphaValue = restingAlpha
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if pressed, inside { action() }
        pressed = false
    }

    override func accessibilityPerformPress() -> Bool {
        guard let action else { return false }
        action()
        return true
    }
}

final class HairlineView: NSView {
    init(frame: NSRect, color: NSColor) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Buttons

final class GlassButton: NSButton {
    enum Style {
        case primary
        case secondary
        case icon
        case text(NSColor)
        case popup
        case use
    }

    private let style: Style
    private let theme: PanelTheme
    private let onPress: () -> Void
    private var trackingArea: NSTrackingArea?
    private var hovering = false
    private var pressedDown = false
    private let buttonTitle: String
    private let fontSize: CGFloat

    init(
        title: String = "",
        symbol: String? = nil,
        style: Style,
        theme: PanelTheme,
        height: CGFloat = 28,
        fontSize: CGFloat = 12,
        accessibilityLabel: String? = nil,
        onPress: @escaping () -> Void
    ) {
        self.style = style
        self.theme = theme
        self.onPress = onPress
        self.buttonTitle = title
        self.fontSize = fontSize
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(firePress)
        if let accessibilityLabel { setAccessibilityLabel(accessibilityLabel) }

        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        var width: CGFloat
        switch style {
        case .icon:
            width = height
            imagePosition = .imageOnly
            let config = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .semibold)
            image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: accessibilityLabel)?.withSymbolConfiguration(config) }
        case .popup:
            width = textWidth(title, font: .systemFont(ofSize: fontSize, weight: .medium)) + 28
            imagePosition = .imageTrailing
            let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        case .text:
            width = textWidth(title, font: font) + 14
            if let symbol {
                imagePosition = .imageTrailing
                let config = NSImage.SymbolConfiguration(pointSize: fontSize - 3, weight: .bold)
                image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
                width += 12
            }
        case .primary:
            width = textWidth(title, font: font) + 28
        case .secondary:
            width = textWidth(title, font: .systemFont(ofSize: fontSize, weight: .medium)) + 24
        case .use:
            width = textWidth(title, font: font) + 24
        }
        frame = NSRect(x: 0, y: 0, width: ceil(width), height: height)
        switch style {
        case .icon, .primary, .secondary, .use:
            layer?.cornerRadius = height / 2
        case .popup, .text:
            layer?.cornerRadius = 6
        }
        applyAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEnabled: Bool {
        didSet { applyAppearance() }
    }

    @objc private func firePress() {
        onPress()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyAppearance()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        pressedDown = flag
        applyAppearance()
    }

    private func applyAppearance() {
        let active = isEnabled && hovering
        var fill: NSColor = .clear
        var textColor = theme.primaryText
        var weight: NSFont.Weight = .semibold
        var borderColor: NSColor?

        switch style {
        case .primary:
            fill = active ? theme.accent.blended(withFraction: 0.12, of: .white) ?? theme.accent : theme.accent
            textColor = .white
        case .secondary:
            fill = active ? theme.controlHoverFill : theme.controlFill
            borderColor = theme.controlBorder
            weight = .medium
        case .icon:
            fill = active ? theme.controlHoverFill : theme.controlFill
            borderColor = theme.controlBorder
            textColor = active ? theme.primaryText : theme.secondaryText
        case .text(let color):
            fill = active ? theme.controlFill : .clear
            textColor = color
            weight = .medium
        case .popup:
            fill = active ? theme.controlHoverFill : theme.controlFill
            borderColor = theme.controlBorder
            weight = .medium
        case .use:
            fill = active ? theme.accent : theme.controlFill
            textColor = active ? .white : theme.primaryText
            borderColor = active ? nil : theme.controlBorder
        }
        if pressedDown {
            fill = fill.blended(withFraction: 0.18, of: theme.isDark ? .black : .gray) ?? fill
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = borderColor?.cgColor
        layer?.borderWidth = borderColor == nil ? 0 : 0.5
        alphaValue = isEnabled ? 1 : 0.45
        contentTintColor = textColor

        if !buttonTitle.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            attributedTitle = NSAttributedString(string: buttonTitle, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ])
        } else {
            title = ""
        }
    }
}

final class ToggleSwitch: NSButton {
    private let theme: PanelTheme
    private let onToggle: () -> Void

    init(isOn: Bool, theme: PanelTheme, accessibilityLabel: String, onToggle: @escaping () -> Void) {
        self.theme = theme
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 20))
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.switch)
        wantsLayer = true
        focusRingType = .exterior
        state = isOn ? .on : .off
        setAccessibilityLabel(accessibilityLabel)
        target = self
        action = #selector(toggled)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    @objc private func toggled() {
        needsDisplay = true
        onToggle()
    }

    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let track = bounds
        (on ? theme.accent : theme.switchOff).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()

        let knobSize = track.height - 4
        let knobX = on ? track.maxX - knobSize - 2 : track.minX + 2
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobX, y: track.minY + 2, width: knobSize, height: knobSize)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Segmented tabs

final class SegmentedTabsView: NSView {
    struct Segment {
        let title: String
        let badge: String?
        let isSelected: Bool
        let action: () -> Void
    }

    init(frame: NSRect, theme: PanelTheme, segments: [Segment], fontSize: CGFloat = 12) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.height >= 28 ? 9 : 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = theme.segmentTrack.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = theme.tileBorder.cgColor

        guard !segments.isEmpty else { return }
        let gap: CGFloat = 2
        let segmentRadius: CGFloat = (frame.height >= 28 ? 9 : 8) - 2
        let width = (frame.width - 4 - gap * CGFloat(segments.count - 1)) / CGFloat(segments.count)
        for (index, segment) in segments.enumerated() {
            let rect = NSRect(x: 2 + CGFloat(index) * (width + gap), y: 2, width: width, height: frame.height - 4)
            let tile = TileView(
                frame: rect,
                fill: segment.isSelected ? theme.segmentSelected : .clear,
                border: segment.isSelected ? theme.segmentSelectedBorder : nil,
                cornerRadius: segmentRadius,
                hoverFill: segment.isSelected ? nil : theme.controlFill,
                shadow: segment.isSelected ? NSColor.black.withAlphaComponent(theme.isDark ? 0.30 : 0.12) : nil,
                accessibilityLabel: segment.badge.map { "\(segment.title), \($0)" } ?? segment.title,
                action: segment.isSelected ? nil : segment.action
            )
            if segment.isSelected {
                tile.setAccessibilityElement(true)
                tile.setAccessibilityRole(.button)
                tile.setAccessibilityLabel(segment.title)
                tile.setAccessibilitySelected(true)
            }

            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let titleLabel = makeLabel(segment.title, size: fontSize, weight: .medium, color: segment.isSelected ? theme.primaryText : theme.secondaryText)
            var groupWidth = textWidth(segment.title, font: font)
            var badgeView: CapsuleTagView?
            if let badge = segment.badge {
                let view = CapsuleTagView(text: badge, theme: theme, foreground: theme.blueText, background: theme.tint(.blue), height: 16, fontSize: 10.5, minWidth: 16)
                groupWidth += 6 + view.frame.width
                badgeView = view
            }
            let startX = max(4, (rect.width - groupWidth) / 2)
            tile.place(titleLabel, x: startX, y: (rect.height - titleLabel.frame.height) / 2, width: min(titleLabel.frame.width + 2, rect.width - 8))
            if let badgeView {
                tile.place(badgeView, x: startX + textWidth(segment.title, font: font) + 6, y: (rect.height - badgeView.frame.height) / 2)
            }
            addSubview(tile)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
}

// MARK: - Small visual pieces

final class CapsuleTagView: NSView {
    private let text: String
    private let foreground: NSColor
    private let background: NSColor
    private let dotColor: NSColor?
    private let font: NSFont

    init(text: String, theme: PanelTheme, foreground: NSColor, background: NSColor, dot: NSColor? = nil, height: CGFloat = 18, fontSize: CGFloat = 10.5, weight: NSFont.Weight = .semibold, minWidth: CGFloat = 0, fixedWidth: CGFloat? = nil) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.dotColor = dot
        self.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
        let content = textWidth(text, font: font) + (dot == nil ? 0 : 11)
        let width = fixedWidth ?? max(minWidth, content + 14)
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(width), height: height))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        let size = (text as NSString).size(withAttributes: attributes)
        let content = size.width + (dotColor == nil ? 0 : 11)
        var x = (bounds.width - content) / 2
        if let dotColor {
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: (bounds.height - 6) / 2, width: 6, height: 6)).fill()
            x += 11
        }
        (text as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

final class MonogramView: NSView {
    private let text: String
    private let fill: NSColor
    private let textColor: NSColor
    private let symbol: String?

    init(frame: NSRect, text: String, fill: NSColor, textColor: NSColor, symbol: String? = nil) {
        self.text = text
        self.fill = fill
        self.textColor = textColor
        self.symbol = symbol
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: bounds.height * 0.42, weight: .semibold)
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
            let tinted = image.tinted(with: textColor)
            let size = tinted.size
            tinted.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            return
        }
        let scale: CGFloat
        switch text.count {
        case 0, 1: scale = 0.44
        case 2: scale = 0.38
        case 3: scale = 0.31
        default: scale = 0.26
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: bounds.height * scale, weight: .semibold),
            .foregroundColor: textColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

final class SymbolIconView: NSImageView {
    init(frame: NSRect, symbol: String, color: NSColor, pointSize: CGFloat = 13, weight: NSFont.Weight = .semibold) {
        super.init(frame: frame)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        imageScaling = .scaleProportionallyDown
        contentTintColor = color
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class DotView: NSView {
    private let color: NSColor

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// One usage window on a single line: label, bar, percent left and time to reset.
final class UsageBarRowView: NSView {
    private let label: String
    private let percent: Int?
    private let reset: String
    private let color: NSColor
    private let theme: PanelTheme

    init(frame: NSRect, label: String, percent: Int?, reset: String, color: NSColor, theme: PanelTheme) {
        self.label = label
        self.percent = percent.map { max(0, min(100, $0)) }
        self.reset = reset
        self.color = color
        self.theme = theme
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(label) \(self.percent.map { "\($0)%" } ?? "unknown") left, resets in \(reset)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.secondaryText]
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.primaryText]
        let resetAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.tertiaryText]
        let textY = (bounds.height - font.boundingRectForFont.height) / 2 + 1
        let labelWidth: CGFloat = 26
        let resetWidth: CGFloat = 34
        let valueWidth: CGFloat = 40

        (label as NSString).draw(at: NSPoint(x: 0, y: textY), withAttributes: labelAttributes)
        let resetSize = (reset as NSString).size(withAttributes: resetAttributes)
        (reset as NSString).draw(at: NSPoint(x: bounds.width - resetSize.width, y: textY), withAttributes: resetAttributes)
        let value = percent.map { "\($0)%" } ?? "--"
        let valueSize = (value as NSString).size(withAttributes: valueAttributes)
        (value as NSString).draw(at: NSPoint(x: bounds.width - resetWidth - valueSize.width, y: textY), withAttributes: valueAttributes)

        let barX = labelWidth + 4
        let bar = NSRect(x: barX, y: (bounds.height - 6) / 2, width: bounds.width - barX - resetWidth - valueWidth - 8, height: 6)
        theme.trackFill.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        if let percent, percent > 0 {
            let fill = NSRect(x: bar.minX, y: bar.minY, width: max(6, bar.width * CGFloat(percent) / 100), height: bar.height)
            color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }
    }
}

/// A row of proportional coloured segments separated by small gaps.
final class StackedBarView: NSView {
    private let segments: [(weight: CGFloat, color: NSColor)]

    init(frame: NSRect, segments: [(weight: CGFloat, color: NSColor)]) {
        self.segments = segments.filter { $0.weight > 0 }
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let total = segments.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return }
        let gap: CGFloat = 3
        let usable = bounds.width - gap * CGFloat(max(0, segments.count - 1))
        var x: CGFloat = 0
        let radius = bounds.height / 2
        for segment in segments {
            let width = usable * segment.weight / total
            segment.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: width, height: bounds.height), xRadius: radius, yRadius: radius).fill()
            x += width + gap
        }
    }
}

// MARK: - Menu bar glyphs

enum MenuBarGlyph {
    /// A bundled SVG logo filled with the menu bar's label colour at draw time,
    /// so it stays white on dark menu bars and black on light ones.
    static func logo(_ name: String, size: CGFloat, color: NSColor = .labelColor) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let source = NSImage(contentsOf: url) else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    static let claudeOrange = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)

    struct UsagePart {
        let logo: String
        let text: String
        let isLow: Bool
        var reset: String? = nil
    }

    /// Time until `date` in its largest unit: `45m`, `4h`, `3d`.
    static func relativeReset(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = max(0, date.timeIntervalSinceNow)
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// `[logo] 100% · 4h  |  [logo] 95% · 3d`, shared by the status item and its preview.
    static func usageTitle(_ parts: [UsagePart], fontSize: CGFloat, compact: Bool, textColor: NSColor = .labelColor, lowColor: NSColor, separatorColor: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let title = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: compact ? "  |  " : "   |   ", attributes: [.font: font, .foregroundColor: separatorColor]))
            }
            if let image = logo(part.logo, size: fontSize + 2, color: part.logo == "logo-claude" ? claudeOrange : textColor) {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: compact ? 0 : 1.5]))
            }
            title.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: part.isLow ? lowColor : textColor]))
            if let reset = part.reset {
                title.append(NSAttributedString(string: " · \(reset)", attributes: [.font: font, .foregroundColor: separatorColor]))
            }
        }
        return title
    }

    private static var spinnerCache: [String: NSImage] = [:]

    /// A quarter arc rotated by `frame` steps — the switching / resetting spinner.
    /// The 12 frames are drawn once per colour and size, then reused.
    static func spinner(frame: Int, color: NSColor, diameter: CGFloat = 13, lineWidth: CGFloat = 2.2) -> NSImage {
        let step = frame % 12
        let key = "\(step)|\(diameter)|\(lineWidth)|\(color.description)"
        if let cached = spinnerCache[key] { return cached }
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let radius = (min(rect.width, rect.height) - lineWidth) / 2
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.labelColor.withAlphaComponent(0.22).setStroke()
            track.stroke()
            let start = 90 - CGFloat(step) * 30
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - 100, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = false
        spinnerCache[key] = image
        return image
    }

    static func symbol(_ name: String, color: NSColor?, pointSize: CGFloat = 12) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        guard let color else {
            base.isTemplate = true
            return base
        }
        let tinted = base.tinted(with: color)
        tinted.isTemplate = false
        return tinted
    }
}

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let source = self
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Shared helpers

extension DateFormatter {
    static let diagnosticStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    static let resetCreditISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let resetCreditDisplay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    static let resetCreditShortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    static let directFiveHourUsage: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    static let directWeeklyUsage: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()
}

extension NSAlert {
    /// The account panel sits at status-bar level, above ordinary modal alerts.
    /// `runModal` resets the alert's level, so lower those windows while it runs.
    func runAbovePanel() -> NSApplication.ModalResponse {
        let raised = NSApp.windows.filter { $0.isVisible && $0.level > .modalPanel }
        let levels = raised.map(\.level)
        raised.forEach { $0.level = .normal }
        defer { zip(raised, levels).forEach { $0.level = $1 } }
        NSApp.activate(ignoringOtherApps: true)
        return runModal()
    }
}

/// NSSlider that reports its value through a closure.
final class ClosureSlider: NSSlider {
    private let onChange: (Double) -> Void

    init(frame: NSRect, value: Double, range: ClosedRange<Double>, theme: PanelTheme, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: frame)
        minValue = range.lowerBound
        maxValue = range.upperBound
        doubleValue = value
        controlSize = .small
        trackFillColor = theme.accent
        isContinuous = true
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() { onChange(doubleValue) }
}
