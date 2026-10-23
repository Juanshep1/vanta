import AppKit

/// Editor gutter: [breakpoint / diagnostic glyph margin][line numbers][fold chevrons].
/// Only visible lines are drawn, so cost doesn't grow with file length.
final class GutterView: NSRulerView {
    weak var pane: EditorPane?
    private var hoverLine: Int?
    private var mouseInside = false

    static let glyphMargin: CGFloat = 18
    static let foldMargin: CGFloat = 16

    init(pane: EditorPane, scrollView: NSScrollView) {
        self.pane = pane
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = pane.textView
        updateThickness()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // Draw only our own content (the default ruler draws a border that can bleed outside).
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        drawHashMarksAndLabels(in: dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    var numberFont: NSFont {
        let size = max(9, CGFloat(StudioSettings.shared.prefs.fontSize) - 1.5)
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    func updateThickness() {
        guard let pane else { return }
        let showNumbers = StudioSettings.shared.prefs.showLineNumbers
        let digits = max(3, String(pane.document.lines.count).count)
        let w = showNumbers ? ("8" as NSString).size(withAttributes: [.font: numberFont]).width * CGFloat(digits) + 8 : 0
        let t = ceil(Self.glyphMargin + w + Self.foldMargin)
        if abs(ruleThickness - t) > 0.5 { ruleThickness = t }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: drawing

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let pane else { return }
        Theme.ngutter.setFill()
        bounds.fill()
        let tv = pane.textView
        let doc = pane.document
        let ns = doc.storage.string as NSString
        let current = doc.lines.line(at: tv.selectedRange().location)
        let showNumbers = StudioSettings.shared.prefs.showLineNumbers
        let numW = ruleThickness - Self.glyphMargin - Self.foldMargin
        let nf = numberFont
        let normal: [NSAttributedString.Key: Any] = [.font: nf, .foregroundColor: Theme.nlineNumber]
        let active: [NSAttributedString.Key: Any] = [.font: nf, .foregroundColor: Theme.nlineNumberActive]
        let bps = pane.breakpoints
        let diagByLine = pane.diagnosticSeverityByLine
        let foldable = pane.foldableStarts
        let folded = pane.foldedStartLines
        let changeMarks = LineMarkerStore.shared.markers(for: doc.uri)     // git change bars (Run module)

        pane.forEachVisibleLine { line, fragRect, baseline in
            let y = self.convert(NSPoint(x: 0, y: fragRect.minY), from: tv).y
            let h = fragRect.height
            let baseY = self.convert(NSPoint(x: 0, y: baseline), from: tv).y
            // debugger current line
            if pane.debugLine == line {
                Theme.ndebugLine.setFill()
                NSRect(x: 0, y: y, width: self.bounds.width, height: h).fill()
            }
            // line number
            if showNumbers {
                let label = "\(line + 1)" as NSString
                let attrs = line == current ? active : normal
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: Self.glyphMargin + numW - size.width - 4, y: baseY - nf.ascender), withAttributes: attrs)
            }
            // glyph margin: breakpoint dot, else diagnostic icon
            let cy = y + h / 2
            if bps.contains(line) {
                Theme.nRose.setFill()
                NSBezierPath(ovalIn: NSRect(x: 5, y: cy - 5, width: 10, height: 10)).fill()
            } else if self.mouseInside && self.hoverLine == line && self.hoverInGlyphMargin {
                Theme.nRose.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: NSRect(x: 5, y: cy - 5, width: 10, height: 10)).fill()
            } else if let sev = diagByLine[line] {
                self.drawDiagnosticGlyph(sev, center: NSPoint(x: 10, y: cy))
            }
            if pane.debugLine == line {
                Theme.nAmber.setFill()
                let p = NSBezierPath()
                p.move(to: NSPoint(x: 3, y: cy - 5)); p.line(to: NSPoint(x: 13, y: cy)); p.line(to: NSPoint(x: 3, y: cy + 5)); p.close()
                p.fill()
            }
            // git change bar between the line numbers and the fold chevrons
            if let mark = changeMarks[line] {
                let bx = self.ruleThickness - Self.foldMargin - 1
                switch mark {
                case .added: Theme.nMint.setFill(); NSRect(x: bx, y: y, width: 3, height: h).fill()
                case .modified: Theme.nBlue.setFill(); NSRect(x: bx, y: y, width: 3, height: h).fill()
                case .deletedAbove:
                    Theme.nRose.setFill()
                    let t = NSBezierPath()
                    t.move(to: NSPoint(x: bx, y: y - 4)); t.line(to: NSPoint(x: bx + 5, y: y)); t.line(to: NSPoint(x: bx, y: y + 4)); t.close()
                    t.fill()
                }
            }
            // fold chevrons
            let fx = self.ruleThickness - Self.foldMargin + 3
            if folded.contains(line) {
                self.drawChevron(NSPoint(x: fx + 5, y: cy), expanded: false, alpha: 1)
            } else if foldable.contains(line) && self.mouseInside {
                self.drawChevron(NSPoint(x: fx + 5, y: cy), expanded: true, alpha: self.hoverLine == line ? 1 : 0.55)
            }
            _ = ns
        }
        // separator
        Theme.nLine.withAlphaComponent(0.0).setFill()
    }

    private func drawChevron(_ c: NSPoint, expanded: Bool, alpha: CGFloat) {
        let p = NSBezierPath()
        p.lineWidth = 1.4
        p.lineCapStyle = .round; p.lineJoinStyle = .round
        if expanded {
            p.move(to: NSPoint(x: c.x - 3.5, y: c.y - 1.8)); p.line(to: NSPoint(x: c.x, y: c.y + 1.8)); p.line(to: NSPoint(x: c.x + 3.5, y: c.y - 1.8))
        } else {
            p.move(to: NSPoint(x: c.x - 1.8, y: c.y - 3.5)); p.line(to: NSPoint(x: c.x + 1.8, y: c.y)); p.line(to: NSPoint(x: c.x - 1.8, y: c.y + 3.5))
        }
        Theme.nMuted.withAlphaComponent(alpha).setStroke()
        p.stroke()
    }

    private func drawDiagnosticGlyph(_ s: DiagnosticSeverity, center c: NSPoint) {
        let color = DiagnosticIcon.nsColor(s)
        switch s {
        case .error:
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)).fill()
            let x = NSBezierPath(); x.lineWidth = 1.5
            x.move(to: NSPoint(x: c.x - 2, y: c.y - 2)); x.line(to: NSPoint(x: c.x + 2, y: c.y + 2))
            x.move(to: NSPoint(x: c.x + 2, y: c.y - 2)); x.line(to: NSPoint(x: c.x - 2, y: c.y + 2))
            Theme.nbg.setStroke(); x.stroke()
        case .warning:
            color.setFill()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x, y: c.y - 5.5)); p.line(to: NSPoint(x: c.x + 5.5, y: c.y + 4.5)); p.line(to: NSPoint(x: c.x - 5.5, y: c.y + 4.5)); p.close()
            p.fill()
        default:
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)).fill()
        }
    }

    // MARK: mouse

    private var hoverInGlyphMargin = false

    private func line(at point: NSPoint) -> Int? {
        guard let pane else { return nil }
        let p = convert(point, to: pane.textView)
        return pane.line(atY: p.y)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouseInside = true
        hoverLine = line(at: p)
        hoverInGlyphMargin = p.x < Self.glyphMargin
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { mouseInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { mouseInside = false; hoverLine = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard let pane else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let l = line(at: p) else { return }
        if p.x < Self.glyphMargin {
            pane.toggleBreakpoint(l)
        } else if p.x >= ruleThickness - Self.foldMargin {
            pane.toggleFold(atLine: l)
        } else {
            pane.selectLines(l...l)
        }
        needsDisplay = true
    }
}
