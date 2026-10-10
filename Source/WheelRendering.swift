import AppKit
import SwiftUI

final class WheelView: NSView {
    var language: AppLanguage = .chinese { didSet { needsDisplay = true } }
    var theme: WheelTheme = .glass { didSet {
        guard theme != oldValue else { return }
        (superview as? WheelSurface)?.refreshMaterial()
        beginPresentation()
        needsDisplay = true
    } }
    private var hoverSince = ProcessInfo.processInfo.systemUptime
    private var previousHovered: Int?
    private var hovered: Int? { didSet {
        if hovered != oldValue { previousHovered = oldValue; hoverSince = ProcessInfo.processInfo.systemUptime; needsDisplay = true }
    } }
    private var presentationSince: Double = -.greatestFiniteMagnitude
    func beginPresentation() { presentationSince = ProcessInfo.processInfo.systemUptime; animationTime = presentationSince }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private func progress(since: Double) -> Double {
        if reduceMotion { return 1 }
        let duration = theme == .glass ? 0.32 : 0.16
        let t = min(1, max(0, (animationTime - since) / duration))
        return 1 - pow(1 - t, 3)
    }
    private var innerRadius: CGFloat { 45 * scale }
    private var ink: NSColor { .labelColor }
    private var secondaryInk: NSColor { .secondaryLabelColor }
    private var contrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    private var glassDecoration: Bool { theme == .glass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    var actions: [KeyAction] = [] { didSet { if actions.map(\.id) != oldValue.map(\.id) { hovered = nil }; needsDisplay = true } }
    var appearances: [SlotAppearance] = [] { didSet { needsDisplay = true } }
    var triggerModes: [TriggerMode] = []
    var animationTime = ProcessInfo.processInfo.systemUptime { didSet { needsDisplay = true } }
    var feedback: WheelFeedback = .idle {
        didSet { if feedback != oldValue { feedbackSince = animationTime; needsDisplay = true } }
    }
    private var feedbackSince = ProcessInfo.processInfo.systemUptime
    private var previousSelected: Int?
    private var selectionSince = ProcessInfo.processInfo.systemUptime
    var selectionAnimating: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return now - max(selectionSince, max(hoverSince, presentationSince)) < 0.6
    }
    var selected: Int? { didSet {
        if selected != oldValue { previousSelected = oldValue; selectionSince = ProcessInfo.processInfo.systemUptime }
        needsDisplay = true
    } }
    var rotation: Double = 0 { didSet { needsDisplay = true } }
    var vector = WheelVector() { didSet { needsDisplay = true } }
    var demonstration = false
    var editing = false
    var onSelect: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onRotate: ((Double) -> Void)?
    var onInsert: ((Int, Int) -> Void)?
    var mouseMove: ((WheelVector) -> Void)?
    var mouseClose: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var dragAngle: Double?
    private var handleHovered = false
    private var dragSource: Int?
    private var dragStart = CGPoint.zero
    private var dragPoint = CGPoint.zero
    private var dragBoundary: Int?
    private var sectorDragging = false
    private var dragActions: [String] = []
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { editing }
    private var scale: CGFloat { min(bounds.width, bounds.height) / 320 }
    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var handlePoint: CGPoint {
        CGPoint(x: center.x + sin(rotation) * 151 * scale, y: center.y + cos(rotation) * 151 * scale)
    }
    private func sector(at point: CGPoint) -> Int? {
        let radius = hypot(point.x - center.x, point.y - center.y)
        guard radius >= 45 * scale, radius <= 140 * scale else { return nil }
        return wheelSector(WheelVector(x: (point.x - center.x) / (140 * scale), y: (point.y - center.y) / (140 * scale)), count: actions.count, rotation: rotation)
    }
    private func appearance(at index: Int) -> SlotAppearance { appearances.indices.contains(index) ? appearances[index] : SlotAppearance() }
    private var activeMode: TriggerMode {
        guard let index = selected, triggerModes.indices.contains(index) else { return .onEntry }
        return triggerModes[index]
    }
    private var stateColor: NSColor { .labelColor }
    private var stateLabel: String {
        switch feedback {
        case .idle: return "移动选择"
        case .selecting: return activeMode == .whileInside ? "即将按下" : activeMode == .onRelease ? "松手执行" : "即将触发"
        case .holding: return "正在按下"
        case .releaseReady: return "松手执行"
        case .fired: return "已触发"
        case .inactive: return "未设置"
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if editing {
            let p = handlePoint
            addCursorRect(NSRect(x: p.x - 16 * scale, y: p.y - 16 * scale, width: 32 * scale, height: 32 * scale), cursor: .openHand)
        }
    }
    override func mouseMoved(with event: NSEvent) {
        if editing {
            let p = convert(event.locationInWindow, from: nil)
            let hover = hypot(p.x - handlePoint.x, p.y - handlePoint.y) <= 17 * scale
            if hover != handleHovered { handleHovered = hover; needsDisplay = true }
            hovered = sector(at: p)
            return
        }
        guard demonstration else { return }
        let p = convert(event.locationInWindow, from: nil)
        mouseMove?(WheelVector(x: (p.x - center.x) / (120 * scale), y: (p.y - center.y) / (120 * scale)))
    }
    override func mouseExited(with event: NSEvent) {
        hovered = nil; handleHovered = false; needsDisplay = true
    }
    private func insertionBoundary(at point: CGPoint) -> Int? {
        let distance = hypot(point.x - center.x, point.y - center.y)
        guard distance >= 45 * scale, distance <= 150 * scale else { return nil }
        return wheelInsertionBoundary(WheelVector(x: (point.x - center.x) / (140 * scale), y: (point.y - center.y) / (140 * scale)), count: actions.count, rotation: rotation)
    }
    override func mouseDown(with event: NSEvent) {
        if editing {
            let p = convert(event.locationInWindow, from: nil)
            if hypot(p.x - handlePoint.x, p.y - handlePoint.y) <= 17 * scale {
                dragAngle = atan2(p.x - center.x, p.y - center.y)
                needsDisplay = true; NSCursor.closedHand.push()
                return
            }
            guard hypot(p.x - center.x, p.y - center.y) <= 140 * scale else { return }
            if actions.isEmpty { onAdd?(); return }
            if let index = sector(at: p) {
                dragSource = index; dragStart = p; dragPoint = p
                dragActions = actions.map(\.id)
                onSelect?(index)
            }
        } else if demonstration { mouseClose?() }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let last = dragAngle else {
            guard dragSource != nil else { return }
            if !sectorDragging, hypot(p.x - dragStart.x, p.y - dragStart.y) >= 6 * scale {
                sectorDragging = true; NSCursor.closedHand.push()
            }
            if sectorDragging { dragPoint = p; dragBoundary = insertionBoundary(at: p); needsDisplay = true }
            return
        }
        guard hypot(p.x - center.x, p.y - center.y) > 45 * scale else { return }
        let next = atan2(p.x - center.x, p.y - center.y)
        // Signed shortest delta makes crossing twelve o'clock continuous.
        let delta = atan2(sin(next - last), cos(next - last))
        rotation = normalizedAngle(rotation + delta); dragAngle = next
        onRotate?(rotation)
    }
    override func mouseUp(with event: NSEvent) {
        if dragAngle != nil { dragAngle = nil; needsDisplay = true; NSCursor.pop(); window?.invalidateCursorRects(for: self) }
        let source = dragSource
        let target = insertionBoundary(at: convert(event.locationInWindow, from: nil))
        let shouldInsert = sectorDragging && dragActions == actions.map(\.id)
        if sectorDragging { NSCursor.pop() }
        dragSource = nil; dragBoundary = nil; sectorDragging = false; dragActions = []
        needsDisplay = true
        if shouldInsert, let source, let target { onInsert?(source, target) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        let c = center
        let outer: CGFloat = 140 * scale, inner = innerRadius
        let step = actions.isEmpty ? 360 : 360 / Double(actions.count)
        let turn = rotation * 180 / .pi
        for i in actions.indices {
            let mid = 90.0 - turn - Double(i) * step
            let angle = mid * .pi / 180
            let ease = progress(since: selectionSince)
            let strength = selected == i ? ease : previousSelected == i ? 1 - ease : 0
            let hoverEase = progress(since: hoverSince)
            let hover = editing ? (hovered == i ? hoverEase : previousHovered == i ? 1 - hoverEase : 0) : 0
            let highlight = max(strength * (hovered != nil && hovered != selected ? 0.4 : 1), hover)
            let selectedAge = max(0, animationTime - (hovered == i ? hoverSince : selectionSince))
            let active = selected == i || hovered == i
            let emphasis = highlight
            let shape = sectorPath(center: c, inner: inner, outer: outer - 1, mid: mid, half: step / 2)
            let lift: CGFloat
            switch theme {
            case .minimal: lift = 0
            case .glass: lift = reduceMotion ? 0 : CGFloat(sin(min(1, selectedAge / 0.32) * .pi)) * 1.4 * scale * emphasis
            }
            NSGraphicsContext.saveGraphicsState()
            let offset = NSAffineTransform(); offset.translateX(by: cos(angle) * lift, yBy: sin(angle) * lift); offset.concat()
            drawSectorMaterial(shape, highlight: emphasis, age: selectedAge, mid: mid)
            if actions.count > 1 {
                let a = (mid + step / 2) * .pi / 180
                let line = NSBezierPath()
                line.move(to: NSPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
                line.line(to: NSPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a)))
                NSColor.labelColor.withAlphaComponent(contrast ? 0.5 : 0.1).setStroke(); line.lineWidth = contrast ? 1 : 0.5; line.stroke()
            }
            let r: CGFloat = 97 * scale
            let x = c.x + r * cos(angle), y = c.y + r * sin(angle)
            let width = max(7 * scale, min(86 * scale, 2 * r * CGFloat(sin(min(.pi / 2, step * .pi / 360))) - 5 * scale))
            let fontSize = max(6, min(21, 150 / Double(max(6, actions.count)))) * scale
            let style = appearance(at: i)
            let name = style.visibleName(for: actions[i], language: language), icon = style.visibleIcon(for: actions[i])
            let color = ink
            if !icon.isEmpty {
                let pop = reduceMotion ? 1 : 1 + (theme == .glass ? 0.08 : 0.025) * emphasis
                drawIcon(icon, at: NSPoint(x: x, y: y + (name.isEmpty || actions.count > 16 ? 0 : 6 * scale)), size: fontSize * pop, color: color, maxWidth: width)
            }
            if !name.isEmpty {
                let size = max(6, min(icon.isEmpty ? 13 : 10, 100 / Double(max(8, actions.count)))) * scale
                let font = NSFont.systemFont(ofSize: size, weight: icon.isEmpty ? .semibold : .regular)
                centered(name, at: NSPoint(x: x, y: y - (icon.isEmpty ? 0 : 16 * scale)), font: font, color: active ? color : secondaryInk, maxWidth: width)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let core = NSBezierPath(ovalIn: NSRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        ink.withAlphaComponent(contrast ? 0.5 : 0.14).setStroke(); core.lineWidth = 0.6 * scale; core.stroke()
        if !editing, selected != nil { drawFeedbackRing(center: c, radius: 41 * scale) }
        let action = selected.flatMap { actions.indices.contains($0) ? actions[$0] : nil }
        if let index = selected, let action {
            let style = appearance(at: index), name = appearance(at: index).visibleName(for: action, language: language)
            if !name.isEmpty {
                centered(name, at: NSPoint(x: c.x, y: c.y + 12 * scale), font: .systemFont(ofSize: 11 * scale, weight: .medium), color: ink, maxWidth: 72 * scale)
            } else {
                drawIcon(style.visibleIcon(for: action), at: NSPoint(x: c.x, y: c.y + 12 * scale), size: 17 * scale, color: ink, maxWidth: 72 * scale)
            }
        } else {
            centered(language.text(actions.isEmpty ? "添加按键" : editing ? "选择键位" : "选择按键"), at: NSPoint(x: c.x, y: c.y + (editing ? 0 : 5 * scale)), font: .systemFont(ofSize: 11 * scale, weight: .medium), color: ink, maxWidth: 78 * scale)
        }
        if editing, action != nil {
            centered(language.text("正在编辑"), at: NSPoint(x: c.x, y: c.y - 12 * scale), font: .systemFont(ofSize: 9 * scale, weight: .medium), color: secondaryInk, maxWidth: 72 * scale)
        }
        if glassDecoration { drawGlassEdge(center: c, radius: outer) }
        else {
            ink.withAlphaComponent(contrast ? 0.65 : 0.16).setStroke()
            let border = NSBezierPath(ovalIn: NSRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
            border.lineWidth = contrast ? 1.5 : 0.8; border.stroke()
        }
        if !editing {
            centered(language.text(stateLabel), at: NSPoint(x: c.x, y: c.y - 12 * scale), font: .systemFont(ofSize: 10 * scale, weight: .medium), color: stateColor, maxWidth: 72 * scale)
        }
        if editing {
            let ring: CGFloat = 151 * scale
            NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
            let path = NSBezierPath(ovalIn: NSRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)); path.lineWidth = 1; path.stroke()
            let point = handlePoint
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(translationByX: point.x, byY: point.y)
            (transform as NSAffineTransform).concat()
            let turn = NSAffineTransform(); turn.rotate(byRadians: CGFloat(-rotation)); turn.concat()
            let grip = NSBezierPath(roundedRect: NSRect(x: -16 * scale, y: -7 * scale, width: 32 * scale, height: 14 * scale), xRadius: 7 * scale, yRadius: 7 * scale)
            NSColor.controlBackgroundColor.setFill(); grip.fill()
            (handleHovered || dragAngle != nil ? NSColor.labelColor : NSColor.separatorColor).setStroke()
            grip.lineWidth = 1.2; grip.stroke()
            NSColor.secondaryLabelColor.setFill()
            for x in [-5.0, 0, 5] { for y in [-2.3, 2.3] {
                NSBezierPath(ovalIn: NSRect(x: (x - 0.9) * scale, y: (y - 0.9) * scale, width: 1.8 * scale, height: 1.8 * scale)).fill()
            } }
            NSGraphicsContext.restoreGraphicsState()
            if sectorDragging, let boundary = dragBoundary {
                let angle = rotation + (Double(boundary) - 0.5) * 2 * .pi / Double(actions.count)
                let start = CGPoint(x: c.x + sin(angle) * 48 * scale, y: c.y + cos(angle) * 48 * scale)
                let end = CGPoint(x: c.x + sin(angle) * 144 * scale, y: c.y + cos(angle) * 144 * scale)
                let marker = NSBezierPath(); marker.move(to: start); marker.line(to: end)
                NSColor.controlAccentColor.setStroke(); marker.lineWidth = 4 * scale; marker.lineCapStyle = .round; marker.stroke()
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: CGRect(x: end.x - 4 * scale, y: end.y - 4 * scale, width: 8 * scale, height: 8 * scale)).fill()
            }
            if sectorDragging, let source = dragSource, actions.indices.contains(source) {
                let point = CGPoint(x: min(bounds.maxX - 64 * scale, max(64 * scale, dragPoint.x)), y: min(bounds.maxY - 18 * scale, max(18 * scale, dragPoint.y + 24 * scale)))
                let badge = NSBezierPath(roundedRect: NSRect(x: point.x - 62 * scale, y: point.y - 13 * scale, width: 124 * scale, height: 26 * scale), xRadius: 8 * scale, yRadius: 8 * scale)
                NSColor.controlBackgroundColor.setFill(); badge.fill()
                NSColor.separatorColor.setStroke(); badge.stroke()
                let style = appearance(at: source), name = appearance(at: source).visibleName(for: actions[source], language: language)
                if !name.isEmpty { centered(name, at: point, font: .systemFont(ofSize: 11 * scale, weight: .medium), color: .labelColor, maxWidth: 112 * scale) }
                else { drawIcon(style.visibleIcon(for: actions[source]), at: point, size: 15 * scale, color: .labelColor, maxWidth: 112 * scale) }
            }
        } else {
            let offset = wheelIndicatorOffset(vector)
            let point = NSPoint(x: c.x + CGFloat(offset.x) * scale, y: c.y + CGFloat(offset.y) * scale)
            let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
            stateColor.setFill(); dot.fill(); NSColor.white.withAlphaComponent(0.9).setStroke(); dot.lineWidth = 0.8; dot.stroke()
        }
    }
    private func drawFeedbackRing(center: CGPoint, radius: CGFloat) {
        let elapsed = max(0, animationTime - feedbackSince)
        let quiet = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard feedback == .holding || feedback == .releaseReady || feedback == .fired else { return }
        let t = quiet ? 0 : elapsed
        // Held: a gently breathing meniscus. Release: two settled concentric
        // edges. Fired: a single expanding ripple; status text remains explicit.
        let count = feedback == .releaseReady ? 2 : 1
        for band in 0..<count {
            let progress = min(1, t / 0.65)
            let base = radius + (feedback == .holding ? CGFloat(sin(t * 2.4)) * 1.5 * scale : feedback == .fired ? CGFloat(progress) * 8 * scale : CGFloat(band) * 4 * scale)
            let path = NSBezierPath()
            for n in 0...120 {
                let a = Double(n) * 2 * .pi / 120
                let wave = quiet || !glassDecoration ? 0 : sin(a * 3 + t * 1.4) * sin(t * 1.8) * (feedback == .holding ? 1.4 : 0.45)
                let r = base + CGFloat(wave) * scale
                let point = NSPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
                if n == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close()
            let opacity = feedback == .fired ? 0.45 * (1 - progress) : band == 0 ? 0.32 : 0.15
            stateColor.withAlphaComponent(opacity).setStroke(); path.lineWidth = 0.7 * scale; path.stroke()
            guard glassDecoration else { continue }
            NSGraphicsContext.saveGraphicsState()
            let shift = NSAffineTransform(); shift.translateX(by: 0, yBy: 0.8 * scale); shift.concat()
            NSColor.white.withAlphaComponent(opacity + 0.12).setStroke(); path.lineWidth = 1.1 * scale; path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    private func sectorPath(center c: CGPoint, inner: CGFloat, outer: CGFloat, mid: Double, half: Double) -> NSBezierPath {
        let path = NSBezierPath()
        func point(_ r: CGFloat, _ degrees: Double) -> NSPoint {
            let a = degrees * .pi / 180
            return NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        let start = mid + half, end = mid - half
        path.move(to: point(inner, start))
        path.appendArc(withCenter: c, radius: outer, startAngle: start, endAngle: end, clockwise: true)
        path.line(to: point(inner, end))
        path.appendArc(withCenter: c, radius: inner, startAngle: end, endAngle: start, clockwise: false)
        path.close(); path.lineJoinStyle = .round; return path
    }
    private func drawSectorMaterial(_ path: NSBezierPath, highlight h: Double, age: Double, mid: Double) {
        if theme == .minimal {
            guard h > 0 else { return }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.12 * h); shadow.shadowBlurRadius = 3 * scale; shadow.shadowOffset = NSSize(width: 0, height: -1 * scale); shadow.set()
            NSColor.controlBackgroundColor.withAlphaComponent(h).setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
            NSColor.labelColor.withAlphaComponent((contrast ? 0.18 : 0.065) * h).setFill(); path.fill()
            NSColor.labelColor.withAlphaComponent(0.2 * h).setStroke(); path.lineWidth = 0.6 * scale; path.stroke()
        } else {
            guard h > 0 else { return }
            let ageProgress = min(1, age / 0.32)
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.32 * h), NSColor.white.withAlphaComponent(0.04 * h), NSColor.black.withAlphaComponent(0.075 * h)])?.draw(in: path, angle: CGFloat(mid - 45 + (reduceMotion ? 0 : (1 - ageProgress) * 24)))
            NSColor.labelColor.withAlphaComponent((contrast ? 0.6 : editing ? 0.3 : 0.16) * h).setStroke(); path.lineWidth = scale; path.stroke()
        }
    }
    private func drawGlassEdge(center: CGPoint, radius: CGFloat) {
        let outer = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let bevel = NSBezierPath(ovalIn: outer)
        bevel.appendOval(in: outer.insetBy(dx: 1.8 * scale, dy: 1.8 * scale))
        bevel.windingRule = .evenOdd
        NSGradient(colors: [.white.withAlphaComponent(0.65), .white.withAlphaComponent(0.12), .black.withAlphaComponent(0.16), .white.withAlphaComponent(0.45)])?.draw(in: bevel, angle: -55)
        NSColor.white.withAlphaComponent(0.65).setStroke()
        let lip = NSBezierPath(ovalIn: outer.insetBy(dx: 0.6 * scale, dy: 0.6 * scale)); lip.lineWidth = 0.8 * scale; lip.stroke()
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        let innerLip = NSBezierPath(ovalIn: outer.insetBy(dx: 2.2 * scale, dy: 2.2 * scale)); innerLip.lineWidth = 0.6 * scale; innerLip.stroke()
    }
    private func drawIcon(_ value: String, at point: NSPoint, size: CGFloat, color: NSColor, maxWidth: CGFloat) {
        guard !value.isEmpty else { return }
        if let symbol = NSImage(systemSymbolName: value, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .medium)) {
            let ratio = min(1, min(maxWidth / symbol.size.width, size * 1.25 / symbol.size.height))
            let dimensions = NSSize(width: symbol.size.width * ratio, height: symbol.size.height * ratio)
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect); color.setFill(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: point.x - dimensions.width / 2, y: point.y - dimensions.height / 2, width: dimensions.width, height: dimensions.height))
        } else { centered(value, at: point, font: .systemFont(ofSize: size, weight: .medium), color: color, maxWidth: maxWidth) }
    }
    private func centered(_ text: String, at p: NSPoint, font: NSFont, color: NSColor, maxWidth: CGFloat = .greatestFiniteMagnitude) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let size = text.size(withAttributes: a)
        let width = min(size.width + 1, maxWidth)
        text.draw(in: NSRect(x: p.x - width / 2, y: p.y - size.height / 2, width: width, height: size.height + 1), withAttributes: a)
    }
}
final class EditorGlassBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 28, yRadius: 28)
        NSGraphicsContext.saveGraphicsState(); plate.addClip()
        NSGradient(starting: NSColor.labelColor.withAlphaComponent(0.055), ending: NSColor.labelColor.withAlphaComponent(0.15))?.draw(in: bounds, angle: -35)
        for n in 0..<3 {
            let offset = CGFloat(n) * bounds.width * 0.43
            let path = NSBezierPath(); path.move(to: NSPoint(x: offset - bounds.width * 0.3, y: 0))
            path.curve(to: NSPoint(x: offset + bounds.width * 0.15, y: bounds.height), controlPoint1: NSPoint(x: offset + bounds.width * 0.65, y: bounds.height * 0.4), controlPoint2: NSPoint(x: offset - bounds.width * 0.4, y: bounds.height * 0.6))
            NSColor.labelColor.withAlphaComponent(0.075).setStroke(); path.lineWidth = 20; path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
final class SolidWheelMaterial: NSView {
    var theme: WheelTheme = .minimal
    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = NSColor.controlBackgroundColor
        color.setFill(); NSBezierPath(ovalIn: bounds).fill()
        if theme == .minimal {
            NSGradient(starting: NSColor.labelColor.withAlphaComponent(0.012), ending: NSColor.labelColor.withAlphaComponent(0.055))?.draw(in: NSBezierPath(ovalIn: bounds), angle: -90)
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
final class WheelSurface: NSView {
    let wheel: WheelView
    private var material: NSView = NSView()
    private var usesWindowBackdrop = false
    private var accessibilityObserver: NSObjectProtocol?
    private var backdrop: EditorGlassBackdrop?
    private var animationTimer: Timer?
    init(wheel: WheelView, frame: NSRect) {
        self.wheel = wheel
        super.init(frame: frame)
        // Wheel content overlays the material as a sibling; the outer editing
        // grip stays outside the circular glass without clipping its refraction.
        if wheel.editing { let background = EditorGlassBackdrop(); backdrop = background; addSubview(background) }
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 11
        layer?.shadowOffset = CGSize(width: 0, height: -5)
        wheel.wantsLayer = true
        addSubview(wheel)
        refreshMaterial()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshMaterial(); self?.wheel.needsDisplay = true
        }
        layout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); animationTimer?.invalidate(); animationTimer = nil
        if window != nil { animationTimer = Controller.commonTimer(interval: 1/60) { [weak self] in
            guard let self, self.wheel.editing, self.window?.isVisible == true, self.wheel.selectionAnimating else { return }
            self.wheel.animationTime = ProcessInfo.processInfo.systemUptime
        } }
    }
    deinit {
        animationTimer?.invalidate()
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
    func refreshMaterial() {
        material.removeFromSuperview()
        let transparent = !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let glassEnabled = wheel.theme == .glass && transparent
        if glassEnabled {
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.style = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .regular : .clear
                glass.tintColor = nil; glass.contentView = NSView(); material = glass
            } else {
                let effect = NSVisualEffectView()
                effect.material = .popover; effect.blendingMode = usesWindowBackdrop ? .withinWindow : .behindWindow; effect.state = .active
                effect.wantsLayer = true; effect.layer?.masksToBounds = true; material = effect
            }
        } else { let solid = SolidWheelMaterial(); solid.theme = wheel.theme; material = solid }
        backdrop?.isHidden = !glassEnabled
        layer?.shadowOpacity = glassEnabled ? 0.20 : 0.12
        layer?.shadowRadius = glassEnabled ? 11 : 8
        addSubview(material, positioned: .below, relativeTo: wheel)
        needsLayout = true
        layout()
    }
    func withinWindow() { usesWindowBackdrop = true; (material as? NSVisualEffectView)?.blendingMode = .withinWindow }
    override func layout() {
        super.layout()
        backdrop?.frame = bounds
        let diameter = min(bounds.width, bounds.height) * 280 / 320
        material.frame = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView { glass.cornerRadius = diameter / 2 }
        else { material.layer?.cornerRadius = diameter / 2 }
        layer?.shadowPath = CGPath(ellipseIn: material.frame.insetBy(dx: 2, dy: 2), transform: nil)
        wheel.frame = bounds
    }
}
