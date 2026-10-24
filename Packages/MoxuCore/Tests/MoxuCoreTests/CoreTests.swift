import XCTest

@testable import MoxuCore

private let png = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jTlcAAAAASUVORK5CYII=")!
private func imageProfile(_ kind: APIKind = .novelAI) -> APIProfile {
    var p = APIProfile()
    p.kind = kind
    p.baseURL = kind.defaultBase
    p.model = kind == .novelAI ? "nai-diffusion-4-5-full" : "image-test"
    return p
}
private func textProfile() -> APIProfile {
    var p = APIProfile()
    p.model = "text-test"
    return p
}
private func outfit() -> Costume {
    Costume(
        layers: ["base": "内层", "top": "蓝衫", "bottom": "长裤", "outer": "红外套", "footwear": "鞋", "accessories": "围巾"],
        naiLayers: [
            "base": "undershirt", "top": "blue shirt", "bottom": "long pants", "outer": "red coat", "footwear": "shoes",
            "accessories": "scarf",
        ])
}
private func character() -> CharacterCard {
    CharacterCard(
        name: "林舟", stage: "成年", identity: ["hair": "黑色短发", "face": "椭圆脸"],
        naiIdentity: "1boy, adult, black hair, short hair", costumes: [outfit()])
}
private func projectAndPanel() -> (Project, ComicPanel) {
    let c = character()
    var p = Project(title: "测试作品", chapters: [ChapterIndex(ordinal: 1, title: "第一章", characterCount: 10)])
    p.characters = [c]
    let cast = PanelCast(
        characterID: c.id, costumeKey: "daily-01", pose: "站立", expression: "微笑", position: "画面左侧", visible: "全身",
        naiPose: "standing, smile", layerStates: ["outer": "removed"])
    let panel = ComicPanel(
        id: "P0001", units: ["U00001"], scene: "S1", setting: "书店", action: "林舟站在门口",
        naiScene: "1boy, bookstore, standing", cast: [cast], dialogue: [Dialogue(speaker: "林舟", text: "走吧。")])
    return (p, panel)
}
private func temporary() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("MoxuTests-" + UUID().uuidString, isDirectory: true)
}
private func object(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
private func sampleBatch(units: [SourceUnit]) -> AnalysisBatch {
    let c = character()
    let proof = Evidence(unit: units[0].id, quote: "林舟")
    let draft = CharacterDraft(
        name: c.name, stage: c.stage, aliases: [], identity: c.identity, naiIdentity: c.naiIdentity, designNotes: "测试",
        explicitStage: false, evidence: [proof], costumes: c.costumes)
    let cast = CastDraft(
        name: c.name, stage: c.stage, costumeKey: "daily-01", pose: "站立", expression: "平静", position: "左",
        visible: "全身", props: "无", injuries: "无", naiPose: "standing", layerStates: [:], presence: [proof], changes: [])
    let panel = PanelDraft(
        units: units.map(\.id), scene: "S1", setting: "书店", time: "雨夜", shot: "中景", camera: "平视", lighting: "暖光",
        action: "林舟站在书店", naiScene: "1boy, bookstore, standing", cast: [cast], dialogue: [], narration: "", sfx: "")
    return AnalysisBatch(
        characters: [draft], panels: [panel], identityUpdates: [], relations: [], summary: "林舟来到书店。", scene: "S1",
        time: "雨夜", continuityNotes: "林舟在场。")
}

final class ChapterTests: XCTestCase {
    func testRepeatedHeadingsKeepIndependentChapters() throws {
        let c = try ChapterParser.parse("第一章 雨\n林舟。\n第一章 雨\n苏禾。", title: "作品")
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.map(\.text), ["林舟。\n", "苏禾。"])
    }
    func testFrontMatterAndEnglishHeadings() throws {
        let c = try ChapterParser.parse("作者说明\n\nChapter 1\nA\n\nChapter 2\nB", title: "Book")
        XCTAssertEqual(c.count, 3)
        XCTAssertTrue(c[0].title.contains("卷首"))
    }
    func testUnicodeOffsetsAndChunkCoverage() {
        let text = "👩🏽‍🎨林舟\n\n" + String(repeating: "雨", count: 2005)
        let units = ChapterParser.units(text)
        XCTAssertEqual(units.count, 4)
        for u in units {
            let actual = (text as NSString).substring(with: NSRange(location: u.utf16Start, length: u.text.utf16.count))
            XCTAssertEqual(actual, u.text)
            XCTAssertLessThanOrEqual(u.text.count, 1000)
        }
        let batches = ChapterParser.batches(units, limit: 1500)
        XCTAssertEqual(batches.flatMap { $0 }, units.map(\.id))
    }
    func testUTF16AndBOM() throws {
        let data = Data([0xff, 0xfe]) + Data("第一章\r\n林舟".utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
        XCTAssertEqual(try ChapterParser.decode(data), "第一章\n林舟")
    }
    func testJSONChapterVariants() throws {
        let data = Data(#"{"chapters":[{"title":"一","text":"林舟"},{"name":"二","content":"苏禾"}]}"#.utf8)
        XCTAssertEqual(try ChapterParser.jsonChapters(data).map(\.title), ["一", "二"])
    }
    func testEmptyAndInvalidSourcesRejected() {
        XCTAssertThrowsError(try ChapterParser.parse(" \n", title: "空"))
        XCTAssertThrowsError(try ChapterParser.jsonChapters(Data("[]".utf8)))
    }
}

final class PromptTests: XCTestCase {
    func testArtistStringsPreservedAndClothesRemoved() throws {
        let (p, panel) = projectAndPanel()
        var a = ArtistPreset()
        a.positive = "  {artist:a}, 1.25::artist:b::\n[artist:c]  "
        a.negative = "bad hands,  {{blur}}"
        a.character = "0.8::linework::"
        a.background = "fog, detailed background"
        let q = try PromptComposer.compose(panel: panel, project: p, artist: a, profile: imageProfile())
        XCTAssertTrue(q.naiBase.hasSuffix(a.positive))
        XCTAssertTrue(q.natural.contains(a.positive))
        XCTAssertEqual(q.negative, a.negative)
        XCTAssertTrue(q.natural.contains(a.negative))
        XCTAssertTrue(q.characters[0].prompt.contains(a.character))
        XCTAssertFalse(q.characters[0].prompt.contains("red coat"))
        XCTAssertTrue(q.characters[0].prompt.contains("blue shirt"))
        XCTAssertEqual(q.characters[0].x, 0.2)
        let run = ChapterRun(ordinal: 1, title: "章", units: [], batches: [[]])
        let planning = try PromptTemplates.planning(
            project: p, run: run, units: [SourceUnit(id: "U", text: "林舟")], artist: a)
        XCTAssertFalse(planning.contains(a.positive))
        XCTAssertFalse(planning.contains(a.negative))
    }
    func testFingerprintChangesWithReferenceAndLockedFace() throws {
        var (p, panel) = projectAndPanel()
        let a = ArtistPreset()
        let api = imageProfile()
        let first = try PromptComposer.compose(panel: panel, project: p, artist: a, profile: api).fingerprint
        p.characters[0].referenceFile = "Images/new.png"
        XCTAssertNotEqual(
            first, try PromptComposer.compose(panel: panel, project: p, artist: a, profile: api).fingerprint)
        p.characters[0].identity["hair"] = "银发"
        let q = try PromptComposer.compose(panel: panel, project: p, artist: a, profile: api)
        XCTAssertTrue(q.natural.contains("银发"))
        panel.cast[0].characterID = UUID()
        XCTAssertThrowsError(try PromptComposer.compose(panel: panel, project: p, artist: a, profile: api))
    }
    func testProfileDictionaryOrderingIsStable() throws {
        let (p, panel) = projectAndPanel()
        let a = ArtistPreset()
        var api = imageProfile()
        let first = try PromptComposer.compose(panel: panel, project: p, artist: a, profile: api).fingerprint
        let reloaded = try Codec.decode(APIProfile.self, Codec.encode(api))
        XCTAssertEqual(
            first, try PromptComposer.compose(panel: panel, project: p, artist: a, profile: reloaded).fingerprint)
        api.guidance = 6
        XCTAssertNotEqual(
            first, try PromptComposer.compose(panel: panel, project: p, artist: a, profile: api).fingerprint)
    }
}

final class RequestTests: XCTestCase {
    func testFullAndRootEndpointsDoNotDoubleAppend() throws {
        var p = textProfile()
        p.baseURL = "https://example.test/v1/chat/completions/"
        XCTAssertEqual(
            try RequestBuilder.endpoint(p, suffix: "chat/completions").absoluteString,
            "https://example.test/v1/chat/completions")
        p.kind = .geminiText
        p.baseURL = "https://example.test/v1beta/models/old:generateContent"
        XCTAssertEqual(
            try RequestBuilder.endpoint(p, suffix: "models/new:generateContent").path,
            "/v1beta/models/new:generateContent")
    }
    func testEndpointRequiresDeliberateHTTPAndNoInlineSecrets() throws {
        var p = textProfile()
        for bad in ["file:///tmp/key", "https://name:password@example.test/v1", "https://example.test?key=secret"] {
            p.baseURL = bad
            XCTAssertThrowsError(try RequestBuilder.endpoint(p, suffix: "models"))
        }
        p.baseURL = "http://192.168.1.2:8000/v1"
        XCTAssertThrowsError(try RequestBuilder.endpoint(p, suffix: "models"))
        p.allowHTTP = true
        XCTAssertEqual(try RequestBuilder.endpoint(p, suffix: "models").scheme, "http")
    }
    func testNAICharacterCaptionsAndVerbatimArtist() throws {
        let (p, panel) = projectAndPanel()
        var a = ArtistPreset()
        a.positive = "1.4::artist:one::, {{artist:two}}"
        let api = imageProfile()
        let q = try PromptComposer.compose(panel: panel, project: p, artist: a, profile: api)
        let request = try RequestBuilder.image(profile: api, token: "secret", prompt: q, references: [])
        let body = try object(request.body)
        let params = try XCTUnwrap(body["parameters"] as? [String: Any])
        let v4 = try XCTUnwrap(params["v4_prompt"] as? [String: Any])
        let caption = try XCTUnwrap(v4["caption"] as? [String: Any])
        XCTAssertEqual(body["input"] as? String, q.naiBase)
        XCTAssertTrue((body["input"] as? String)?.contains(a.positive) == true)
        XCTAssertEqual((caption["char_captions"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(params["qualityToggle"] as? Bool, false)
        XCTAssertFalse(request.redactedJSON.contains("secret"))
        XCTAssertEqual(request.headers["Authorization"], "Bearer secret")
    }
    func testNAIReferenceLimitAndExperimentalGuard() throws {
        let (p, panel) = projectAndPanel()
        var api = imageProfile()
        api.referenceMode = .precise
        let q = try PromptComposer.compose(panel: panel, project: p, artist: ArtistPreset(), profile: api)
        XCTAssertThrowsError(
            try RequestBuilder.image(
                profile: api, token: "", prompt: q, references: [ReferenceImage(data: png), ReferenceImage(data: png)]))
        api.model = "nai-diffusion-4-full"
        XCTAssertThrowsError(
            try RequestBuilder.image(profile: api, token: "", prompt: q, references: [ReferenceImage(data: png)]))
    }
    func testProtectedAdvancedFieldsRejected() throws {
        let (p, panel) = projectAndPanel()
        var api = imageProfile(.openAIImage)
        let q = try PromptComposer.compose(panel: panel, project: p, artist: ArtistPreset(), profile: api)
        api.extraJSON = #"{"prompt":"ignore locked face"}"#
        XCTAssertThrowsError(try RequestBuilder.image(profile: api, token: "", prompt: q, references: []))
        var text = textProfile()
        text.extraJSON = #"{"messages":[]}"#
        XCTAssertThrowsError(try RequestBuilder.text(profile: text, token: "", prompt: "a"))
    }
    func testImageEditUsesMultipartAndDedicatedEndpoint() throws {
        let (p, panel) = projectAndPanel()
        let api = imageProfile(.openAIImage)
        let q = try PromptComposer.compose(panel: panel, project: p, artist: ArtistPreset(), profile: api)
        let req = try RequestBuilder.image(
            profile: api, token: "x", prompt: q, references: [ReferenceImage(data: png, label: "林舟")])
        XCTAssertEqual(req.url.path, "/v1/images/edits")
        XCTAssertTrue(req.headers["Content-Type"]!.contains("multipart/form-data"))
        XCTAssertTrue(String(decoding: req.body, as: UTF8.self).contains("name=\"image[]\""))
        XCTAssertFalse(req.redactedJSON.contains(png.base64EncodedString()))
    }
    func testGeminiNativeAndAnthropicHeaders() throws {
        var p = textProfile()
        p.kind = .geminiText
        p.baseURL = p.kind.defaultBase
        let req = try RequestBuilder.text(profile: p, token: "test", prompt: "hi", images: [ReferenceImage(data: png)])
        XCTAssertEqual(req.headers["x-goog-api-key"], "test")
        XCTAssertTrue(req.url.path.hasSuffix("/models/text-test:generateContent"))
        XCTAssertNotNil(try object(req.body)["contents"])
        p.kind = .anthropic
        p.baseURL = p.kind.defaultBase
        XCTAssertEqual(
            try RequestBuilder.text(profile: p, token: "", prompt: "hi").headers["anthropic-version"], "2023-06-01")
    }
}

final class AnalysisTests: XCTestCase {
    let units = [SourceUnit(id: "U00001", text: "林舟站在书店。")]
    func testCoverageFailureRollsBackWholeBatch() throws {
        var d = sampleBatch(units: units)
        var p = Project(title: "作", chapters: [ChapterIndex(ordinal: 1, title: "章", characterCount: 10)])
        var r = ChapterRun(ordinal: 1, title: "章", units: units, batches: [units.map(\.id)])
        let beforeP = p
        let beforeR = r
        d.panels[0].units = ["unknown"]
        XCTAssertThrowsError(try Analysis.apply(d, units: units, project: &p, run: &r))
        XCTAssertEqual(p, beforeP)
        XCTAssertEqual(r, beforeR)
    }
    func testNoOmittedUnitsAndNoImaginedPresence() throws {
        let u = units + [SourceUnit(id: "U00002", text: "门外下雨。")]
        var d = sampleBatch(units: u)
        var p = Project(title: "作", chapters: [])
        var r = ChapterRun(ordinal: 1, title: "章", units: u, batches: [u.map(\.id)])
        d.panels[0].units = [u[0].id]
        XCTAssertThrowsError(try Analysis.apply(d, units: u, project: &p, run: &r))
        d = sampleBatch(units: u)
        d.panels[0].cast[0].presence = [Evidence(unit: u[0].id, quote: "并不存在的登场")]
        XCTAssertThrowsError(try Analysis.apply(d, units: u, project: &p, run: &r))
    }
    func testLockedIdentityConflictAndActiveContinuity() throws {
        var d = sampleBatch(units: units)
        var p = Project(title: "作", chapters: [])
        var r = ChapterRun(ordinal: 1, title: "章", units: units, batches: [units.map(\.id)])
        let c = character()
        p.characters = [c]
        d.characters[0].identity["hair"] = "银色长发"
        try Analysis.apply(d, units: units, project: &p, run: &r)
        XCTAssertEqual(p.characters[0].identity["hair"], "黑色短发")
        XCTAssertEqual(p.conflicts.count, 1)
        XCTAssertEqual(r.continuity.castStates[c.id.uuidString]?["active"], "true")
        XCTAssertEqual(r.doneBatches, 1)
    }
    func testNewStageNeedsEvidenceAndDoesNotReplaceOldFace() throws {
        var d = sampleBatch(units: units)
        var p = Project(title: "作", chapters: [])
        var r = ChapterRun(ordinal: 1, title: "章", units: units, batches: [units.map(\.id)])
        p.characters = [character()]
        d.characters[0].stage = "少年"
        d.panels[0].cast[0].stage = "少年"
        XCTAssertThrowsError(try Analysis.apply(d, units: units, project: &p, run: &r))
        d.characters[0].explicitStage = true
        try Analysis.apply(d, units: units, project: &p, run: &r)
        XCTAssertEqual(p.characters.count, 2)
        XCTAssertNotEqual(p.characters[0].id, p.characters[1].id)
        XCTAssertEqual(p.characters[0].lineageID, p.characters[1].lineageID)
    }
    func testWardrobeChangesNeedSourceProof() throws {
        var d = sampleBatch(units: units)
        var p = Project(title: "作", chapters: [])
        var r = ChapterRun(ordinal: 1, title: "章", units: units, batches: [units.map(\.id)])
        let c = character()
        p.characters = [c]
        r.continuity.castStates[c.id.uuidString] = ["costumeKey": "daily-01", "layer.outer": "worn"]
        d.panels[0].cast[0].layerStates = ["outer": "removed"]
        XCTAssertThrowsError(try Analysis.apply(d, units: units, project: &p, run: &r))
        d.panels[0].cast[0].changes = [Evidence(unit: units[0].id, quote: "林舟")]
        try Analysis.apply(d, units: units, project: &p, run: &r)
        XCTAssertEqual(r.panels[0].cast[0].layerStates["outer"], "removed")
    }
    func testSpeechMustBeInFrame() throws {
        var d = sampleBatch(units: units)
        var p = Project(title: "作", chapters: [])
        var r = ChapterRun(ordinal: 1, title: "章", units: units, batches: [units.map(\.id)])
        d.panels[0].dialogue = [Dialogue(speaker: "苏禾", text: "走吧")]
        XCTAssertThrowsError(try Analysis.apply(d, units: units, project: &p, run: &r))
        d.panels[0].dialogue[0].kind = "offscreen"
        try Analysis.apply(d, units: units, project: &p, run: &r)
    }
}

actor MockTransport: HTTPTransport {
    var requests: [PreparedRequest] = []
    var replies: [HTTPResult]
    init(_ replies: [HTTPResult]) { self.replies = replies }
    func send(_ request: PreparedRequest) async throws -> HTTPResult {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.timedOut) }
        return replies.removeFirst()
    }
    func recorded() -> [PreparedRequest] { requests }
}
private struct Passthrough: ImageProcessor {
    func prepare(_ images: [ReferenceImage], profile: APIProfile) async throws -> [ReferenceImage] { images }
    func normalize(_ image: Data) async throws -> Data { image }
}
private struct FailedDecode: ImageProcessor {
    func prepare(_ images: [ReferenceImage], profile: APIProfile) async throws -> [ReferenceImage] { images }
    func normalize(_ image: Data) async throws -> Data { throw StudioError.invalid("模拟图片解码中断") }
}

final class PersistenceAndPipelineTests: XCTestCase {
    private func seeded() async throws -> (Repository, Project, ChapterRun) {
        let repo = Repository(root: temporary())
        try await repo.prepare()
        let chapters = try ChapterParser.parse("第一章\n林舟站在书店。\n第二章\n林舟离开。", title: "测试")
        let p = try await repo.importChapters(chapters, title: "测试", artistID: nil, chunk: 3000)
        let r = try await repo.chapter(p.id, ordinal: 1, chunk: 3000)
        return (repo, p, r)
    }
    private func configuration(image: APIProfile? = nil) -> PipelineConfiguration {
        PipelineConfiguration(
            text: nil, image: image, vision: nil, artist: ArtistPreset(), chunk: 3000, textToken: "", imageToken: "",
            visionToken: "", checkVision: false)
    }
    func testBackupRestoresSourceAndArtistWithoutAPISecrets() async throws {
        let (repo, p, _) = try await seeded()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        var settings = try await repo.settings()
        var api = textProfile()
        api.extraJSON = "{}"
        settings.profiles = [api]
        try await repo.saveSettings(settings)
        var a = ArtistPreset()
        a.positive = "{{artist:test}}\n line"
        let dest = repo.root.appendingPathComponent("test.moxu")
        try await repo.exportProject(p.id, artist: a, destination: dest)
        let data = try Data(contentsOf: dest)
        let zip = try ZIPArchive(data: data)
        XCTAssertTrue(zip.entries.contains { $0.name == "Chapters/1-source.json" })
        XCTAssertTrue(zip.entries.contains { $0.name == "Artist.json" })
        XCTAssertFalse(
            zip.entries.contains {
                $0.name.contains("Settings") || $0.name.contains("Jobs") || $0.name.contains("Receipts")
            })
        let restored = try await repo.restoreProject(data)
        XCTAssertNotEqual(restored.id, p.id)
        XCTAssertEqual(restored.artistID, a.id)
        let run = try await repo.chapter(restored.id, ordinal: 1, chunk: 3000)
        XCTAssertEqual(run.units[0].text, "林舟站在书店。")
    }
    func testBackupUsesCanonicalProjectDirectoryAndRelativeEntryNames() async throws {
        let (repo, p, _) = try await seeded()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.saveAsset(p.id, path: "Images/original.png", data: png)
        _ = try await repo.beginReceipt(
            projectID: p.id, chapter: 1, target: "panel:P0001", fingerprint: "x", prompt: "",
            requestJSON: "private request")
        try Data("private journal".utf8).write(to: await repo.file(p.id, "Journal.json"))
        let folder = await repo.folder(p.id)
        let relocated = repo.root.appendingPathComponent("重定位 project", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: relocated)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: relocated)
        let destination = repo.root.appendingPathComponent("canonical.moxu")
        try await repo.exportProject(p.id, artist: ArtistPreset(), destination: destination)
        let data = try Data(contentsOf: destination)
        let zip = try ZIPArchive(data: data)
        XCTAssertEqual(
            Set(zip.entries.map(\.name)),
            ["Project.json", "Artist.json", "Chapters/1-source.json", "Chapters/2-source.json", "Images/original.png"])
        let restored = try await repo.restoreProject(data)
        let run = try await repo.chapter(restored.id, ordinal: 1, chunk: 3000)
        let image = try await repo.asset(restored.id, path: "Images/original.png")
        XCTAssertEqual(run.units[0].text, "林舟站在书店。")
        XCTAssertEqual(image, png)
    }
    func testPastMemoryNeverReadsFutureAndJournalRecovers() async throws {
        let (repo, p, varRun) = try await seeded()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        var r = varRun
        r.memoryAfter = "过去的融合记忆"
        r.planned = true
        try await repo.commit(p, r)
        var second = try await repo.chapter(p.id, ordinal: 2, chunk: 3000)
        XCTAssertEqual(second.memoryBefore, r.memoryAfter)
        second.memoryAfter = "未来章节"
        try await repo.commit(p, second)
        let first = try await repo.chapter(p.id, ordinal: 1, chunk: 3000)
        XCTAssertEqual(first.memoryBefore, "")
        r.memoryAfter = "事务恢复成功"
        let journal: [String: Any] = ["project": try object(Codec.encode(p)), "chapter": try object(Codec.encode(r))]
        let path = try await repo.file(p.id, "Journal.json")
        try JSONSerialization.data(withJSONObject: journal).write(to: path)
        _ = try await repo.list()
        let recovered = try await repo.chapter(p.id, ordinal: 1, chunk: 3000)
        XCTAssertEqual(recovered.memoryAfter, "事务恢复成功")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testUnknownImageRequestDoesNotAutomaticallyChargeAgain() async throws {
        let (repo, p, varRun) = try await seeded()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        var r = varRun
        r.planned = true
        r.doneBatches = r.batches.count
        try await repo.commit(p, r)
        _ = try await repo.beginReceipt(
            projectID: p.id, chapter: 1, target: "panel:P0001", fingerprint: "old", prompt: "", requestJSON: "{}")
        let mock = MockTransport([])
        let pipeline = Pipeline(repository: repo, client: ProviderClient(transport: mock), processor: Passthrough())
        do {
            try await pipeline.run(
                StudioJob(projectID: p.id, chapter: 1, scriptOnly: false), config: configuration(image: imageProfile())
            ) { _ in }
            XCTFail("未拦截不确定请求")
        } catch { XCTAssertTrue(error.localizedDescription.contains("结果不确定")) }
        let requests = await mock.recorded()
        XCTAssertEqual(requests.count, 0)
    }
    func testSavedReceiptRecoversWithoutTextAPIOrImageCharge() async throws {
        let (repo, varP, varRun) = try await seeded()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        var p = varP
        var r = varRun
        let (fixture, panel) = projectAndPanel()
        p.characters = fixture.characters
        r.panels = [panel]
        r.planned = true
        r.doneBatches = r.batches.count
        let api = imageProfile()
        let cfg = configuration(image: api)
        let prompt = try PromptComposer.compose(panel: panel, project: p, artist: cfg.artist, profile: api)
        let receipt = try await repo.beginReceipt(
            projectID: p.id, chapter: 1, target: "panel:" + panel.id, fingerprint: prompt.fingerprint,
            prompt: prompt.naiBase, requestJSON: "{}")
        try await repo.saveAsset(p.id, path: receipt.assetFile, data: png)
        try await repo.commit(p, r)
        let mock = MockTransport([])
        let pipeline = Pipeline(repository: repo, client: ProviderClient(transport: mock), processor: Passthrough())
        var job = StudioJob(projectID: p.id, chapter: 1, scriptOnly: false)
        job.panelID = panel.id
        try await pipeline.run(job, config: cfg) { _ in }
        let output = try await repo.chapter(p.id, ordinal: 1, chunk: 3000)
        let requests = await mock.recorded()
        let pending = try await repo.receipt(p.id, chapter: 1)
        XCTAssertEqual(output.panels[0].imageFile, receipt.assetFile)
        XCTAssertEqual(requests.count, 0)
        XCTAssertNil(pending)
    }
    func testPaidImageSavedBeforeNormalizationFailure() async throws {
        let (repo, varP, varRun) = try await seeded()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        var p = varP
        var r = varRun
        let (fixture, panel) = projectAndPanel()
        p.characters = fixture.characters
        r.panels = [panel]
        r.planned = true
        r.doneBatches = r.batches.count
        try await repo.commit(p, r)
        let mock = MockTransport([HTTPResult(data: png)])
        let pipeline = Pipeline(repository: repo, client: ProviderClient(transport: mock), processor: FailedDecode())
        do {
            try await pipeline.run(
                StudioJob(projectID: p.id, chapter: 1, scriptOnly: false), config: configuration(image: imageProfile())
            ) { _ in }
            XCTFail("应模拟解码失败")
        } catch {}
        let receipt = try await repo.receipt(p.id, chapter: 1)
        XCTAssertNotNil(receipt)
        let data = try await repo.asset(p.id, path: receipt!.assetFile)
        XCTAssertEqual(data, png)
        let requests = await mock.recorded()
        XCTAssertEqual(requests.count, 1)
    }
    func testPathTraversalRejected() async throws {
        let (repo, p, _) = try await seeded()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        do {
            _ = try await repo.file(p.id, "../../Settings.json")
            XCTFail("路径越界")
        } catch {}
    }
}

final class ZIPAndClientTests: XCTestCase {
    func testStoredZIPRoundtripAndCRCValidation() throws {
        let folder = temporary()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("a.png")
        let out = folder.appendingPathComponent("out.zip")
        try png.write(to: image)
        try ZIPArchive.write(files: ["dir/a.png": image], to: out)
        var bytes = try Data(contentsOf: out)
        let zip = try ZIPArchive(data: bytes)
        XCTAssertEqual(try zip.firstImage(), png)
        bytes[40] ^= 1
        XCTAssertThrowsError(try ZIPArchive(data: bytes).firstImage())
    }
    func testCompressedZIPFixture() throws {
        let base64 =
            "UEsDBBQAAAAIAEkuWF3kYh1GEgAAAA8AAAAJAAAAaGVsbG8udHh0ezZv+ouO+U929L3o7n++bB8AUEsBAhQDFAAAAAgASS5YXeRiHUYSAAAADwAAAAkAAAAAAAAAAAAAAIABAAAAAGhlbGxvLnR4dFBLBQYAAAAAAQABADcAAAA5AAAAAAA="
        let zip = try ZIPArchive(data: XCTUnwrap(Data(base64Encoded: base64)))
        XCTAssertEqual(String(data: try zip.read("hello.txt"), encoding: .utf8), "林舟与苏禾")
    }
    func testTextResponseProtocolsAndPublicImageDownloadWithoutKey() async throws {
        let replies = [
            HTTPResult(data: Data(#"{"choices":[{"message":{"content":"完成"}}]}"#.utf8)),
            HTTPResult(data: Data(#"{"data":[{"url":"https://cdn.example.test/image.png"}]}"#.utf8)),
            HTTPResult(data: png),
        ]
        let mock = MockTransport(replies)
        let client = ProviderClient(transport: mock)
        let text = try await client.complete(profile: textProfile(), token: "SECRET", prompt: "test")
        XCTAssertEqual(text, "完成")
        let api = imageProfile(.openAIImage)
        let prompt = ComposedPrompt(natural: "test", naiBase: "", negative: "", characters: [], fingerprint: "a")
        let req = try RequestBuilder.image(profile: api, token: "SECRET", prompt: prompt, references: [])
        let generated = try await client.generate(req, profile: api)
        XCTAssertEqual(generated, png)
        let calls = await mock.recorded()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[2].method, "GET")
        XCTAssertTrue(calls[2].headers.isEmpty)
    }
    func testEmptyImageAndHTTPFailure() async throws {
        let api = imageProfile()
        let request = PreparedRequest(
            url: URL(string: "https://example.test")!, headers: [:], body: Data(), redactedJSON: "{}")
        let client = ProviderClient(
            transport: MockTransport([HTTPResult(data: Data("{}".utf8)), HTTPResult(data: Data(), status: 401)]))
        do {
            _ = try await client.generate(request, profile: api)
            XCTFail()
        } catch {}
        do {
            _ = try await client.generate(request, profile: api)
            XCTFail()
        } catch { XCTAssertTrue(error.localizedDescription.contains("401")) }
    }
}
