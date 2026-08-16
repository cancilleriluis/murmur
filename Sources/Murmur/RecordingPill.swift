import AppKit

/// Small floating capsule shown while recording / transcribing: a light-blue
/// dot plus a live waveform, so you can see at a glance that the mic is
/// actually hearing you and not just that recording is armed.
///
/// Non-activating, click-through, and visible over full-screen apps.
final class RecordingPill {

    enum State {
        case recording
        case working
        case error(String)
    }

    private var panel: NSPanel?
    private var contentView: WaveView?

    private static let size = NSSize(width: 150, height: 42)

    func show(state: State) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.panel == nil { self.build() }
            self.contentView?.state = state
            self.reposition()
            self.panel?.orderFrontRegardless()
        }
    }

    func update(level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.contentView?.push(level: level)
        }
    }

    func hide(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    // MARK: - Construction

    private func build() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
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

        let view = WaveView(frame: NSRect(origin: .zero, size: Self.size))
        panel.contentView = view

        self.panel = panel
        self.contentView = view
    }

    private func reposition() {
        guard let panel = panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2,
                                     y: frame.minY + 80))
    }
}

// MARK: - Drawing

private final class WaveView: NSView {

    var state: RecordingPill.State = .recording {
        didSet { needsDisplay = true }
    }

    /// Light blue, per request.
    private let tint = NSColor(calibratedRed: 0.38, green: 0.75, blue: 1.00, alpha: 1.0)

    private static let barCount = 22
    /// Rolling history, oldest first — this is what makes it read as a
    /// travelling waveform rather than a single jumping meter.
    private var history = [CGFloat](repeating: 0, count: WaveView.barCount)
    private var incoming: CGFloat = 0
    private var displayed: CGFloat = 0
    private var phase: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Advance the waveform on a fixed clock rather than per audio buffer,
        // so the scroll speed stays even regardless of buffer size.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.phase += 0.16
            // Fast attack, gentle release: snappy on speech, no flicker.
            let k: CGFloat = self.incoming > self.displayed ? 0.55 : 0.25
            self.displayed += (self.incoming - self.displayed) * k
            self.history.removeFirst()
            self.history.append(self.displayed)
            self.incoming *= 0.6          // decay if no new audio arrives
            self.needsDisplay = true
        }
        if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    deinit { timer?.invalidate() }

    func push(level: Float) {
        incoming = max(incoming, max(0, min(1, CGFloat(level))))
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)

        // Capsule.
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor(calibratedWhite: 0.08, alpha: 0.93).setFill()
        path.fill()
        tint.withAlphaComponent(0.30).setStroke()
        path.lineWidth = 1
        path.stroke()

        switch state {
        case .recording:
            let dotX = r.minX + 17
            drawDot(at: NSPoint(x: dotX, y: r.midY), pulse: true)
            drawWaveform(in: NSRect(x: dotX + 13, y: r.minY,
                                    width: r.maxX - dotX - 24, height: r.height))
        case .working:
            drawSpinner(at: NSPoint(x: r.minX + 18, y: r.midY))
            drawLabel("Transcribiendo…", from: r.minX + 34, in: r)
        case .error(let msg):
            drawDot(at: NSPoint(x: r.minX + 17, y: r.midY), pulse: false, color: .systemOrange)
            drawLabel(msg, from: r.minX + 32, in: r)
        }
    }

    // MARK: pieces

    private func drawDot(at c: NSPoint, pulse: Bool, color: NSColor? = nil) {
        let base = color ?? tint
        let level = history.last ?? 0
        // Halo breathes with the voice so the dot itself signals input too.
        if pulse {
            let halo = 7 + level * 7
            base.withAlphaComponent(0.22).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - halo, y: c.y - halo,
                                        width: halo * 2, height: halo * 2)).fill()
        }
        let radius: CGFloat = 4.5
        base.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    }

    /// Symmetric bars around the centre line, oldest on the left.
    private func drawWaveform(in rect: NSRect) {
        let n = history.count
        guard n > 0, rect.width > 0 else { return }
        let gap: CGFloat = 2.0
        let barWidth = max(1.5, (rect.width - gap * CGFloat(n - 1)) / CGFloat(n))
        let maxH = rect.height - 14
        let midY = rect.midY

        for (i, raw) in history.enumerated() {
            // Slight taper at the leading edge makes the scroll feel smooth.
            let edge = min(1.0, CGFloat(i) / 3.0)
            let level = raw * edge
            let h = max(2.5, maxH * level)
            let x = rect.minX + CGFloat(i) * (barWidth + gap)
            let bar = NSRect(x: x, y: midY - h / 2, width: barWidth, height: h)
            // Louder bars read brighter, so clipping is visible at a glance.
            let alpha = 0.45 + min(0.55, level * 0.9)
            tint.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    private func drawSpinner(at c: NSPoint) {
        let path = NSBezierPath()
        let start = phase * 57.3
        path.appendArc(withCenter: c, radius: 7, startAngle: start, endAngle: start + 100)
        tint.setStroke()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawLabel(_ text: String, from x: CGFloat, in r: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.93, alpha: 1.0),
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        s.draw(at: NSPoint(x: x, y: r.midY - s.size().height / 2))
    }
}
