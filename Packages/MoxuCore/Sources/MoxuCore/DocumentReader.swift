import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

private final class XMLDocument: NSObject, XMLParserDelegate {
    private static let containerNamespace = "urn:oasis:names:tc:opendocument:xmlns:container"
    private static let packageNamespace = "http://www.idpf.org/2007/opf"
    private static let htmlNamespace = "http://www.w3.org/1999/xhtml"
    private static let wordNamespaces: Set<String> = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main",
    ]
    var items: [String: String] = [:], order: [String] = [], rootfile: String?, text = ""
    private var ignoredDepth = 0
    // Older fixtures and EPUB producers omit namespace declarations; prefixes themselves are never identities.
    private static func matches(_ namespace: String?, _ expected: String) -> Bool {
        namespace == nil || namespace == "" || namespace == expected
    }
    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName q: String?,
        attributes: [String: String]
    ) {
        if name == "rootfile", Self.matches(namespaceURI, Self.containerNamespace) {
            rootfile = attributes["full-path"]
        }
        if Self.matches(namespaceURI, Self.packageNamespace) {
            if name == "item", let id = attributes["id"], let href = attributes["href"] { items[id] = href }
            if name == "itemref", attributes["linear"] != "no", let id = attributes["idref"] { order.append(id) }
        }
        if ignoredDepth > 0 {
            ignoredDepth += 1
            return
        }
        let isHTML = Self.matches(namespaceURI, Self.htmlNamespace)
        let isWord = Self.wordNamespaces.contains(namespaceURI ?? "")
        if isHTML, ["head", "script", "style"].contains(name.lowercased()) {
            ignoredDepth = 1
            return
        }
        if (isHTML && ["p", "br", "div", "h1", "h2", "h3"].contains(name))
            || (isWord && ["p", "br"].contains(name))
        { text += "\n" }
        if isWord, name == "tab" { text += "\t" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if ignoredDepth == 0 { text += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName q: String?) {
        if ignoredDepth > 0 {
            ignoredDepth -= 1
            return
        }
        if (Self.matches(namespaceURI, Self.htmlNamespace) && ["p", "div", "h1", "h2", "h3"].contains(name))
            || (Self.wordNamespaces.contains(namespaceURI ?? "") && name == "p")
        { text += "\n" }
    }
    static func read(_ data: Data) throws -> XMLDocument {
        let delegate = XMLDocument()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw StudioError.invalid("电子书 XML 无法解析。") }
        return delegate
    }
}
public enum DocumentReader {
    public static func chapters(data: Data, extension ext: String, title: String, headingPattern: String? = nil) throws
        -> [RawChapter]
    {
        switch ext.lowercased() {
        case "json": return try ChapterParser.jsonChapters(data)
        case "epub":
            let zip = try ZIPArchive(data: data)
            guard let opf = try XMLDocument.read(zip.read("META-INF/container.xml")).rootfile else {
                throw StudioError.invalid("EPUB 缺少阅读顺序。")
            }
            let book = try XMLDocument.read(zip.read(opf))
            let base = (opf as NSString).deletingLastPathComponent
            var result: [RawChapter] = []
            for id in book.order {
                guard let href = book.items[id] else { continue }
                let rawPath =
                    (base.isEmpty ? href : base + "/" + href).components(separatedBy: "#")[0].removingPercentEncoding
                    ?? href
                let path = (rawPath as NSString).standardizingPath
                guard !path.hasPrefix("/"), !path.hasPrefix("..") else { throw StudioError.invalid("EPUB 路径无效。") }
                let text = try XMLDocument.read(zip.read(path)).text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result += try ChapterParser.parse(
                        text, title: "第\(result.count+1)章", headingPattern: headingPattern)
                }
            }
            guard !result.isEmpty else { throw StudioError.invalid("EPUB 没有可读取正文，或含 DRM。") }
            return result
        case "docx":
            let zip = try ZIPArchive(data: data)
            let text = try XMLDocument.read(zip.read("word/document.xml")).text
            return try ChapterParser.parse(text, title: title, headingPattern: headingPattern)
        default:
            return try ChapterParser.parse(ChapterParser.decode(data), title: title, headingPattern: headingPattern)
        }
    }
}
