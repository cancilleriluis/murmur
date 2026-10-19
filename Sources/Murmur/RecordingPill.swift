import AppKit

/// Small floating capsule shown while dictating: a row of white bars on black
/// that move with your voice, in the same quiet visual language as the
/// system's own dictation indicator. No text unless something went wrong.
///
/// Non-activating, click-through, and visible over full-screen apps.
final class RecordingPill {

    enum State {
        case recording
        /// Hands-free: recording continues after the key is released.
        case recordingLocked
        case working
        case error(String)
    }

    private var panel: NSPanel?
    private var contentView: WaveView?
    /// Bumped on every show, so a delayed hide (an error fading out) can't
    /// close the pill of a dictation that started since.
    private var generation = 0

    private static let compactSize = NSSize(width: 122, height: 38)

    func show(state: State) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.panel == nil { self.build() }
            guard let panel = self.panel, let view = self.contentView else { return }
            self.generation += 1

            let size = Self.size(for: state)
            panel.setContentSize(size)
            view.frame = NSRect(origin: .zero, size: size)
            view.state = state
            view.startAnimating()
            self.reposition(size)

            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func update(level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.contentView?.push(level: level)
        }
    }

    func hide(after delay: TimeInterval = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let gen = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.generation == gen, let panel = self.panel, panel.isVisible else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    guard self.generation == gen else { return }
                    panel.orderOut(nil)
                    self.contentView?.stopAnimating()
                })
            }
        }
    }

    // MARK: - Construction

    private static func size(for state: State) -> NSSize {
        guard case .error(let msg) = state else { return compactSize }
        let width = WaveView.labelWidth(msg) + 46
        return NSSize(width: min(340, max(compactSize.width, width)), height: compactSize.height)
    }

    private func build() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let view = WaveView(frame: NSRect(origin: .zero, size: Self.compactSize))
        panel.contentView = view

        self.panel = panel
        self.contentView = view
    }

    private func reposition(_ size: NSSize) {
        guard let panel = panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.minY + 80))
    }
}

// MARK: - Shape

/// The bar silhouette shared by the pill and the menu-bar icon: dots at the
/// edges, two tall peaks just off centre.
enum WaveShape {
    static let envelope: [CGFloat] = [
        0.17, 0.20, 0.27, 0.33, 0.50, 1.00, 0.43,
        0.43, 1.00, 0.50, 0.30, 0.27, 0.23, 0.17,
    ]

    /// Template image for the menu bar. Recording inverts it into a filled
    /// capsule so a live mic is obvious at a glance; disabled dims it.
    static func menuBarImage(recording: Bool, enabled: Bool) -> NSImage {
        let size = NSSize(width: 26, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            // Same silhouette, thinned to nine bars so it stays crisp at 18 pt.
            let bars: [CGFloat] = [0.2, 0.32, 0.6, 1.0, 0.45, 1.0, 0.55, 0.32, 0.2]
            let barW: CGFloat = 1.7
            let gap: CGFloat = 1.0
            let total = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap
            let maxH: CGFloat = recording ? 9 : 13
            var x = rect.midX - total / 2

            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let color = NSColor.black.withAlphaComponent(enabled ? 1 : 0.35)
            if recording {
                color.setFill()
                let pill = rect.insetBy(dx: 0, dy: 2)
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                // Punch the bars out of the capsule.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            }
            color.setFill()
            for e in bars {
                let h = max(barW, maxH * e)
                let bar = NSRect(x: x, y: rect.midY - h / 2, width: barW, height: h)
                NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
                x += barW + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "VoZ"
        return image
    }
}

// MARK: - Drawing

private final class WaveView: NSView {

    var state: RecordingPill.State = .recording {
        didSet { needsDisplay = true }
    }

    private static let barWidth: CGFloat = 3.2
    private static let gap: CGFloat = 3.8
    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    private var incoming: CGFloat = 0
    private var displayed: CGFloat = 0
    private var phase: CGFloat = 0
    private var timer: Timer?

    static func labelWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: labelFont]).width
    }

    func startAnimating() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The pill is hidden most of the time; don't redraw it 60×/s for nobody.
    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        incoming = 0
        displayed = 0
    }

    deinit { timer?.invalidate() }

    func push(level: Float) {
        // Room tone sits around 0.2 on this scale; start the bars above it so
        // silence reads as a row of dots and speech uses the full height.
        let speech = (CGFloat(level) - 0.18) / 0.5
        incoming = max(incoming, max(0, min(1, speech)))
    }

    private func tick() {
        phase += 1.0 / 60.0
        // Fast attack, gentle release: snappy on speech, no flicker.
        let k: CGFloat = incoming > displayed ? 0.45 : 0.12
        displayed += (incoming - displayed) * k
        incoming *= 0.85              // decay if no new audio arrives
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)

        let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor(calibratedWhite: 0, alpha: 0.88).setFill()
        capsule.fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        switch state {
        case .recording, .recordingLocked:
            if case .recordingLocked = state {
                // A small steady dot on the left: the mic stays on by itself.
                let dot = NSRect(x: r.minX + 5, y: r.midY - 2.5, width: 5, height: 5)
                NSColor(calibratedWhite: 1, alpha: 0.9).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            drawBars(in: r, alpha: 0.95) { i in
                // Each bar wobbles at its own rate so the row looks like a
                // voice, not a single meter copied fourteen times.
                let wobble = 0.78 + 0.22 * sin(self.phase * (5 + CGFloat(i % 5) * 1.3) + CGFloat(i) * 1.7)
                return WaveShape.envelope[i] * min(1, self.displayed * 1.3) * wobble
            }
        case .working:
            // A soft wave travelling across the bars: busy, but calm.
            drawBars(in: r, alpha: 0.7) { i in
                let wave = 0.5 + 0.5 * sin(self.phase * 7 - CGFloat(i) * 0.55)
                return 0.08 + 0.32 * wave * wave
            }
        case .error(let msg):
            let dot = NSRect(x: r.minX + 13, y: r.midY - 3.5, width: 7, height: 7)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: dot).fill()
            let s = NSAttributedString(string: msg, attributes: [
                .font: WaveView.labelFont,
                .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 1.0),
            ])
            s.draw(at: NSPoint(x: dot.maxX + 8, y: r.midY - s.size().height / 2))
        }
    }

    /// Centred row of rounded bars; `level(i)` is 0…1 of the available height.
    /// At 0 a bar collapses to a dot, matching the edges of the icon.
    private func drawBars(in r: NSRect, alpha: CGFloat, level: (Int) -> CGFloat) {
        let n = WaveShape.envelope.count
        let w = WaveView.barWidth
        let total = CGFloat(n) * w + CGFloat(n - 1) * WaveView.gap
        let maxH = r.height - 10
        var x = r.midX - total / 2

        NSColor(calibratedWhite: 1, alpha: alpha).setFill()
        for i in 0..<n {
            let h = max(w, maxH * max(0, min(1, level(i))))
            let bar = NSRect(x: x, y: r.midY - h / 2, width: w, height: h)
            NSBezierPath(roundedRect: bar, xRadius: w / 2, yRadius: w / 2).fill()
            x += w + WaveView.gap
        }
    }
}
