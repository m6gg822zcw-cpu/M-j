import XCTest

@testable import MoxuCore

final class ImportTests: XCTestCase {
    func testResponsesNativeInputAndOutput() async throws {
        var api = APIProfile()
        api.kind = .responses
        api.model = "my-text-model"
        api.temperature = nil
        let request = try RequestBuilder.text(
            profile: api, token: "token", prompt: "林舟", images: [ReferenceImage(data: Data([0, 1]))])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(request.url.path, "/v1/responses")
        XCTAssertEqual(object["store"] as? Bool, false)
        XCTAssertNotNil(object["input"])
        XCTAssertNotNil(object["max_output_tokens"])
        XCTAssertNil(object["max_tokens"])
        let result = HTTPResult(
            data: Data(
                #"{"output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"分镜完成"}]}]}"#
                    .utf8))
        let client = ProviderClient(transport: MockTransport([result]))
        let text = try await client.complete(profile: api, token: "token", prompt: "林舟")
        XCTAssertEqual(text, "分镜完成")
    }
    func testChatReasoningTokenField() throws {
        var api = APIProfile()
        api.model = "my-text-model"
        api.textTokenField = "max_completion_tokens"
        api.temperature = nil
        let req = try RequestBuilder.text(profile: api, token: "", prompt: "test")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: req.body) as? [String: Any])
        XCTAssertNotNil(object["max_completion_tokens"])
        XCTAssertNil(object["max_tokens"])
        XCTAssertNil(object["temperature"])
    }
    func testChineseGB18030Decoding() throws {
        XCTAssertEqual(try ChapterParser.decode(Data([0xd6, 0xd0, 0xce, 0xc4])), "中文")
    }
    private func archive(_ files: [String: String]) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var map: [String: URL] = [:]
        for (name, text) in files {
            let file = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            map[name] = file
        }
        let out = folder.appendingPathComponent("out.zip")
        try ZIPArchive.write(files: map, to: out)
        return try Data(contentsOf: out)
    }
    func testDOCXParagraphsAndXMLText() throws {
        let zip = try archive([
            "word/document.xml":
                #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>第一章 雨</w:t></w:r></w:p><w:p><w:r><w:t>林舟&amp;苏禾。</w:t></w:r></w:p><w:p><w:r><w:t>第二章 桥</w:t></w:r></w:p><w:p><w:r><w:t>桥上见。</w:t></w:r></w:p></w:body></w:document>"#
        ])
        let chapters = try DocumentReader.chapters(data: zip, extension: "docx", title: "书")
        XCTAssertEqual(chapters.count, 2)
        XCTAssertTrue(chapters[0].text.contains("林舟&苏禾"))
        XCTAssertTrue(chapters[1].text.contains("桥上见"))
    }
    func testEPUBSpineOrderAndHeadMetadataExcluded() throws {
        let zip = try archive([
            "META-INF/container.xml":
                #"<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>"#,
            "OPS/book.opf":
                #"<package><manifest><item id="a" href="a.xhtml"/><item id="b" href="b.xhtml"/><item id="toc" href="toc.xhtml"/></manifest><spine><itemref idref="toc" linear="no"/><itemref idref="b"/><itemref idref="a"/></spine></package>"#,
            "OPS/a.xhtml":
                "<html><head><title>不应出现在正文的标题</title><style>p{color:red}</style></head><body><h1>第二章 归</h1><p>苏禾回家。</p></body></html>",
            "OPS/b.xhtml": "<html><head><title>元数据</title></head><body><h1>第一章 雨</h1><p>林舟出门。</p></body></html>",
            "OPS/toc.xhtml": "<html><body>不应出现的目录</body></html>",
        ])
        let chapters = try DocumentReader.chapters(data: zip, extension: "epub", title: "书")
        XCTAssertEqual(chapters.map(\.title), ["第一章 雨", "第二章 归"])
        XCTAssertTrue(chapters[0].text.contains("林舟出门"))
        XCTAssertFalse(chapters.map(\.text).joined().contains("元数据"))
        XCTAssertFalse(chapters.map(\.text).joined().contains("不应出现"))
    }
    func testCustomHeadingRegex() throws {
        let chapters = try ChapterParser.parse("【01】雨\n林舟。\n【02】桥\n苏禾。", title: "书", headingPattern: #"^【\d+】[^\n]+$"#)
        XCTAssertEqual(chapters.count, 2)
    }
    func testNAIAuditHidesSmallBase64Images() throws {
        var api = APIProfile()
        api.kind = .novelAI
        api.baseURL = api.kind.defaultBase
        api.model = "nai-diffusion-4-5-full"
        api.referenceMode = .precise
        let prompt = ComposedPrompt(
            natural: "人", naiBase: "1boy", negative: "", characters: [CharacterPrompt(prompt: "1boy")], fingerprint: "a"
        )
        let image = ReferenceImage(data: Data([0, 1, 2, 3]))
        let req = try RequestBuilder.image(profile: api, token: "secret", prompt: prompt, references: [image])
        XCTAssertFalse(req.redactedJSON.contains(image.data.base64EncodedString()))
        XCTAssertTrue(req.redactedJSON.contains("图片数据"))
    }
}
