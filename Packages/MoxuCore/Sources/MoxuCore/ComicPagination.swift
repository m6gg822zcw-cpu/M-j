import Foundation

/// Local page composition. Panel indices always keep their original storyboard order.
public enum ComicPagination {
    public static let supportedPanelsPerPage = [1, 2, 4]

    public static func normalizedPanelsPerPage(_ value: Int) -> Int {
        supportedPanelsPerPage.contains(value) ? value : 4
    }

    public static func pages(panelCount: Int, panelsPerPage: Int) -> [[Int]] {
        guard panelCount > 0 else { return [] }
        let count = normalizedPanelsPerPage(panelsPerPage)
        return stride(from: 0, to: panelCount, by: count).map { start in
            // Subtract before adding so the final page cannot overflow Int.
            Array(start..<(start + min(count, panelCount - start)))
        }
    }

    /// Two panels stack vertically; four panels read left to right, then top to bottom.
    public static func cells(panelsPerPage: Int, in bounds: CGRect, gap: CGFloat) -> [CGRect] {
        let count = normalizedPanelsPerPage(panelsPerPage)
        guard valid(bounds) else { return Array(repeating: .zero, count: count) }
        guard count > 1 else { return [bounds] }
        let columns = count == 4 ? 2 : 1
        let requestedGap = gap.isFinite ? max(0, gap) : 0
        let spacing = min(requestedGap, columns == 2 ? min(bounds.width, bounds.height) : bounds.height)
        let width = (bounds.width - (columns == 2 ? spacing : 0)) / CGFloat(columns)
        let height = (bounds.height - spacing) / 2
        return (0..<count).map { index in
            CGRect(
                x: bounds.minX + CGFloat(index % columns) * (width + spacing),
                y: bounds.minY + CGFloat(index / columns) * (height + spacing),
                width: width, height: height)
        }
    }

    /// The whole image remains visible, leaving unused space around other aspect ratios.
    public static func aspectFit(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard valid(bounds) else { return .zero }
        let empty = CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
        guard imageSize.width.isFinite, imageSize.height.isFinite,
            imageSize.width > 0, imageSize.height > 0
        else { return empty }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        guard scale.isFinite else { return empty }
        let width = min(bounds.width, imageSize.width * scale)
        let height = min(bounds.height, imageSize.height * scale)
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    private static func valid(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite && bounds.origin.y.isFinite
            && bounds.width.isFinite && bounds.height.isFinite
            && bounds.size.width > 0 && bounds.size.height > 0
            && bounds.maxX.isFinite && bounds.maxY.isFinite
    }
}
