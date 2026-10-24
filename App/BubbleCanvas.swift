import MoxuCore
import SwiftUI
import UIKit

private final class BubbleTypeset: NSObject {
    let text: NSAttributedString
    let height: CGFloat
    let fits: Bool
    init(text: NSAttributedString, height: CGFloat, fits: Bool) {
        self.text = text
        self.height = height
        self.fits = fits
    }
}

/// The reader, editor and all exports share this one vector lettering painter.
enum BubblePainter {
    private static let cache: NSCache<NSString, BubbleTypeset> = {
        let value = NSCache<NSString, BubbleTypeset>()
        value.countLimit = 256
        return value
    }()
    static func bodyRect(_ bubble: ComicBubble, canvas: CGSize) -> CGRect {
        let r = bubble.frame.clamped()
        return CGRect(
            x: CGFloat(r.x) * canvas.width, y: CGFloat(r.y) * canvas.height,
            width: CGFloat(r.width) * canvas.width, height: CGFloat(r.height) * canvas.height)
    }
    private static func textRect(_ bubble: ComicBubble, body: CGRect) -> CGRect {
        if bubble.style == .thought { return body.insetBy(dx: body.width * 0.15, dy: body.height * 0.15) }
        return body.insetBy(dx: min(20, body.width * 0.09), dy: min(16, body.height * 0.12))
    }
    private static func typeset(_ bubble: ComicBubble, in rect: CGRect) -> BubbleTypeset {
        let key =
            "\(bubble.displayedText)|\(bubble.style.rawValue)|\(bubble.fontScale)|\(rect.width)|\(rect.height)|\(bubble.showSpeaker)"
            as NSString
        if let value = cache.object(forKey: key) { return value }
        let requested = CGFloat(bubble.fontScale) * 1000
        var fontSize = requested
        var result = NSAttributedString(string: "")
        var height: CGFloat = 0
        var fits = false
        for _ in 0..<14 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = bubble.style == .caption ? .left : .center
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = fontSize * 0.08
            let text = NSMutableAttributedString(
                string: bubble.displayedText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: UIColor.black,
                    .paragraphStyle: paragraph,
                ])
            if bubble.showSpeaker, !bubble.speaker.isEmpty {
                text.addAttribute(
                    .font, value: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                    range: NSRange(location: 0, length: (bubble.speaker as NSString).length))
            }
            let measured = text.boundingRect(
                with: CGSize(width: max(1, rect.width), height: 100000),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            result = text
            height = ceil(measured.height)
            fits = height <= rect.height + 0.5 && measured.width <= rect.width + 1
            if fits || fontSize <= 14 { break }
            fontSize = max(14, fontSize * 0.90)
        }
        let value = BubbleTypeset(text: result, height: height, fits: fits)
        cache.setObject(value, forKey: key)
        return value
    }
    static func overflowing(_ layer: ComicLettering, aspect: Double) -> [String] {
        let canvas = CGSize(width: 1000, height: 1000 / CGFloat(max(0.03, aspect)))
        return layer.bubbles.filter { !$0.hidden }.compactMap { bubble in
            let b = bubble.clamped()
            return typeset(b, in: textRect(b, body: bodyRect(b, canvas: canvas))).fits ? nil : b.id
        }
    }
    static func draw(_ layer: ComicLettering, in imageRect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), imageRect.width > 0, imageRect.height > 0 else { return }
        let canvas = CGSize(width: 1000, height: 1000 * imageRect.height / imageRect.width)
        context.saveGState()
        context.translateBy(x: imageRect.minX, y: imageRect.minY)
        let scale = imageRect.width / 1000
        context.scaleBy(x: scale, y: scale)
        context.clip(to: CGRect(origin: .zero, size: canvas))
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for raw in layer.bubbles where !raw.hidden {
            let bubble = raw.clamped()
            let body = bodyRect(bubble, canvas: canvas)
            let path =
                bubble.style == .thought ? UIBezierPath(ovalIn: body) : speechPath(bubble, body: body, canvas: canvas)
            UIColor.white.setFill()
            path.fill()
            UIColor.black.setStroke()
            path.lineWidth = 2.5
            path.stroke()
            if bubble.style == .thought, bubble.tailEnabled,
                let attachment = BubbleGeometry.attachment(frame: bubble.frame, tip: bubble.tailTip)
            {
                let start = CGPoint(
                    x: CGFloat(attachment.point.x) * canvas.width, y: CGFloat(attachment.point.y) * canvas.height)
                let tip = CGPoint(
                    x: CGFloat(bubble.tailTip.x) * canvas.width, y: CGFloat(bubble.tailTip.y) * canvas.height)
                for (i, t) in [0.30, 0.64, 0.95].enumerated() {
                    let radius = CGFloat(9 - i * 3)
                    let center = CGPoint(
                        x: start.x + (tip.x - start.x) * CGFloat(t), y: start.y + (tip.y - start.y) * CGFloat(t))
                    let dot = UIBezierPath(
                        ovalIn: CGRect(
                            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    UIColor.white.setFill()
                    dot.fill()
                    UIColor.black.setStroke()
                    dot.lineWidth = 2
                    dot.stroke()
                }
            }
            let rect = textRect(bubble, body: body)
            let text = typeset(bubble, in: rect)
            let y = bubble.style == .caption ? rect.minY : rect.midY - min(rect.height, text.height) / 2
            context.saveGState()
            context.clip(to: rect)
            text.text.draw(
                with: CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            context.restoreGState()
        }
        context.restoreGState()
    }
    private static func speechPath(_ bubble: ComicBubble, body: CGRect, canvas: CGSize) -> UIBezierPath {
        let path = UIBezierPath()
        let radius = min(bubble.style == .caption ? 5 : 28, min(body.width, body.height) * 0.18)
        let tail =
            bubble.style == .speech && bubble.tailEnabled
            ? BubbleGeometry.attachment(frame: bubble.frame, tip: bubble.tailTip) : nil
        let tip = CGPoint(x: CGFloat(bubble.tailTip.x) * canvas.width, y: CGFloat(bubble.tailTip.y) * canvas.height)
        func edge(_ kind: BubbleEdge, from: CGPoint, to: CGPoint) {
            if let tail, tail.edge == kind {
                let horizontal = kind == .top || kind == .bottom
                let minValue = horizontal ? min(from.x, to.x) : min(from.y, to.y)
                let maxValue = horizontal ? max(from.x, to.x) : max(from.y, to.y)
                let half = min(15, (maxValue - minValue) * 0.16)
                let raw = horizontal ? CGFloat(tail.point.x) * canvas.width : CGFloat(tail.point.y) * canvas.height
                let center = min(maxValue - half, max(minValue + half, raw))
                let forward = horizontal ? to.x > from.x : to.y > from.y
                let first = center + (forward ? -half : half)
                let last = center + (forward ? half : -half)
                path.addLine(to: horizontal ? CGPoint(x: first, y: from.y) : CGPoint(x: from.x, y: first))
                path.addLine(to: tip)
                path.addLine(to: horizontal ? CGPoint(x: last, y: to.y) : CGPoint(x: to.x, y: last))
            }
            path.addLine(to: to)
        }
        let x = body.minX
        let y = body.minY
        let r = body.maxX
        let b = body.maxY
        path.move(to: CGPoint(x: x + radius, y: y))
        edge(.top, from: CGPoint(x: x + radius, y: y), to: CGPoint(x: r - radius, y: y))
        path.addQuadCurve(to: CGPoint(x: r, y: y + radius), controlPoint: CGPoint(x: r, y: y))
        edge(.right, from: CGPoint(x: r, y: y + radius), to: CGPoint(x: r, y: b - radius))
        path.addQuadCurve(to: CGPoint(x: r - radius, y: b), controlPoint: CGPoint(x: r, y: b))
        edge(.bottom, from: CGPoint(x: r - radius, y: b), to: CGPoint(x: x + radius, y: b))
        path.addQuadCurve(to: CGPoint(x: x, y: b - radius), controlPoint: CGPoint(x: x, y: b))
        edge(.left, from: CGPoint(x: x, y: b - radius), to: CGPoint(x: x, y: y + radius))
        path.addQuadCurve(to: CGPoint(x: x + radius, y: y), controlPoint: CGPoint(x: x, y: y))
        path.close()
        return path
    }
}

struct ComicCanvas: UIViewRepresentable {
    let image: UIImage
    let lettering: ComicLettering
    var selectedID: String? = nil
    var editable = false
    var onSelect: (String?) -> Void = { _ in }
    var onBegin: () -> Void = {}
    var onChange: (ComicBubble) -> Void = { _ in }
    var onEnd: () -> Void = {}
    func makeUIView(context: Context) -> ComicCanvasView { ComicCanvasView() }
    func updateUIView(_ view: ComicCanvasView, context: Context) {
        view.image = image
        view.lettering = lettering
        view.selectedID = selectedID
        view.editable = editable
        view.isUserInteractionEnabled = editable
        view.onSelect = onSelect
        view.onBegin = onBegin
        view.onChange = onChange
        view.onEnd = onEnd
        view.setNeedsDisplay()
    }
    static func dismantleUIView(_ view: ComicCanvasView, coordinator: ()) {
        view.onSelect = { _ in }
        view.onBegin = {}
        view.onChange = { _ in }
        view.onEnd = {}
        view.image = nil
        view.lettering = ComicLettering(bubbles: [])
    }
}

final class ComicCanvasView: UIView, UIGestureRecognizerDelegate {
    var image: UIImage?
    var lettering = ComicLettering(bubbles: [])
    var selectedID: String?
    var editable = false
    var onSelect: (String?) -> Void = { _ in }
    var onBegin: () -> Void = {}
    var onChange: (ComicBubble) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private enum DragKind { case move, resize, tail }
    private var dragKind: DragKind?
    private var seed: ComicBubble?
    private var origin = CGPoint.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .white
        contentMode = .redraw
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        accessibilityLabel = "漫画气泡画布"
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    private var selected: ComicBubble? { lettering.bubbles.first { $0.id == selectedID && !$0.hidden } }
    private func unit(_ p: CGPoint) -> BubblePoint {
        BubblePoint(x: Double(p.x / max(1, bounds.width)), y: Double(p.y / max(1, bounds.height)))
    }
    private func pixel(_ p: BubblePoint) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * bounds.width, y: CGFloat(p.y) * bounds.height)
    }
    private func marker(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(bounds.width - 10, max(10, p.x)), y: min(bounds.height - 10, max(10, p.y)))
    }
    private func resizePoint(_ b: ComicBubble) -> CGPoint {
        marker(pixel(BubblePoint(x: b.frame.x + b.frame.width, y: b.frame.y + b.frame.height)))
    }
    private func tailPoint(_ b: ComicBubble) -> CGPoint { marker(pixel(b.tailTip)) }
    private func control(at p: CGPoint) -> DragKind? {
        guard let b = selected else { return nil }
        if hypot(p.x - resizePoint(b).x, p.y - resizePoint(b).y) < 24 { return .resize }
        if b.tailEnabled, b.style != .caption, hypot(p.x - tailPoint(b).x, p.y - tailPoint(b).y) < 24 { return .tail }
        return nil
    }
    override func draw(_ rect: CGRect) {
        UIColor.white.setFill()
        UIRectFill(bounds)
        image?.draw(in: bounds)
        BubblePainter.draw(lettering, in: bounds)
        guard editable, let b = selected, let context = UIGraphicsGetCurrentContext() else { return }
        let frame = BubblePainter.bodyRect(b, canvas: bounds.size)
        context.setStrokeColor(UIColor.systemTeal.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [5, 3])
        context.stroke(frame.insetBy(dx: -1, dy: -1))
        context.setLineDash(phase: 0, lengths: [])
        func handle(_ p: CGPoint, color: UIColor) {
            let circle = UIBezierPath(ovalIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
            color.setFill()
            circle.fill()
            UIColor.white.setStroke()
            circle.lineWidth = 2
            circle.stroke()
        }
        handle(resizePoint(b), color: .systemTeal)
        if b.tailEnabled, b.style != .caption { handle(tailPoint(b), color: .systemOrange) }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard editable else { return false }
        var p = gestureRecognizer.location(in: self)
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let delta = pan.translation(in: self)
            p = CGPoint(x: p.x - delta.x, y: p.y - delta.y)
        }
        return control(at: p) != nil || BubbleGeometry.hitTest(unit(p), bubbles: lettering.bubbles) != nil
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard editable else { return }
        selectedID = BubbleGeometry.hitTest(unit(gesture.location(in: self)), bubbles: lettering.bubbles)
        onSelect(selectedID)
        setNeedsDisplay()
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard editable else { return }
        let p = gesture.location(in: self)
        switch gesture.state {
        case .began:
            let delta = gesture.translation(in: self)
            let start = CGPoint(x: p.x - delta.x, y: p.y - delta.y)
            if let kind = control(at: start), let selected {
                seed = selected
                dragKind = kind
            } else {
                selectedID = BubbleGeometry.hitTest(unit(start), bubbles: lettering.bubbles)
                onSelect(selectedID)
                seed = selected
                dragKind = seed == nil ? nil : .move
            }
            origin = start
            if seed != nil { onBegin() }
        case .changed:
            guard var b = seed, let kind = dragKind else { return }
            let dx = Double((p.x - origin.x) / max(1, bounds.width))
            let dy = Double((p.y - origin.y) / max(1, bounds.height))
            switch kind {
            case .move: b.frame = b.frame.moved(dx: dx, dy: dy)
            case .resize: b.frame = b.frame.resized(dw: dx, dh: dy)
            case .tail: b.tailTip = BubblePoint(x: b.tailTip.x + dx, y: b.tailTip.y + dy).clamped()
            }
            if let i = lettering.bubbles.firstIndex(where: { $0.id == b.id }) { lettering.bubbles[i] = b }
            onChange(b)
            setNeedsDisplay()
        case .ended, .cancelled, .failed:
            if seed != nil { onEnd() }
            seed = nil
            dragKind = nil
        default: break
        }
    }
}

struct LetteredArtwork: View {
    let url: URL?
    let panel: ComicPanel
    var side = 1200
    @State private var bitmap: CachedBitmap?
    var body: some View {
        Group {
            if let bitmap {
                ComicCanvas(
                    image: bitmap.image,
                    lettering: LetteringDefaults.layout(
                        for: panel, imageAspect: Double(bitmap.image.size.width / bitmap.image.size.height))
                )
                .aspectRatio(bitmap.image.size, contentMode: .fit)
            } else {
                Rectangle().fill(Ink.teal.opacity(0.08)).frame(height: 220).overlay { ProgressView() }
            }
        }.task(id: "\(url?.path ?? "")/\(side)") {
            bitmap = nil
            guard let url else { return }
            let result = try? await BitmapCache.shared.load(url, side: side)
            if !Task.isCancelled { bitmap = result }
        }.onDisappear { bitmap = nil }
    }
}
