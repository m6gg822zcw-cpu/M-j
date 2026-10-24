import Foundation
import ImageIO
import MoxuCore
import UIKit

enum ExportKind { case backup, pdf, png, html }

/// Runs away from MainActor; decodes and renders one page at a time.
actor ComicExporter {
    static let shared = ComicExporter()
    private let pageSize = CGSize(width: 1170, height: 1656)
    private struct Layout { var index: Int, rect: CGRect }
    private let margin: CGFloat = 64, contentWidth: CGFloat = 1042
    func export(
        _ kind: ExportKind, project: Project, run: ChapterRun, repository: Repository, artist: ArtistPreset,
        panelsPerPage: Int = 4
    )
        async throws -> URL
    {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MoxuExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = safeName(project.title) + "-第\(run.ordinal)章"
        if kind == .backup {
            let url = folder.appendingPathComponent(safeName(project.title) + ".moxu")
            try await repository.exportProject(project.id, artist: artist, destination: url)
            return url
        }
        guard !run.panels.isEmpty else { throw StudioError.invalid("本章没有分镜可导出。") }
        let assets = try await resolveAssets(project, run, repository)
        for (index, url) in assets {
            let aspect = 1 / max(0.0001, Double(ratio(url)))
            if !BubblePainter.overflowing(
                LetteringDefaults.layout(for: run.panels[index], imageAspect: aspect), aspect: aspect
            ).isEmpty {
                throw StudioError.invalid("\(run.panels[index].id) 有气泡文字放不下，请在「调整气泡」放大或修改后再导出。")
            }
        }
        let pages = layouts(run: run, panelsPerPage: panelsPerPage)
        for items in pages {
            for item in items where assets[item.index] == nil {
                let textRect = placeholderRect(in: item.rect)
                guard textHeight(placeholderText(run.panels[item.index]), size: 14, width: textRect.width)
                    <= textRect.height
                else {
                    throw StudioError.invalid(
                        "\(run.panels[item.index].id) 的未出图文字超出页面空间，请改为每页1格或先生成图片后再导出。")
                }
            }
        }
        if kind == .pdf {
            let url = folder.appendingPathComponent(base + ".pdf")
            let format = UIGraphicsPDFRendererFormat()
            format.documentInfo = [kCGPDFContextTitle as String: project.title, kCGPDFContextCreator as String: "墨序"]
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
            try renderer.writePDF(to: url) { context in
                for (pageIndex, items) in pages.enumerated() {
                    autoreleasepool {
                        context.beginPage()
                        drawPage(
                            items, run: run, project: project, assets: assets, page: pageIndex + 1, total: pages.count)
                    }
                }
            }
            return url
        }
        let images = folder.appendingPathComponent("Pages", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var files: [String: URL] = [:]
        for (i, items) in pages.enumerated() {
            try Task.checkCancellation()
            let name = String(format: "%03d.png", i + 1)
            let url = images.appendingPathComponent(name)
            try autoreleasepool {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let data = UIGraphicsImageRenderer(size: pageSize, format: format).pngData { _ in
                    drawPage(items, run: run, project: project, assets: assets, page: i + 1, total: pages.count)
                }
                try data.write(to: url, options: .atomic)
            }
            files[name] = url
        }
        if kind == .png {
            let out = folder.appendingPathComponent(base + "-PNG.zip")
            try ZIPArchive.write(files: files, to: out)
            try? FileManager.default.removeItem(at: images)
            return out
        }
        let out = folder.appendingPathComponent(base + ".html")
        guard FileManager.default.createFile(atPath: out.path, contents: nil) else {
            throw StudioError.invalid("无法创建导出文件。")
        }
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        func write(_ s: String) throws { try handle.write(contentsOf: Data(s.utf8)) }
        try write(
            "<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>\(escape(project.title))</title><style>body{margin:0;background:#e9e5dc;color:#302b27;font-family:system-ui}header{padding:18px;text-align:center}main{max-width:850px;margin:auto}img{display:block;width:100%;margin-bottom:20px}button{padding:8px 18px;border:1px solid #b4664a;background:#fff8ef;border-radius:6px}@media print{body{background:white}header{display:none}img{break-after:page;margin:0}main{max-width:none}@page{margin:0;size:A4}}</style><header>\(escape(project.title)) · \(escape(run.title)) <button onclick=\"window.print()\">打印 / PDF</button></header><main>"
        )
        for name in files.keys.sorted() {
            try autoreleasepool {
                let data = try Data(contentsOf: files[name]!, options: .mappedIfSafe)
                try write("<img alt=\"漫画页 \(name)\" src=\"data:image/png;base64,\(data.base64EncodedString())\">")
            }
        }
        try write("</main></html>")
        try? FileManager.default.removeItem(at: images)
        return out
    }
    private func resolveAssets(
        _ project: Project, _ run: ChapterRun, _ repository: Repository, indices: [Int]? = nil
    ) async throws -> [Int: URL] {
        var assets: [Int: URL] = [:]
        for i in indices ?? Array(run.panels.indices) {
            try Task.checkCancellation()
            let panel = run.panels[i]
            if let path = panel.imageFile {
                guard try await repository.exists(project.id, path: path) else {
                    throw StudioError.invalid("\(panel.id) 图片缺失，请恢复图片后再导出。")
                }
                assets[i] = try await repository.file(project.id, path)
            }
        }
        return assets
    }
    private func textHeight(_ text: String, size: CGFloat, width: CGFloat) -> CGFloat {
        if text.isEmpty { return 0 }
        return ceil(
            (text as NSString).boundingRect(
                with: CGSize(width: width, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: UIFont.systemFont(ofSize: size)], context: nil
            ).height)
    }
    private func caption(_ panel: ComicPanel) -> String {
        // A saved empty layer deliberately suppresses the original dialogue, including without an image.
        if let saved = panel.lettering {
            return ((try? saved.validated())?.bubbles ?? []).filter { !$0.hidden }
                .map(\.displayedText).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        var parts = panel.dialogue.map { d in
            "\(d.speaker)\(d.kind == "thought" ? "（心声）":d.kind == "offscreen" ? "（画外）":"")：\(d.text)"
        }
        if let sfx = SoundEffects.displayText(panel.sfx) { parts.append("音效：\(sfx)") }
        return parts.joined(separator: "\n")
    }
    private func placeholderText(_ panel: ComicPanel) -> String {
        var parts = ["尚未出图", panel.action]
        if panel.lettering == nil, !panel.narration.isEmpty { parts.append(panel.narration) }
        parts.append(caption(panel))
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private func imageBounds(in cell: CGRect) -> CGRect {
        CGRect(x: cell.minX + 10, y: cell.minY + 38, width: cell.width - 20, height: cell.height - 48)
    }
    private func placeholderRect(in cell: CGRect) -> CGRect { imageBounds(in: cell).insetBy(dx: 20, dy: 20) }
    private func ratio(_ url: URL?) -> CGFloat {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? NSNumber,
            let h = props[kCGImagePropertyPixelHeight] as? NSNumber
        else { return 0.65 }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5
            ? CGFloat(w.doubleValue / max(1, h.doubleValue)) : CGFloat(h.doubleValue / max(1, w.doubleValue))
    }
    private func layouts(run: ChapterRun, panelsPerPage: Int) -> [[Layout]] {
        let bounds = CGRect(x: margin, y: 142, width: contentWidth, height: 1418)
        let cells = ComicPagination.cells(panelsPerPage: panelsPerPage, in: bounds, gap: 24)
        return ComicPagination.pages(panelCount: run.panels.count, panelsPerPage: panelsPerPage).map { indices in
            zip(indices, cells).map { Layout(index: $0.0, rect: $0.1) }
        }
    }
    private func bitmap(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
    private func drawText(
        _ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, color: UIColor = .black,
        weight: UIFont.Weight = .regular
    ) -> CGFloat {
        let h = textHeight(text, size: size, width: width)
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        (text as NSString).draw(
            in: CGRect(x: x, y: y, width: width, height: h + 3), withAttributes: [.font: font, .foregroundColor: color])
        return h
    }
    private func drawPage(
        _ items: [Layout], run: ChapterRun, project: Project, assets: [Int: URL], page: Int, total: Int
    ) {
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: pageSize))
        _ = drawText(project.title, x: margin, y: 42, width: contentWidth, size: 30, weight: .semibold)
        _ = drawText(run.title, x: margin, y: 86, width: contentWidth, size: 22, color: .darkGray)
        for item in items {
            autoreleasepool {
                let panel = run.panels[item.index]
                UIColor(white: 0.83, alpha: 1).setStroke()
                let border = UIBezierPath(rect: item.rect)
                border.lineWidth = 1
                border.stroke()
                _ = drawText(
                    "第 \(item.index + 1) 格", x: item.rect.minX + 10, y: item.rect.minY + 7, width: item.rect.width - 20,
                    size: 20, color: .darkGray)
                let rect = imageBounds(in: item.rect)
                if let url = assets[item.index], let image = bitmap(url) {
                    let imageRect = ComicPagination.aspectFit(imageSize: image.size, in: rect)
                    image.draw(in: imageRect)
                    BubblePainter.draw(
                        LetteringDefaults.layout(for: panel, imageAspect: Double(image.size.width / image.size.height)),
                        in: imageRect)
                } else {
                    UIColor(white: 0.95, alpha: 1).setFill()
                    UIRectFill(rect)
                    let textRect = placeholderRect(in: item.rect)
                    let text = placeholderText(panel)
                    var size: CGFloat = 26
                    // Reader placeholders also retain all text; export separately rejects text too small to read.
                    while size > 1 && textHeight(text, size: size, width: textRect.width) > textRect.height {
                        size -= 1
                    }
                    _ = drawText(
                        text, x: textRect.minX, y: textRect.minY, width: textRect.width, size: size, color: .darkGray)
                }
            }
        }
        _ = drawText("墨序    \(page) / \(total)", x: margin, y: 1610, width: contentWidth, size: 20, color: .gray)
    }
    /// The reader uses the same page layout and painter as PDF, PNG and HTML.
    func pagePreview(
        project: Project, run: ChapterRun, repository: Repository, pageIndex: Int, panelsPerPage: Int = 4,
        scale: CGFloat = 0.5
    ) async throws -> CachedBitmap {
        let pages = layouts(run: run, panelsPerPage: panelsPerPage)
        guard pages.indices.contains(pageIndex) else { throw StudioError.invalid("漫画页不存在。") }
        let items = pages[pageIndex]
        let assets = try await resolveAssets(project, run, repository, indices: items.map(\.index))
        try Task.checkCancellation()
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(1, max(0.25, scale))
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: pageSize, format: format).image { _ in
            drawPage(items, run: run, project: project, assets: assets, page: pageIndex + 1, total: pages.count)
        }
        return CachedBitmap(image)
    }
    private func safeName(_ s: String) -> String {
        let result = s.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r")).joined(separator: "-")
        return String(result.prefix(70))
    }
    func preview(url: URL, panel: ComicPanel) async throws -> CachedBitmap {
        let raw = try await BitmapCache.shared.load(url, side: 2400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: raw.image.size, format: format).image { _ in
            let bounds = CGRect(origin: .zero, size: raw.image.size)
            UIColor.white.setFill()
            UIRectFill(bounds)
            raw.image.draw(in: bounds)
            BubblePainter.draw(
                LetteringDefaults.layout(for: panel, imageAspect: Double(raw.image.size.width / raw.image.size.height)),
                in: bounds)
        }
        return CachedBitmap(image)
    }
    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(
            of: ">", with: "&gt;"
        ).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
