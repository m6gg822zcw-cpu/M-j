import CZlib
import Foundation

public struct ZIPEntry: Sendable {
    public var name: String, method: UInt16, crc: UInt32, size: Int, compressedSize: Int, localOffset: Int
}
public struct ZIPArchive: Sendable {
    private let data: Data
    public let entries: [ZIPEntry]
    public init(data: Data) throws {
        guard data.count >= 22, data.count <= 512 * 1024 * 1024 else {
            throw StudioError.invalid("ZIP 文件为空、损坏或超过512MB。")
        }
        self.data = Data(data)
        func u16(_ p: Int) throws -> UInt16 {
            guard p >= 0, p + 2 <= data.count else { throw StudioError.invalid("ZIP 目录越界。") }
            return UInt16(data[p]) | UInt16(data[p + 1]) << 8
        }
        func u32(_ p: Int) throws -> UInt32 { UInt32(try u16(p)) | UInt32(try u16(p + 2)) << 16 }
        var eocd: Int? = nil
        for p in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try u32(p) == 0x0605_4b50 {
                eocd = p
                break
            }
        }
        guard let end = eocd, try u16(end + 4) == 0, try u16(end + 6) == 0 else {
            throw StudioError.invalid("不支持分卷或损坏的 ZIP。")
        }
        let count = Int(try u16(end + 10))
        var cursor = Int(try u32(end + 16))
        var list: [ZIPEntry] = []
        guard count <= 20000 else { throw StudioError.invalid("压缩包条目过多。") }
        for _ in 0..<count {
            guard try u32(cursor) == 0x0201_4b50 else { throw StudioError.invalid("ZIP 中央目录损坏。") }
            let flags = try u16(cursor + 8)
            let method = try u16(cursor + 10)
            let crc = try u32(cursor + 16)
            let compressed = try u32(cursor + 20)
            let size = try u32(cursor + 24)
            let local = try u32(cursor + 42)
            let nameLength = Int(try u16(cursor + 28))
            let extra = Int(try u16(cursor + 30))
            let comment = Int(try u16(cursor + 32))
            guard flags & 1 == 0, size != UInt32.max, compressed != UInt32.max, local != UInt32.max,
                cursor + 46 + nameLength + extra + comment <= data.count
            else { throw StudioError.invalid("不支持加密、ZIP64 或损坏的 ZIP。") }
            guard let name = String(data: data.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8)
            else { throw StudioError.invalid("压缩包文件名不是 UTF-8。") }
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), !name.contains("\\") else {
                throw StudioError.invalid("压缩包包含不安全路径。")
            }
            list.append(
                ZIPEntry(
                    name: name, method: method, crc: crc, size: Int(size), compressedSize: Int(compressed),
                    localOffset: Int(local)))
            cursor += 46 + nameLength + extra + comment
        }
        self.entries = list
    }
    private func u16(_ p: Int) throws -> UInt16 {
        guard p >= 0, p + 2 <= data.count else { throw StudioError.invalid("ZIP 文件越界。") }
        return UInt16(data[p]) | UInt16(data[p + 1]) << 8
    }
    private func u32(_ p: Int) throws -> UInt32 { UInt32(try u16(p)) | UInt32(try u16(p + 2)) << 16 }
    public func read(_ name: String, limit: Int = 64 * 1024 * 1024) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else { throw StudioError.invalid("压缩包缺少 \(name)。") }
        guard entry.size <= limit, try u32(entry.localOffset) == 0x0403_4b50 else {
            throw StudioError.invalid("ZIP 条目超限或损坏。")
        }
        let start = entry.localOffset + 30 + Int(try u16(entry.localOffset + 26)) + Int(try u16(entry.localOffset + 28))
        guard start >= 0, start + entry.compressedSize <= data.count else { throw StudioError.invalid("ZIP 图片数据不完整。") }
        let compressed = data.subdata(in: start..<start + entry.compressedSize)
        let output: Data
        if entry.method == 0 {
            output = compressed
        } else if entry.method == 8 {
            var stream = z_stream()
            let code = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard code == Z_OK else { throw StudioError.invalid("无法初始化 ZIP 解压器。") }
            defer { inflateEnd(&stream) }
            var inflated = Data(count: max(1, entry.size))
            let result = compressed.withUnsafeBytes { input in
                inflated.withUnsafeMutableBytes { dest -> Int32 in
                    stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = dest.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(dest.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard result == Z_STREAM_END, stream.total_out == entry.size else {
                throw StudioError.invalid("ZIP 解压失败或尺寸不符。")
            }
            inflated.count = entry.size
            output = inflated
        } else {
            throw StudioError.invalid("不支持此 ZIP 压缩算法。")
        }
        let crc = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(output.count)) }
        guard output.count == entry.size, UInt32(crc) == entry.crc else { throw StudioError.invalid("ZIP 文件校验失败。") }
        return output
    }
    public func firstImage() throws -> Data {
        guard
            let name = entries.first(where: { entry in
                [".png", ".jpg", ".jpeg", ".webp"].contains { ext in entry.name.lowercased().hasSuffix(ext) }
            })?.name
        else { throw StudioError.invalid("生图 ZIP 中没有图片。") }
        return try read(name)
    }
    public static func write(files: [String: URL], to destination: URL) throws {
        guard files.count <= 20000 else { throw StudioError.invalid("备份条目太多。") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw StudioError.invalid("无法创建备份文件。")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var directory = Data()
        var offset: UInt32 = 0
        func bytes16(_ x: UInt16) -> Data { Data([UInt8(x & 255), UInt8((x >> 8) & 255)]) }
        func bytes32(_ x: UInt32) -> Data {
            Data([UInt8(x & 255), UInt8((x >> 8) & 255), UInt8((x >> 16) & 255), UInt8(x >> 24)])
        }
        func pack(_ parts: [Data]) -> Data {
            var result = Data()
            for part in parts { result.append(part) }
            return result
        }
        func w(_ data: Data) throws {
            guard UInt64(offset) + UInt64(data.count) < 512 * 1024 * 1024 else {
                throw StudioError.invalid("归档超过512MB，请按章导出图片或减少旧图片。")
            }
            try handle.write(contentsOf: data)
            offset += UInt32(data.count)
        }
        for name in files.keys.sorted() {
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator: "/").contains(".."),
                let url = files[name]
            else { throw StudioError.invalid("备份路径无效。") }
            let filename = Data(name.utf8)
            guard filename.count < 65535 else { throw StudioError.invalid("文件名过长。") }
            let start = offset
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            let header = pack([
                bytes32(0x0403_4b50), bytes16(20), bytes16(0x0808), bytes16(0), bytes16(0), bytes16(0), bytes32(0),
                bytes32(0), bytes32(0), bytes16(UInt16(filename.count)), bytes16(0), filename,
            ])
            try w(header)
            var crc: uLong = 0
            var size: UInt32 = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard UInt64(size) + UInt64(chunk.count) < UInt64(UInt32.max) else {
                    throw StudioError.invalid("备份单文件超过4GB。")
                }
                crc = chunk.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count)) }
                size += UInt32(chunk.count)
                try w(chunk)
            }
            try w(bytes32(0x0807_4b50) + bytes32(UInt32(crc)) + bytes32(size) + bytes32(size))
            directory.append(
                pack([
                    bytes32(0x0201_4b50), bytes16(20), bytes16(20), bytes16(0x0808), bytes16(0), bytes16(0), bytes16(0),
                    bytes32(UInt32(crc)), bytes32(size), bytes32(size), bytes16(UInt16(filename.count)), bytes16(0),
                    bytes16(0), bytes16(0), bytes16(0), bytes32(0), bytes32(start), filename,
                ]))
        }
        let directoryOffset = offset
        try w(directory)
        try w(
            pack([
                bytes32(0x0605_4b50), bytes16(0), bytes16(0), bytes16(UInt16(files.count)),
                bytes16(UInt16(files.count)), bytes32(UInt32(directory.count)), bytes32(directoryOffset), bytes16(0),
            ]))
        try handle.synchronize()
    }
}
