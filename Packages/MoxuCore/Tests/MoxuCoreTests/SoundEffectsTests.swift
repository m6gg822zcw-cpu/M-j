import XCTest

@testable import MoxuCore

final class SoundEffectsTests: XCTestCase {
    func testMetadataAndPlaceholdersAreNotComicText() {
        for raw in ["", " \n ", "环境声", "环境音效", "背景声", "无", "无音效", "（无）", "none", " NONE. ", "null", "N/A", "SFX: none"] {
            XCTAssertNil(SoundEffects.displayText(raw), raw)
        }
    }

    func testExactEnvironmentalNamesBecomeBriefSounds() {
        let examples = ["雨声": "淅沥淅沥", "（雨声）": "淅沥淅沥", "音效：雨声": "淅沥淅沥", "风声": "呼呼", "雷声": "轰隆", "水滴声": "滴答"]
        for (raw, expected) in examples {
            XCTAssertEqual(SoundEffects.displayText(raw), expected, raw)
        }
    }

    func testUnknownDescriptionsAreOmittedWithoutInventingSounds() {
        for raw in ["远处传来的雨声", "雨落在窗台上", "树叶摩擦的声音", "市场里的环境声", "低沉的机械运转", "远处汽车经过", "雨，声", "雨声：窗外持续下雨", "雨声（环境音）", "unknown ambient noise", "rain sound"] {
            XCTAssertNil(SoundEffects.displayText(raw), raw)
        }
    }

    func testLabeledSoundsKeepOnlyIndependentSoundExpressions() {
        let examples = [
            "雨声：淅沥": "淅沥", "淅沥（雨声）": "淅沥", "音效：雨声：淅沥淅沥": "淅沥淅沥",
            "咚咚（敲门声）": "咚咚", "远处的引擎：嗡嗡": "嗡嗡", "rain: drip": "drip",
            "雨声：淅沥；雷声：轰隆": "淅沥 轰隆",
        ]
        for (raw, expected) in examples {
            XCTAssertEqual(SoundEffects.displayText(raw), expected, raw)
        }
    }

    func testRealSoundExpressionsKeepTheirTextAndPunctuation() {
        for raw in ["哗啦", "咚咚", "沙沙", "滴答", "噼里啪啦", "窸窸窣窣", "咣当", "咣咣", "喀嚓", "砰！", "轰隆隆——", "咚！咚！", "砰的一声", "嗖地一声", "沙沙声", "咔嚓作响", "BANG!", "tick-tock", "knock knock", "SPLASH!", "clatter", "splat", "SHHH", "ZZZZ"] {
            XCTAssertEqual(SoundEffects.displayText(raw), raw, raw)
        }
    }

    func testLegacyDefaultsUseDisplayPolicyAndKeepOriginalFields() throws {
        let panel = makePanel(sfx: "雨声")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Codec.encode(panel)) as? [String: Any])
        object.removeValue(forKey: "lettering")
        let legacy = try Codec.decode(ComicPanel.self, JSONSerialization.data(withJSONObject: object))
        let before = try Codec.encode(legacy)
        let layout = LetteringDefaults.layout(for: legacy, imageAspect: 1)
        XCTAssertEqual(layout.bubbles.first { $0.sourceKey == "sfx" }?.text, "淅沥淅沥")
        XCTAssertEqual(legacy.sfx, "雨声")
        XCTAssertEqual(try Codec.encode(legacy), before)
        XCTAssertEqual(layout.bubbles.first { $0.sourceKey == "narration" }?.text, "窗外传来雨声。")
        XCTAssertEqual(layout.bubbles.first { $0.sourceKey == "dialogue:0" }?.text, "你听见雨声了吗？")
    }

    func testMetadataDoesNotCreateDefaultSoundBubble() {
        for raw in ["环境声", "无", "none", "远处的引擎声"] {
            let panel = makePanel(sfx: raw)
            let layout = LetteringDefaults.layout(for: panel, imageAspect: 1)
            XCTAssertFalse(layout.bubbles.contains { $0.sourceKey == "sfx" }, raw)
            XCTAssertEqual(panel.sfx, raw)
            XCTAssertEqual(layout.bubbles.count, 2)
        }
    }

    func testSavedManualSoundTextTakesPriorityOverDefaultPolicy() throws {
        var panel = makePanel(sfx: "环境声")
        let manual = ComicLettering(bubbles: [
            ComicBubble(id: "manual-sfx", sourceKey: "sfx", text: "雨声", style: .caption),
            ComicBubble(id: "manual-placeholder", text: "none", style: .caption),
        ])
        panel.lettering = manual
        let restored = try Codec.decode(ComicPanel.self, Codec.encode(panel))
        XCTAssertEqual(LetteringDefaults.layout(for: restored, imageAspect: 1), try manual.validated())
        XCTAssertEqual(restored.sfx, "环境声")
    }

    func testSavedEmptyLayerSuppressesAllDefaultsIncludingMappedRain() {
        var panel = makePanel(sfx: "雨声")
        panel.lettering = ComicLettering(bubbles: [])
        XCTAssertTrue(LetteringDefaults.layout(for: panel, imageAspect: 1).bubbles.isEmpty)
        XCTAssertEqual(panel.sfx, "雨声")
        XCTAssertEqual(panel.narration, "窗外传来雨声。")
        XCTAssertEqual(panel.dialogue.first?.text, "你听见雨声了吗？")
    }

    private func makePanel(sfx: String) -> ComicPanel {
        ComicPanel(
            id: "P0001", units: ["U00001"], scene: "S1", setting: "窗边", action: "看向窗外",
            dialogue: [Dialogue(speaker: "林舟", text: "你听见雨声了吗？")], narration: "窗外传来雨声。", sfx: sfx)
    }
}
