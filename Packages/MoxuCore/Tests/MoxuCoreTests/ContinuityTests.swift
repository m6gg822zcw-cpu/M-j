import XCTest

@testable import MoxuCore

final class ContinuityTests: XCTestCase {
    func testPronounAfterEmptyCutawayKeepsRecentLockedIdentity() throws {
        var p = Project(title: "雨夜", chapters: [])
        p.characters = [
            CharacterCard(
                name: "林舟", stage: "成年", identity: ["hair": "黑色短发"], naiIdentity: "locked_black_hair",
                costumes: [Costume()])
        ]
        let units = [SourceUnit(id: "U00002", text: "他听见雨声，推开门走了出去。")]
        var run = ChapterRun(ordinal: 1, title: "章", units: units, batches: [units.map(\.id)])
        run.summary = "林舟来到书店，随后镜头切到空无一人的窗外。"
        run.continuity.notes = "仍是同一场景。"
        let prompt = try PromptTemplates.planning(project: p, run: run, units: units, artist: ArtistPreset())
        XCTAssertTrue(prompt.contains("locked_black_hair"))
    }
}
