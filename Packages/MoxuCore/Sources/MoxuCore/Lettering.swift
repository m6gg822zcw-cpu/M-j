import Foundation

/// Coordinates are fractions of the actual image, never of the device or a letterbox.
public struct BubblePoint: Codable, Equatable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    public func clamped() -> Self {
        Self(x: finiteClamp(x, 0...1, fallback: 0.5), y: finiteClamp(y, 0...1, fallback: 0.5))
    }
}
public struct BubbleRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public var center: BubblePoint { BubblePoint(x: x + width / 2, y: y + height / 2) }
    public func clamped() -> Self {
        let w = finiteClamp(width, 0.12...0.98, fallback: 0.42)
        let h = finiteClamp(height, 0.05...0.96, fallback: 0.18)
        return Self(
            x: finiteClamp(x, 0.01...(0.99 - w), fallback: 0.02),
            y: finiteClamp(y, 0.01...(0.99 - h), fallback: 0.02), width: w, height: h)
    }
    public func contains(_ point: BubblePoint) -> Bool {
        point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height
    }
    public func moved(dx: Double, dy: Double) -> Self {
        Self(x: x + dx, y: y + dy, width: width, height: height).clamped()
    }
    public func resized(dw: Double, dh: Double) -> Self {
        let base = clamped()
        return Self(
            x: base.x, y: base.y,
            width: finiteClamp(base.width + dw, 0.12...max(0.12, 0.99 - base.x), fallback: base.width),
            height: finiteClamp(base.height + dh, 0.05...max(0.05, 0.99 - base.y), fallback: base.height)
        ).clamped()
    }
}
public enum BubbleStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case speech, thought, caption
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .speech: return "对白"
        case .thought: return "心声"
        case .caption: return "旁白框"
        }
    }
}
public struct ComicBubble: Codable, Identifiable, Equatable, Sendable {
    public var id: String, sourceKey: String?
    public var text: String, speaker: String
    public var frame: BubbleRect
    public var style: BubbleStyle
    /// Nominal font size as a fraction of image width. Rendering uses a 1000-wide reference canvas.
    public var fontScale: Double
    public var showSpeaker: Bool, tailEnabled: Bool, hidden: Bool
    public var tailTip: BubblePoint
    public init(
        id: String = UUID().uuidString, sourceKey: String? = nil, text: String, speaker: String = "",
        frame: BubbleRect = BubbleRect(x: 0.04, y: 0.05, width: 0.42, height: 0.2),
        style: BubbleStyle = .speech, fontScale: Double = 0.03, showSpeaker: Bool = true,
        tailEnabled: Bool = true, tailTip: BubblePoint = BubblePoint(x: 0.25, y: 0.4), hidden: Bool = false
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.text = text
        self.speaker = speaker
        self.frame = frame
        self.style = style
        self.fontScale = fontScale
        self.showSpeaker = showSpeaker
        self.tailEnabled = tailEnabled
        self.tailTip = tailTip
        self.hidden = hidden
    }
    public var displayedText: String { showSpeaker && !speaker.isEmpty ? speaker + "\n" + text : text }
    public func clamped() -> Self {
        var b = self
        b.frame = frame.clamped()
        b.tailTip = tailTip.clamped()
        b.fontScale = finiteClamp(fontScale, 0.014...0.08, fallback: 0.03)
        return b
    }
}
public struct ComicLettering: Codable, Equatable, Sendable {
    public var version = 1, revision = 0
    public var bubbles: [ComicBubble]
    public init(bubbles: [ComicBubble]) { self.bubbles = bubbles }
    public func validated() throws -> Self {
        guard version == 1, bubbles.count <= 50 else { throw StudioError.invalid("气泡格式不支持，或超过每格50个。") }
        guard Set(bubbles.map(\.id)).count == bubbles.count,
            bubbles.allSatisfy({ !$0.id.isEmpty && $0.text.count <= 2000 && $0.speaker.count <= 100 })
        else {
            throw StudioError.invalid("气泡编号重复，或文字过长。")
        }
        var result = self
        result.bubbles = bubbles.map { $0.clamped() }
        return result
    }
}
public enum BubbleEdge: String, Sendable { case top, right, bottom, left }
public struct BubbleTailAttachment: Equatable, Sendable {
    public let edge: BubbleEdge
    public let point: BubblePoint
}
public enum BubbleGeometry {
    /// Intersection of the center-to-tip ray and the bubble box, in image coordinates.
    public static func attachment(frame: BubbleRect, tip: BubblePoint) -> BubbleTailAttachment? {
        let r = frame.clamped()
        let p = tip.clamped()
        let c = r.center
        guard !r.contains(p) else { return nil }
        let dx = p.x - c.x
        let dy = p.y - c.y
        let tx = dx == 0 ? Double.infinity : r.width / 2 / abs(dx)
        let ty = dy == 0 ? Double.infinity : r.height / 2 / abs(dy)
        let t = min(tx, ty)
        return BubbleTailAttachment(
            edge: tx < ty ? (dx > 0 ? .right : .left) : (dy > 0 ? .bottom : .top),
            point: BubblePoint(x: c.x + dx * t, y: c.y + dy * t))
    }
    public static func hitTest(_ point: BubblePoint, bubbles: [ComicBubble]) -> String? {
        bubbles.reversed().first { !$0.hidden && $0.frame.clamped().contains(point) }?.id
    }
}
public enum LetteringDefaults {
    public static func layout(for panel: ComicPanel, imageAspect: Double) -> ComicLettering {
        if let saved = panel.lettering { return (try? saved.validated()) ?? ComicLettering(bubbles: []) }
        let aspect = finiteClamp(imageAspect, 0.03...32, fallback: 1)
        var bubbles: [ComicBubble] = []
        var startY = 0.035
        if !panel.narration.isEmpty {
            let h = estimatedHeight(panel.narration, width: 0.90, aspect: aspect, font: 0.028, limit: 0.24)
            bubbles.append(
                ComicBubble(
                    id: "narration", sourceKey: "narration", text: panel.narration,
                    frame: BubbleRect(x: 0.05, y: startY, width: 0.90, height: h),
                    style: .caption, fontScale: 0.028, showSpeaker: false, tailEnabled: false))
            startY += h + 0.025
        }
        let remaining = max(0.30, 0.93 - startY)
        var rowY = startY
        var rowHeight = 0.0
        for (i, d) in panel.dialogue.enumerated() {
            if i > 0, i % 2 == 0 {
                rowY += rowHeight + 0.04
                rowHeight = 0
            }
            let h = estimatedHeight(
                d.speaker + "\n" + d.text, width: 0.44, aspect: aspect, font: 0.030,
                limit: min(0.30, remaining / 2 - 0.025))
            let x = i % 2 == 0 ? 0.04 : 0.52
            let y = rowY
            rowHeight = max(rowHeight, h)
            let style: BubbleStyle = d.kind == "thought" ? .thought : d.kind == "offscreen" ? .caption : .speech
            bubbles.append(
                ComicBubble(
                    id: "dialogue:\(i)", sourceKey: "dialogue:\(i)", text: d.text, speaker: d.speaker,
                    frame: BubbleRect(x: x, y: y, width: 0.44, height: h).clamped(), style: style,
                    tailEnabled: style != .caption, tailTip: BubblePoint(x: x + 0.23, y: min(0.97, y + h + 0.08))))
        }
        if let sfx = SoundEffects.displayText(panel.sfx) {
            bubbles.append(
                ComicBubble(
                    id: "sfx", sourceKey: "sfx", text: sfx,
                    frame: BubbleRect(x: 0.65, y: 0.87, width: 0.30, height: 0.09),
                    style: .caption, fontScale: 0.026, showSpeaker: false, tailEnabled: false))
        }
        return ComicLettering(bubbles: bubbles.map { $0.clamped() })
    }
    private static func estimatedHeight(_ text: String, width: Double, aspect: Double, font: Double, limit: Double)
        -> Double
    {
        let units = text.reduce(0.0) { $0 + ($1.isASCII ? 0.6 : 1) }
        let lines = ceil(units / max(1, (width - 0.032) / font)) + 1
        return min(limit, max(0.08, (lines * font * 1.23 + 0.032) * aspect))
    }
}
private func finiteClamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
    min(range.upperBound, max(range.lowerBound, value.isFinite ? value : fallback))
}
