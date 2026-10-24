import Foundation
import ImageIO
import MoxuCore
import UIKit

final class CachedBitmap: @unchecked Sendable {
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}
actor BitmapCache {
    static let shared = BitmapCache()
    private let cache = NSCache<NSString, CachedBitmap>()
    init() {
        cache.countLimit = 40
        cache.totalCostLimit = 48 * 1024 * 1024
    }
    func clear() { cache.removeAllObjects() }
    func load(_ url: URL, side: Int) throws -> CachedBitmap {
        let stamp =
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?
                .timeIntervalSince1970) ?? 0
        let key = "\(url.path)|\(side)|\(stamp)" as NSString
        if let existing = cache.object(forKey: key) { return existing }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw StudioError.invalid("图片文件无法读取。") }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            throw StudioError.invalid("图片无法解码。")
        }
        let bitmap = CachedBitmap(UIImage(cgImage: cg))
        cache.setObject(bitmap, forKey: key, cost: cg.width * cg.height * 4)
        return bitmap
    }
}
actor AssetProcessor: ImageProcessor {
    private func image(_ data: Data, side: Int) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw StudioError.invalid("不支持的图片格式。")
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            throw StudioError.invalid("图片解码失败。")
        }
        return UIImage(cgImage: cg)
    }
    func normalize(_ data: Data) throws -> Data {
        let img = try image(data, side: 3072)
        guard let out = img.pngData() else { throw StudioError.invalid("图片编码失败。") }
        return out
    }
    private func renderer(_ size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
    }
    private func draw(_ image: UIImage, into rect: CGRect) {
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(
            in: CGRect(
                x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }
    func prepare(_ images: [ReferenceImage], profile: APIProfile) throws -> [ReferenceImage] {
        if images.isEmpty { return [] }
        if profile.kind == .novelAI {
            guard images.count == 1 else { throw StudioError.invalid("NAI 不叠加多个人物参考。") }
            let img = try image(images[0].data, side: 2048)
            let size: CGSize
            if profile.referenceMode == .imageToImage {
                size = CGSize(width: CGFloat(profile.width), height: CGFloat(profile.height))
            } else {
                let ratio = img.size.width / img.size.height
                size =
                    ratio > 1.15
                    ? CGSize(width: 1536, height: 1024)
                    : ratio < 0.85 ? CGSize(width: 1024, height: 1536) : CGSize(width: 1472, height: 1472)
            }
            let data = renderer(size).pngData { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                draw(img, into: CGRect(origin: .zero, size: size))
            }
            return [ReferenceImage(data: data, label: images[0].label)]
        }
        let limit = min(8, max(1, profile.maxReferences))
        if images.count <= limit {
            return try images.map { ref in
                let img = try image(ref.data, side: 1024)
                guard let data = img.jpegData(compressionQuality: 0.9) else { throw StudioError.invalid("参考图编码失败。") }
                return ReferenceImage(data: data, mime: "image/jpeg", label: ref.label)
            }
        }
        let cols = 2
        let rows = Int(ceil(Double(images.count) / 2))
        let cell = min(900, 4096 / max(1, rows))
        let size = CGSize(width: 1536, height: CGFloat(rows * cell))
        let decoded = try images.map { try image($0.data, side: 1024) }
        let data = renderer(size).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for i in images.indices {
                let x = CGFloat(i % cols) * 768
                let y = CGFloat(i / cols * cell)
                draw(decoded[i], into: CGRect(x: x + 12, y: y + 55, width: 744, height: CGFloat(cell - 70)))
                let label = String(images[i].label.prefix(8)) + " · " + String(images[i].label.dropFirst(37))
                (label as NSString).draw(
                    in: CGRect(x: x + 16, y: y + 12, width: 736, height: 40),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: UIColor.black,
                    ])
            }
        }
        return [
            ReferenceImage(
                data: data, mime: "image/jpeg", label: "编号对照板（编号为ID前8位）：" + images.map(\.label).joined(separator: "；"))
        ]
    }
}
