import XCTest

@testable import MoxuCore

private func letteredPanel() -> ComicPanel {
    var p = ComicPanel(
        id: "P0001", units: ["U00001"], scene: "S1", setting: "书店", action: "林舟问好",
        dialogue: [Dialogue(speaker: "林舟", text: "你也在这里。"), Dialogue(speaker: "苏禾", text: "我等了很久。", kind: "thought")],
        narration: "雨停之前。", sfx: "滴答")
    p.imageFile = "Images/original.png"
    p.fingerprint = "original-image-signature"
    p.review = .approved
    return p
}
private func seededLetteringRepository() async throws -> (Repository, Project, ChapterRun) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lettering-" + UUID().uuidString)
    let repo = Repository(root: root)
    try await repo.prepare()
    let raw = try ChapterParser.parse("第一章\n林舟问好。", title: "雨")
    let project = try await repo.importChapters(raw, title: "雨", artistID: nil, chunk: 3000)
    var run = try await repo.chapter(project.id, ordinal: 1, chunk: 3000)
    run.panels = [letteredPanel()]
    run.planned = true
    run.doneBatches = run.batches.count
    try await repo.saveAsset(project.id, path: "Images/original.png", data: Data([1, 2, 3, 4]))
    try await repo.commit(project, run)
    return (repo, project, run)
}
final class LetteringGeometryTests: XCTestCase {
    func testV10PanelWithoutLetteringDecodes() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Codec.encode(letteredPanel())) as? [String: Any])
        object.removeValue(forKey: "lettering")
        let old = try Codec.decode(ComicPanel.self, JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.lettering)
        XCTAssertEqual(old.dialogue[0].speaker, "林舟")
    }
    func testDefaultsKeepEverySourceAndStableIDs() {
        let p = letteredPanel()
        let a = LetteringDefaults.layout(for: p, imageAspect: 2.0 / 3.0)
        let b = LetteringDefaults.layout(for: p, imageAspect: 2.0 / 3.0)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.bubbles.count, 4)
        XCTAssertEqual(a.bubbles.map(\.sourceKey), ["narration", "dialogue:0", "dialogue:1", "sfx"])
        XCTAssertEqual(a.bubbles[2].style, .thought)
        XCTAssertEqual(a.bubbles[1].text, p.dialogue[0].text)
    }
    func testSavedEmptyLayerIntentionallySuppressesOriginalBubbles() {
        var p = letteredPanel()
        p.lettering = ComicLettering(bubbles: [])
        XCTAssertTrue(LetteringDefaults.layout(for: p, imageAspect: 1).bubbles.isEmpty)
        XCTAssertFalse(p.dialogue.isEmpty)
    }
    func testBadCoordinatesCannotEscapeCanvasOrCreateNaN() throws {
        let b = ComicBubble(
            text: "你好", frame: BubbleRect(x: .nan, y: -100, width: .infinity, height: 20),
            fontScale: .nan, tailTip: BubblePoint(x: 20, y: -5))
        let layer = try ComicLettering(bubbles: [b]).validated()
        let r = layer.bubbles[0].frame
        XCTAssertTrue(r.x.isFinite && r.y.isFinite && r.width.isFinite && r.height.isFinite)
        XCTAssertGreaterThanOrEqual(r.x, 0.01)
        XCTAssertGreaterThanOrEqual(r.y, 0.01)
        XCTAssertLessThanOrEqual(r.x + r.width, 0.990001)
        XCTAssertLessThanOrEqual(r.y + r.height, 0.990001)
        XCTAssertEqual(layer.bubbles[0].tailTip, BubblePoint(x: 1, y: 0))
        XCTAssertEqual(layer.bubbles[0].fontScale, 0.03)
    }
    func testDraggingBodyKeepsTailAtSpeakersMouth() {
        var b = ComicBubble(text: "你好", tailTip: BubblePoint(x: 0.7, y: 0.65))
        let tip = b.tailTip
        b.frame = b.frame.moved(dx: 0.2, dy: 0.3)
        XCTAssertEqual(b.tailTip, tip)
        XCTAssertEqual(b.frame.x, 0.24, accuracy: 0.0001)
        b.frame = b.frame.moved(dx: 100, dy: 100)
        XCTAssertLessThanOrEqual(b.frame.x + b.frame.width, 0.990001)
        XCTAssertLessThanOrEqual(b.frame.y + b.frame.height, 0.990001)
    }
    func testResizeDoesNotMoveTopLeftAndStaysInBounds() {
        let r = BubbleRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2)
        let big = r.resized(dw: 5, dh: 5)
        XCTAssertEqual(big.x, r.x, accuracy: 0.000001)
        XCTAssertEqual(big.y, r.y, accuracy: 0.000001)
        XCTAssertLessThanOrEqual(big.x + big.width, 0.990001)
        XCTAssertLessThanOrEqual(big.y + big.height, 0.990001)
        let tiny = r.resized(dw: -5, dh: -5)
        XCTAssertEqual(tiny.width, 0.12)
        XCTAssertEqual(tiny.height, 0.05)
    }
    func testRepeatedCornerResizesHaveNoInvalidClosedRange() {
        for index in 0...1000 {
            let r = BubbleRect(x: Double(index) / 1000, y: Double(index) / 1000, width: 0.12, height: 0.05).clamped()
            let result = r.resized(dw: 1, dh: 1).resized(dw: -1, dh: -1)
            XCTAssertTrue(result.x.isFinite && result.width >= 0.12 && result.height >= 0.05)
        }
    }
    func testTailChoosesCorrectEdgeAndDisappearsInsideBody() {
        let r = BubbleRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3)
        XCTAssertEqual(BubbleGeometry.attachment(frame: r, tip: BubblePoint(x: 0.4, y: 0))?.edge, .top)
        XCTAssertEqual(BubbleGeometry.attachment(frame: r, tip: BubblePoint(x: 0.4, y: 1))?.edge, .bottom)
        XCTAssertEqual(BubbleGeometry.attachment(frame: r, tip: BubblePoint(x: 0, y: 0.35))?.edge, .left)
        XCTAssertEqual(BubbleGeometry.attachment(frame: r, tip: BubblePoint(x: 1, y: 0.35))?.edge, .right)
        XCTAssertNil(BubbleGeometry.attachment(frame: r, tip: r.center))
    }
    func testHitTestingUsesTopmostVisibleBubble() {
        let a = ComicBubble(id: "a", text: "a")
        var b = ComicBubble(id: "b", text: "b")
        let point = BubblePoint(x: 0.2, y: 0.1)
        XCTAssertEqual(BubbleGeometry.hitTest(point, bubbles: [a, b]), "b")
        b.hidden = true
        XCTAssertEqual(BubbleGeometry.hitTest(point, bubbles: [a, b]), "a")
        XCTAssertNil(BubbleGeometry.hitTest(BubblePoint(x: 0.9, y: 0.9), bubbles: [a, b]))
    }
    func testDuplicateIDsAndUnsupportedLayerRejected() {
        let b = ComicBubble(id: "same", text: "你好")
        XCTAssertThrowsError(try ComicLettering(bubbles: [b, b]).validated())
        var future = ComicLettering(bubbles: [b])
        future.version = 2
        XCTAssertThrowsError(try future.validated())
    }
    func testRoundtripKeepsManualTextSizeTailOrderAndHiddenFlag() throws {
        var a = ComicBubble(
            id: "a", text: "手动更改的对白", speaker: "苏禾", frame: BubbleRect(x: 0.2, y: 0.3, width: 0.5, height: 0.25),
            style: .thought, fontScale: 0.045, tailTip: BubblePoint(x: 0.9, y: 0.8))
        a.hidden = true
        var layer = ComicLettering(bubbles: [a, ComicBubble(id: "b", text: "第二个")])
        layer.revision = 7
        XCTAssertEqual(try Codec.decode(ComicLettering.self, Codec.encode(layer)), layer)
    }
    func testLetteringChangeDoesNotInvalidateImagePrompt() throws {
        var p = letteredPanel()
        let project = Project(title: "书", chapters: [])
        var api = APIProfile()
        api.kind = .novelAI
        api.model = "nai-diffusion-4-5-full"
        let before = try PromptComposer.compose(panel: p, project: project, artist: ArtistPreset(), profile: api)
            .fingerprint
        var layer = LetteringDefaults.layout(for: p, imageAspect: 1)
        layer.bubbles[0].text = "仅本地排版改字"
        layer.bubbles[0].frame.x = 0.2
        p.lettering = layer
        let after = try PromptComposer.compose(panel: p, project: project, artist: ArtistPreset(), profile: api)
            .fingerprint
        XCTAssertEqual(before, after)
    }
}
final class LetteringPersistenceTests: XCTestCase {
    func testBundledOfflineDemoCanRestoreWithoutAPIs() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root = root.deletingLastPathComponent() }
        let fixture = root.appendingPathComponent("App/Resources/LetteringDemo.moxu")
        let repo = Repository(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.prepare()
        let p = try await repo.restoreProject(Data(contentsOf: fixture))
        let run = try await repo.chapter(p.id, ordinal: 1, chunk: 3000)
        XCTAssertTrue(p.title.contains("离线示例"))
        XCTAssertTrue(run.planned)
        XCTAssertEqual(run.panels[0].dialogue.count, 2)
        let bytes = try await repo.asset(p.id, path: try XCTUnwrap(run.panels[0].imageFile))
        XCTAssertTrue(ProviderClient.isImage(bytes))
        let settings = try await repo.settings()
        XCTAssertTrue(settings.profiles.isEmpty)
    }
    func testSavePreservesRawImageScriptReviewAndReceipt() async throws {
        let (repo, p, run) = try await seededLetteringRepository()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let panel = run.panels[0]
        let layer = LetteringDefaults.layout(for: panel, imageAspect: 1)
        let receipt = try await repo.beginReceipt(
            projectID: p.id, chapter: 1, target: "panel:other", fingerprint: "x", prompt: "", requestJSON: "{}")
        let saved = try await repo.saveLettering(
            p.id, chapter: 1, panelID: panel.id, lettering: layer, expectedImage: panel.imageFile!, expectedRevision: 0)
        XCTAssertEqual(saved.lettering?.revision, 1)
        XCTAssertEqual(saved.imageFile, panel.imageFile)
        XCTAssertEqual(saved.dialogue, panel.dialogue)
        XCTAssertEqual(saved.fingerprint, panel.fingerprint)
        XCTAssertEqual(saved.review, panel.review)
        let data = try await repo.asset(p.id, path: panel.imageFile!)
        let pending = try await repo.receipt(p.id, chapter: 1)
        XCTAssertEqual(data, Data([1, 2, 3, 4]))
        XCTAssertEqual(pending?.id, receipt.id)
    }
    func testConcurrentLetteringSaveRejectsStaleEditor() async throws {
        let (repo, p, run) = try await seededLetteringRepository()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let panel = run.panels[0]
        let layer = LetteringDefaults.layout(for: panel, imageAspect: 1)
        _ = try await repo.saveLettering(
            p.id, chapter: 1, panelID: panel.id, lettering: layer, expectedImage: panel.imageFile!, expectedRevision: 0)
        do {
            _ = try await repo.saveLettering(
                p.id, chapter: 1, panelID: panel.id, lettering: ComicLettering(bubbles: []),
                expectedImage: panel.imageFile!, expectedRevision: 0)
            XCTFail("应拒绝旧版本覆盖")
        } catch {}
        let saved = try await repo.chapter(p.id, ordinal: 1, chunk: 3000)
        XCTAssertEqual(saved.panels[0].lettering?.bubbles.count, layer.bubbles.count)
    }
    func testRedrawnImageRejectsOldCoordinatesSave() async throws {
        let (repo, p, varRun) = try await seededLetteringRepository()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        var run = varRun
        run.panels[0].imageFile = "Images/redrawn.png"
        try await repo.commit(p, run)
        do {
            _ = try await repo.saveLettering(
                p.id, chapter: 1, panelID: "P0001", lettering: ComicLettering(bubbles: []),
                expectedImage: "Images/original.png", expectedRevision: 0)
            XCTFail("应拒绝旧图编辑")
        } catch {}
        let saved = try await repo.chapter(p.id, ordinal: 1, chunk: 3000)
        XCTAssertNil(saved.panels[0].lettering)
    }
    func testPipelineCheckpointCannotEraseManualLayout() async throws {
        let (repo, p, stale) = try await seededLetteringRepository()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        var layer = LetteringDefaults.layout(for: stale.panels[0], imageAspect: 1)
        layer.bubbles[1].frame.x = 0.3
        layer.bubbles[1].tailTip = BubblePoint(x: 0.7, y: 0.6)
        let edited = try await repo.saveLettering(
            p.id, chapter: 1, panelID: "P0001", lettering: layer, expectedImage: "Images/original.png",
            expectedRevision: 0)
        var checkpoint = stale
        checkpoint.summary = "后续流水线保存"
        try await repo.commit(p, checkpoint)
        let saved = try await repo.chapter(p.id, ordinal: 1, chunk: 3000)
        XCTAssertEqual(saved.panels[0].lettering, edited.lettering)
        XCTAssertEqual(saved.summary, checkpoint.summary)
    }
    func testBackupRestoresManualLayerIncludingIntentionallyEmptyLayout() async throws {
        let (repo, p, _) = try await seededLetteringRepository()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let layer = ComicLettering(bubbles: [])
        let edited = try await repo.saveLettering(
            p.id, chapter: 1, panelID: "P0001", lettering: layer, expectedImage: "Images/original.png",
            expectedRevision: 0)
        let dest = repo.root.appendingPathComponent("edited.moxu")
        try await repo.exportProject(p.id, artist: ArtistPreset(), destination: dest)
        let restored = try await repo.restoreProject(Data(contentsOf: dest))
        let run = try await repo.chapter(restored.id, ordinal: 1, chunk: 3000)
        XCTAssertEqual(run.panels[0].lettering, edited.lettering)
        XCTAssertTrue(LetteringDefaults.layout(for: run.panels[0], imageAspect: 1).bubbles.isEmpty)
    }
}
