import CoreFoundation
import Foundation

public enum ChapterParser {
    public static func decode(_ data: Data) throws -> String {
        let encoding: String.Encoding
        if data.starts(with: [0xff, 0xfe]) {
            encoding = .utf16LittleEndian
        } else if data.starts(with: [0xfe, 0xff]) {
            encoding = .utf16BigEndian
        } else if let s = String(data: data, encoding: .utf8) {
            return normalize(s)
        } else {
            encoding = String.Encoding(rawValue: UInt(CFStringConvertEncodingToNSStringEncoding(0x0632)))
        }
        if let s = String(data: data, encoding: encoding) { return normalize(s) }
        // CoreFoundation's converter supports GB18030 even where Swift String.Encoding doesn't.
        if !data.starts(with: [0xff, 0xfe]), !data.starts(with: [0xfe, 0xff]) {
            let cf = data.withUnsafeBytes { bytes in
                CFStringCreateWithBytes(nil, bytes.bindMemory(to: UInt8.self).baseAddress, data.count, 0x0632, false)
            }
            if let cf {
                var chars = [UniChar](repeating: 0, count: CFStringGetLength(cf))
                CFStringGetCharacters(cf, CFRange(location: 0, length: chars.count), &chars)
                return normalize(String(decoding: chars, as: UTF16.self))
            }
        }
        throw StudioError.invalid("无法识别文本编码，请先另存为 UTF-8 TXT。")
    }
    public static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(
            of: "\u{feff}", with: ""
        ).replacingOccurrences(of: "\0", with: "")
    }
    public static func parse(_ text: String, title: String, headingPattern: String? = nil) throws -> [RawChapter] {
        let text = normalize(text)
        let ns = text as NSString
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioError.invalid("小说正文为空。")
        }
        let pattern =
            headingPattern?.isEmpty == false
            ? headingPattern!
            : #"^[\t 　]*(?:第[\t 　]*[零〇一二三四五六七八九十百千万两0-9０-９]+[\t 　]*[章回节集卷部話话節].{0,65}|(?:chapter|part)[\t 　]+[0-9ivxlcdm]+[^\n]{0,65}|(?:序章|楔子|序幕|引子|尾声|终章|后记|番外)(?:[\t 　:：、.．—\-][^\n]*|[零一二三四五六七八九十0-9]{0,6})|#{1,4}[\t ]+[^\n]{1,80})[\t 　]*$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive])
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [RawChapter(title: title, text: text, sourceStart: 0)] }
        var chapters: [RawChapter] = []
        if let first = matches.first, first.range.location > 0 {
            let prefix = ns.substring(to: first.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { chapters.append(RawChapter(title: "卷首文本 · 目录与说明可跳过", text: prefix, sourceStart: 0)) }
        }
        for (i, m) in matches.enumerated() {
            var start = NSMaxRange(m.range)
            if start < ns.length, ns.substring(with: NSRange(location: start, length: 1)) == "\n" { start += 1 }
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let heading = ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
                chapters.append(
                    RawChapter(
                        title: heading.replacingOccurrences(of: #"^#{1,4}\s+"#, with: "", options: .regularExpression),
                        text: body, sourceStart: start))
            }
        }
        guard !chapters.isEmpty else { throw StudioError.invalid("仅找到章标题，没有正文。请修改章节识别规则。") }
        return chapters
    }
    public static func jsonChapters(_ data: Data) throws -> [RawChapter] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let rows = value as? [[String: Any]] ?? (value as? [String: Any])?["chapters"] as? [[String: Any]],
            !rows.isEmpty
        else { throw StudioError.invalid("JSON 需为章节数组，或包含 chapters 数组。") }
        return try rows.enumerated().map { i, row in
            guard let text = row["text"] as? String ?? row["content"] as? String, !text.isEmpty else {
                throw StudioError.invalid("第 \(i+1) 个条目缺少正文。")
            }
            return RawChapter(
                title: row["title"] as? String ?? row["name"] as? String ?? "第\(i+1)章", text: normalize(text),
                sourceStart: 0)
        }
    }
    public static func units(_ text: String) -> [SourceUnit] {
        let ns = text as NSString
        let re = try! NSRegularExpression(pattern: #"[^\n]+(?:\n(?!\s*\n)[^\n]+)*"#)
        var result: [SourceUnit] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let block = ns.substring(with: m.range)
            var local = 0
            var buffer = ""
            var bufferCount = 0
            for c in block {
                if bufferCount >= 1000 {
                    if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result.append(
                            SourceUnit(
                                id: String(format: "U%05d", result.count + 1), text: buffer,
                                utf16Start: m.range.location + local))
                    }
                    local += buffer.utf16.count
                    buffer = ""
                    bufferCount = 0
                }
                buffer.append(c)
                bufferCount += 1
            }
            if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(
                    SourceUnit(
                        id: String(format: "U%05d", result.count + 1), text: buffer,
                        utf16Start: m.range.location + local))
            }
        }
        return result
    }
    public static func batches(_ units: [SourceUnit], limit: Int) -> [[String]] {
        var result: [[String]] = []
        var part: [String] = []
        var count = 0
        for u in units {
            if !part.isEmpty && count + u.text.count > max(1000, limit) {
                result.append(part)
                part = []
                count = 0
            }
            part.append(u.id)
            count += u.text.count
        }
        if !part.isEmpty { result.append(part) }
        return result
    }
}
