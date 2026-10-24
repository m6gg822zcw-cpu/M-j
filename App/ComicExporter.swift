import Foundation
import ImageIO
import MoxuCore
import UIKit

enum ExportKind { case backup, pdf, png, html }

/// Runs away from MainActor; decodes and renders one page at a time.
actor ComicExporter {
    static let shared = ComicExporter()
    private let pageSize = CGSize(width: 1170, height: 1656)
    private struct Layout { var index: Int, y: CGFloat, height: CGFloat, imageHeight: CGFloat }
    private let margin: CGFloat = 64, contentWidth: CGFloat = 1042
    func export(_ kind: ExportKind, project: Project, run: ChapterRun, repository: Repository, artist: ArtistPreset)
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
        let pages = layouts(run: run, assets: assets)
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
    private func resolveAssets(_ project: Project, _ run: ChapterRun, _ repository: Repository) async throws -> [Int:
        URL]
    {
        var assets: [Int: URL] = [:]
        for (i, panel) in run.panels.enumerated() {
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
        var parts = panel.dialogue.map { d in
            "\(d.speaker)\(d.kind == "thought" ? "（心声）":d.kind == "offscreen" ? "（画外）":"")：\(d.text)"
        }
        if !panel.sfx.isEmpty { parts.append("音效：\(panel.sfx)") }
        return parts.joined(separator: "\n")
    }
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
    private func layouts(run: ChapterRun, assets: [Int: URL]) -> [[Layout]] {
        var pages: [[Layout]] = []
        var current: [Layout] = []
        var y: CGFloat = 142
        for (i, p) in run.panels.enumerated() {
            let extra: CGFloat =
                assets[i] != nil
                ? 100
                : textHeight(p.narration, size: 28, width: contentWidth)
                    + textHeight(caption(p), size: 30, width: contentWidth) + 100
            let imageH = min(1280, max(260, contentWidth * ratio(assets[i])))
            let height = min(1410, imageH + extra)
            if y + height > 1560, !current.isEmpty {
                pages.append(current)
                current = []
                y = 142
            }
            current.append(Layout(index: i, y: y, height: height, imageHeight: max(200, height - extra)))
            y += height + 24
        }
        if !current.isEmpty { pages.append(current) }
        return pages
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
                var y = item.y
                _ = drawText(panel.id, x: margin, y: y, width: contentWidth, size: 20, color: .darkGray)
                y += 30
                if assets[item.index] == nil, !panel.narration.isEmpty {
                    y += drawText(panel.narration, x: margin, y: y, width: contentWidth, size: 28) + 12
                }
                let rect = CGRect(x: margin, y: y, width: contentWidth, height: item.imageHeight)
                if let url = assets[item.index], let image = bitmap(url) {
                    let scale = min(rect.width / image.size.width, rect.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    let imageRect = CGRect(
                        x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
                        height: size.height)
                    image.draw(in: imageRect)
                    BubblePainter.draw(
                        LetteringDefaults.layout(for: panel, imageAspect: Double(image.size.width / image.size.height)),
                        in: imageRect)
                } else {
                    UIColor(white: 0.95, alpha: 1).setFill()
                    UIRectFill(rect)
                    _ = drawText(
                        "尚未出图 · \(panel.action)", x: margin + 24, y: y + 24, width: contentWidth - 48, size: 26,
                        color: .darkGray)
                }
                y += item.imageHeight + 12
                if assets[item.index] == nil {
                    _ = drawText(caption(panel), x: margin, y: y, width: contentWidth, size: 30)
                }
            }
        }
        _ = drawText("墨序    \(page) / \(total)", x: margin, y: 1610, width: contentWidth, size: 20, color: .gray)
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
