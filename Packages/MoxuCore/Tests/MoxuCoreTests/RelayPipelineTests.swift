import XCTest
@testable import MoxuCore

private actor RelayPipelineTransport: HTTPTransport {
    private var calls: [PreparedRequest] = []
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jTlcAAAAASUVORK5CYII=")!
    func send(_ request: PreparedRequest) throws -> HTTPResult {
        calls.append(request)
        // A relay may use OpenAI response JSON even when it accepts an NAI request.
        return HTTPResult(data: try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()]]]))
    }
    func recorded() -> [PreparedRequest] { calls }
}

private actor RelayPipelineProcessor: ImageProcessor {
    private var kinds: [APIKind] = []
    func prepare(_ images: [ReferenceImage], profile: APIProfile) -> [ReferenceImage] {
        kinds.append(profile.kind)
        return images
    }
    func normalize(_ image: Data) -> Data { image }
    func recordedKinds() -> [APIKind] { kinds }
}

private struct RelayDecodeFailure: ImageProcessor {
    func prepare(_ images: [ReferenceImage], profile: APIProfile) async throws -> [ReferenceImage] { images }
    func normalize(_ image: Data) async throws -> Data { throw StudioError.invalid("模拟收到图片后解码中断") }
}

final class RelayPipelineTests: XCTestCase {
    private func fixture() async throws -> (Repository, Project, ChapterRun, PipelineConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelayPipeline-" + UUID().uuidString)
        let repo = Repository(root: root)
        try await repo.prepare()
        let chapters = try ChapterParser.parse("第一章\n林舟与苏禾站在书店。", title: "中转测试")
        var p = try await repo.importChapters(chapters, title: "中转测试", artistID: nil, chunk: 3000)
        p.characters = ["林舟", "苏禾"].map {
            CharacterCard(name: $0, stage: "成年", identity: ["hair": "黑发"], naiIdentity: "adult, black hair",
                          costumes: [Costume(layers: ["top": "衬衫"], naiLayers: ["top": "shirt"])])
        }
        var run = try await repo.chapter(p.id, ordinal: 1, chunk: 3000)
        run.doneBatches = run.batches.count
        run.planned = true
        run.panels = [ComicPanel(
            id: "P0001", units: run.units.map(\.id), scene: "S1", setting: "书店", action: "两人在书店站立",
            naiScene: "2people, bookstore, standing", cast: p.characters.map {
                PanelCast(characterID: $0.id, costumeKey: "daily-01", pose: "站立", expression: "平静",
                          position: "中间", visible: "全身", naiPose: "standing")
            })]
        try await repo.commit(p, run)
        var api = APIProfile()
        api.kind = .openAIImage
        api.baseURL = "https://relay.example.test/v1/images/generations"
        api.model = "nai-diffusion-4-5-full"
        api.steps = 21
        api.width = 1024
        api.height = 1536
        // The original OpenAI connection defaults to references; the NAI artist must use NAI rules.
        api.useImageReferences = true
        api.referenceMode = .off
        var artist = ArtistPreset()
        artist.imageRequestFormat = .novelAI
        artist.positive = "  {{artist:test}}\n1.2::linework::  "
        artist.negative = "bad hands, {{blur}}"
        let config = PipelineConfiguration(text: nil, image: api, vision: nil, artist: artist, chunk: 3000,
                                           textToken: "", imageToken: "TOKEN", visionToken: "", checkVision: false)
        return (repo, p, run, config)
    }

    func testArtistNAIFormatReachesPanelGenerationAndAvoidsExtraReferenceRequests() async throws {
        let (repo, project, run, config) = try await fixture()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let transport = RelayPipelineTransport()
        let processor = RelayPipelineProcessor()
        let pipeline = Pipeline(repository: repo, client: ProviderClient(transport: transport), processor: processor)
        let job = StudioJob(projectID: project.id, chapter: 1, scriptOnly: false)
        try await pipeline.run(job, config: config) { _ in }
        let calls = await transport.recorded()
        XCTAssertEqual(calls.count, 1, "NAI reference mode off must not generate extra charged reference sheets")
        let request = try XCTUnwrap(calls.first)
        XCTAssertEqual(request.url.absoluteString, config.image?.baseURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer TOKEN")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertNil(body["prompt"])
        XCTAssertEqual(body["action"] as? String, "generate")
        XCTAssertTrue((body["input"] as? String)?.contains(config.artist.positive) == true)
        let parameters = try XCTUnwrap(body["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["steps"] as? Int, 21)
        XCTAssertEqual(parameters["negative_prompt"] as? String, config.artist.negative)
        XCTAssertEqual((parameters["characterPrompts"] as? [[String: Any]])?.count, 2)
        let kinds = await processor.recordedKinds()
        XCTAssertEqual(kinds, [.novelAI])
        let saved = try await repo.chapter(project.id, ordinal: 1, chunk: 3000)
        let expected = try PromptComposer.compose(panel: run.panels[0], project: project,
                                                artist: config.artist, profile: try XCTUnwrap(config.image))
        XCTAssertEqual(saved.panels[0].fingerprint, expected.fingerprint)
        XCTAssertEqual(saved.panels[0].lastPrompt, expected.naiBase)
        XCTAssertNotNil(saved.panels[0].imageFile)
        // Resuming the same saved panel must not send a second paid POST.
        try await pipeline.run(job, config: config) { _ in }
        let afterResume = await transport.recorded()
        XCTAssertEqual(afterResume.count, 1)
    }

    func testArtistNAIFormatAlsoReachesReferenceSheetGeneration() async throws {
        let (repo, project, _, config) = try await fixture()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let transport = RelayPipelineTransport()
        let pipeline = Pipeline(repository: repo, client: ProviderClient(transport: transport), processor: RelayPipelineProcessor())
        var job = StudioJob(projectID: project.id, chapter: 1, scriptOnly: false)
        job.referenceCharacterID = project.characters[0].id
        try await pipeline.run(job, config: config) { _ in }
        let calls = await transport.recorded()
        XCTAssertEqual(calls.count, 1)
        let request = try XCTUnwrap(calls.first)
        XCTAssertEqual(request.url.absoluteString, config.image?.baseURL)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertNil(body["prompt"])
        XCTAssertTrue((body["input"] as? String)?.contains(project.characters[0].naiIdentity) == true)
        XCTAssertTrue((body["input"] as? String)?.contains(config.artist.positive) == true)
        let saved = try await repo.project(project.id)
        XCTAssertNotNil(saved.characters[0].referenceFile)
    }

    func testNAIRelayReceiptRecoveryDoesNotSendAnotherPaidRequest() async throws {
        let (repo, project, _, config) = try await fixture()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let transport = RelayPipelineTransport()
        let interrupted = Pipeline(repository: repo, client: ProviderClient(transport: transport), processor: RelayDecodeFailure())
        let job = StudioJob(projectID: project.id, chapter: 1, scriptOnly: false)
        do {
            try await interrupted.run(job, config: config) { _ in }
            XCTFail("应在接收并保存图片后模拟解码中断")
        } catch { XCTAssertTrue(error.localizedDescription.contains("解码中断")) }
        let interruptedReceipt = try await repo.receipt(project.id, chapter: 1)
        let receipt = try XCTUnwrap(interruptedReceipt)
        let resumed = Pipeline(repository: repo, client: ProviderClient(transport: transport), processor: RelayPipelineProcessor())
        try await resumed.run(job, config: config) { _ in }
        let calls = await transport.recorded()
        let saved = try await repo.chapter(project.id, ordinal: 1, chunk: 3000)
        let pending = try await repo.receipt(project.id, chapter: 1)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(saved.panels[0].imageFile, receipt.assetFile)
        XCTAssertEqual(saved.panels[0].fingerprint, receipt.fingerprint)
        XCTAssertEqual(saved.panels[0].lastPrompt, receipt.prompt)
        XCTAssertNil(pending)
    }
}
