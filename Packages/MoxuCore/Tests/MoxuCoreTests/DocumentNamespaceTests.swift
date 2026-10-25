import Foundation
import XCTest

@testable import MoxuCore

final class DocumentNamespaceTests: XCTestCase {
    func testPrefixedEPUBNamespacesKeepSpineOrderAndExcludeHeadContent() throws {
        let data = try archive([
            "META-INF/container.xml": """
                <ocf:container xmlns:ocf="urn:oasis:names:tc:opendocument:xmlns:container"><ocf:rootfiles>
                <ocf:rootfile full-path="OPS/book.opf"/></ocf:rootfiles></ocf:container>
                """,
            "OPS/book.opf": """
                <opf:package xmlns:opf="http://www.idpf.org/2007/opf"><opf:manifest>
                <opf:item id="a" href="a.xhtml"/><opf:item id="b" href="b.xhtml"/>
                </opf:manifest><opf:spine><opf:itemref idref="b"/><opf:itemref idref="a"/></opf:spine></opf:package>
                """,
            "OPS/b.xhtml": """
                <h:html xmlns:h="http://www.w3.org/1999/xhtml"><h:head><h:title>禁止导入的元数据</h:title>
                <h:style>禁止导入的样式</h:style><h:script>禁止导入的脚本</h:script></h:head>
                <h:body><h:h1>第一章 雨</h:h1><h:p>林舟走进书店。</h:p></h:body></h:html>
                """,
            "OPS/a.xhtml": """
                <html xmlns="http://www.w3.org/1999/xhtml"><body><h1>第二章 桥</h1><p>苏禾抬起头来。</p></body></html>
                """,
        ])
        let chapters = try DocumentReader.chapters(data: data, extension: "epub", title: "书")
        XCTAssertEqual(chapters.map(\.title), ["第一章 雨", "第二章 桥"])
        XCTAssertEqual(chapters.count, 2)
        XCTAssertTrue(chapters[0].text.contains("林舟走进书店。"))
        XCTAssertTrue(chapters[1].text.contains("苏禾抬起头来。"))
        XCTAssertFalse(chapters.map(\.text).joined().contains("禁止导入"))
    }

    func testDOCXParagraphsUseNamespaceURIRatherThanPrefix() throws {
        for (prefix, namespace) in [
            ("ns0", "http://schemas.openxmlformats.org/wordprocessingml/2006/main"),
            ("w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main"),
            ("strict", "http://purl.oclc.org/ooxml/wordprocessingml/main"),
        ] {
            let xml = """
                <\(prefix):document xmlns:\(prefix)="\(namespace)"><\(prefix):body>
                <\(prefix):p><\(prefix):r><\(prefix):t>第一章 雨</\(prefix):t></\(prefix):r></\(prefix):p>
                <\(prefix):p><\(prefix):r><\(prefix):t>林舟</\(prefix):t><\(prefix):tab/><\(prefix):t>走进书店。</\(prefix):t></\(prefix):r></\(prefix):p>
                <\(prefix):p><\(prefix):r><\(prefix):t>第二章 桥</\(prefix):t></\(prefix):r></\(prefix):p>
                <\(prefix):p><\(prefix):r><\(prefix):t>林舟&amp;苏禾。</\(prefix):t></\(prefix):r></\(prefix):p>
                </\(prefix):body></\(prefix):document>
                """
            let data = try archive(["word/document.xml": xml])
            let chapters = try DocumentReader.chapters(data: data, extension: "docx", title: "书")
            XCTAssertEqual(chapters.map(\.title), ["第一章 雨", "第二章 桥"], prefix)
            XCTAssertEqual(chapters.count, 2, prefix)
            XCTAssertTrue(chapters[0].text.contains("林舟\t走进书店。"), prefix)
            XCTAssertTrue(chapters[1].text.contains("林舟&苏禾。"), prefix)
        }
    }

    func testUnrelatedNamespaceCannotSupplyContainerRootfile() throws {
        let data = try archive([
            "META-INF/container.xml": """
                <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:other="urn:unrelated">
                <rootfiles><other:rootfile full-path="OPS/book.opf"/></rootfiles></container>
                """
        ])
        XCTAssertThrowsError(try DocumentReader.chapters(data: data, extension: "epub", title: "书")) { error in
            XCTAssertEqual(error.localizedDescription, "EPUB 缺少阅读顺序。")
        }
    }

    private func archive(_ files: [String: String]) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var entries: [String: URL] = [:]
        for (name, text) in files {
            let file = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            entries[name] = file
        }
        let destination = folder.appendingPathComponent("fixture.zip")
        try ZIPArchive.write(files: entries, to: destination)
        return try Data(contentsOf: destination)
    }
}
