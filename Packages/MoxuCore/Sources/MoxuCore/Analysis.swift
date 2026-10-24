import Foundation

public struct CharacterDraft: Codable, Sendable {
    public var name: String, stage: String, aliases: [String], identity: [String: String], naiIdentity: String,
        designNotes: String
    public var explicitStage: Bool, evidence: [Evidence], costumes: [Costume]
}
public struct CastDraft: Codable, Sendable {
    public var name: String, stage: String, costumeKey: String, pose: String, expression: String, position: String,
        visible: String, props: String, injuries: String, naiPose: String
    public var layerStates: [String: String], presence: [Evidence], changes: [Evidence]
}
public struct PanelDraft: Codable, Sendable {
    public var units: [String], scene: String, setting: String, time: String, shot: String, camera: String,
        lighting: String, action: String, naiScene: String
    public var cast: [CastDraft], dialogue: [Dialogue], narration: String, sfx: String
}
public struct IdentityUpdate: Codable, Sendable {
    public var name: String, stage: String, field: String, value: String, evidence: [Evidence]
}
public struct AnalysisBatch: Codable, Sendable {
    public var characters: [CharacterDraft], panels: [PanelDraft], identityUpdates: [IdentityUpdate],
        relations: [RelationFact], summary: String
    public var scene: String, time: String, continuityNotes: String
}
public enum Analysis {
    public static func objectData(_ raw: String) throws -> Data {
        guard let first = raw.firstIndex(of: "{"), let last = raw.lastIndex(of: "}"), first <= last,
            let data = raw[first...last].data(using: .utf8)
        else { throw StudioError.invalid("文本模型没有返回 JSON 对象。") }
        return data
    }
    public static func decode(_ raw: String) throws -> AnalysisBatch {
        try JSONDecoder().decode(AnalysisBatch.self, from: objectData(raw))
    }
    private static func matches(_ c: CharacterCard, name: String, stage: String) -> Bool {
        c.stage == stage && ([c.name] + c.aliases).contains(name)
    }
    private static func proof(_ ev: [Evidence], _ units: [SourceUnit]) -> Bool {
        !ev.isEmpty
            && ev.allSatisfy { e in !e.quote.isEmpty && units.contains { $0.id == e.unit && $0.text.contains(e.quote) }
            }
    }
    public static func apply(_ d: AnalysisBatch, units: [SourceUnit], project: inout Project, run: inout ChapterRun)
        throws
    {
        guard !d.panels.isEmpty, d.panels.count <= 100, !d.summary.isEmpty else {
            throw StudioError.invalid("分镜缺失或超过单批100格。")
        }
        var p = project
        var r = run
        let known = Set(units.map(\.id))
        var covered = Set<String>()
        for c in d.characters {
            guard !c.name.isEmpty, !c.stage.isEmpty, !c.naiIdentity.isEmpty, proof(c.evidence, units),
                !c.costumes.isEmpty
            else { throw StudioError.invalid("新人物缺少固定外观、NAI身份标签、服装或原文证据。") }
            for outfit in c.costumes {
                guard
                    ["base", "top", "bottom", "outer", "footwear", "accessories"].allSatisfy({
                        outfit.layers[$0] != nil && outfit.naiLayers[$0] != nil
                    })
                else { throw StudioError.invalid("服装需完整中英文六层字段。") }
            }
            if let index = p.characters.firstIndex(where: { matches($0, name: c.name, stage: c.stage) }) {
                for (key, value) in c.identity where p.characters[index].identity[key] != value {
                    let conflict = AppearanceConflict(
                        characterID: p.characters[index].id, chapter: r.ordinal, field: key,
                        locked: p.characters[index].identity[key] ?? "", proposed: value, evidence: c.evidence)
                    if !p.conflicts.contains(where: {
                        $0.characterID == conflict.characterID && $0.field == key && $0.proposed == value
                    }) {
                        p.conflicts.append(conflict)
                    }
                }
                for outfit in c.costumes where !p.characters[index].costumes.contains(where: { $0.key == outfit.key }) {
                    p.characters[index].costumes.append(outfit)
                }
            } else {
                let related = p.characters.first { ([$0.name] + $0.aliases).contains(c.name) }
                guard related == nil || c.explicitStage else { throw StudioError.invalid("同一人物新增年龄/变身阶段需要原文明示证据。") }
                var card = CharacterCard(
                    name: c.name, stage: c.stage, identity: c.identity, naiIdentity: c.naiIdentity,
                    costumes: c.costumes, aliases: c.aliases, designNotes: c.designNotes, evidence: c.evidence)
                if let related { card.lineageID = related.lineageID }
                p.characters.append(card)
            }
        }
        for update in d.identityUpdates {
            guard let c = p.characters.first(where: { matches($0, name: update.name, stage: update.stage) }),
                proof(update.evidence, units)
            else { throw StudioError.invalid("身份补充缺少准确人物阶段和原文证据。") }
            if c.identity[update.field] != update.value,
                !p.conflicts.contains(where: {
                    $0.characterID == c.id && $0.field == update.field && $0.proposed == update.value
                })
            {
                p.conflicts.append(
                    AppearanceConflict(
                        characterID: c.id, chapter: r.ordinal, field: update.field,
                        locked: c.identity[update.field] ?? "", proposed: update.value, evidence: update.evidence))
            }
        }
        for draft in d.panels {
            guard !draft.units.isEmpty, Set(draft.units).isSubset(of: known), !draft.action.isEmpty,
                !draft.setting.isEmpty, !draft.naiScene.isEmpty, draft.dialogue.count <= 3,
                draft.dialogue.allSatisfy({
                    $0.text.count <= 64 && ["speech", "thought", "offscreen"].contains($0.kind)
                }), draft.narration.count <= 90
            else { throw StudioError.invalid("画格缺少有效原文、场景或英文NAI标签，或对白超长（最多3条，每条64字）。") }
            covered.formUnion(draft.units)
            let localUnits = units.filter { draft.units.contains($0.id) }
            var cast: [PanelCast] = []
            for entry in draft.cast {
                let candidates = p.characters.filter { matches($0, name: entry.name, stage: entry.stage) }
                guard candidates.count == 1, let c = candidates.first,
                    c.costumes.contains(where: { $0.key == entry.costumeKey }), proof(entry.presence, localUnits)
                else { throw StudioError.invalid("入镜人物、阶段或服装匹配失败，或缺少现场原文证据。") }
                guard
                    entry.layerStates.keys.allSatisfy({
                        ["base", "top", "bottom", "outer", "footwear", "accessories"].contains($0)
                    }),
                    entry.layerStates.values.allSatisfy({
                        ["worn", "open", "removed", "torn", "wet", "loose"].contains($0)
                    })
                else { throw StudioError.invalid("服装状态需使用 worn/open/removed/torn/wet/loose。") }
                let previous = r.continuity.castStates[c.id.uuidString] ?? [:]
                let changed = previous["costumeKey"].map { $0 != entry.costumeKey } ?? false
                // Compare each layer separately; no dictionary order or model wording changes the locked paper doll.
                let layerChanged = entry.layerStates.contains { key, value in
                    if let old = previous["layer." + key] { return old != value }
                    return false
                }
                if changed || layerChanged {
                    guard proof(entry.changes, localUnits) else { throw StudioError.invalid("服装穿脱/更换缺少本格原文依据。") }
                }
                var state = previous["costumeKey"] == entry.costumeKey ? previous : [:]
                state["costumeKey"] = entry.costumeKey
                for (key, value) in entry.layerStates { state["layer." + key] = value }
                state["props"] = entry.props
                state["injuries"] = entry.injuries
                r.continuity.castStates[c.id.uuidString] = state
                let states = Dictionary(
                    uniqueKeysWithValues: state.filter { $0.key.hasPrefix("layer.") }.map {
                        (String($0.key.dropFirst(6)), $0.value)
                    })
                cast.append(
                    PanelCast(
                        characterID: c.id, costumeKey: entry.costumeKey, pose: entry.pose, expression: entry.expression,
                        position: entry.position, visible: entry.visible, props: entry.props, injuries: entry.injuries,
                        naiPose: entry.naiPose, layerStates: states))
            }
            for dialogue in draft.dialogue where dialogue.kind == "speech" {
                guard draft.cast.contains(where: { $0.name == dialogue.speaker }) else {
                    throw StudioError.invalid("说话者不在镜头内时需标为 offscreen。")
                }
            }
            r.panels.append(
                ComicPanel(
                    id: String(format: "P%04d", r.panels.count + 1), units: draft.units, scene: draft.scene,
                    setting: draft.setting, time: draft.time, shot: draft.shot, camera: draft.camera,
                    lighting: draft.lighting, action: draft.action, naiScene: draft.naiScene, cast: cast,
                    dialogue: draft.dialogue, narration: draft.narration, sfx: draft.sfx))
        }
        guard covered == known else {
            throw StudioError.invalid("遗漏原文段落：\(known.subtracting(covered).sorted().joined(separator: "、"))。")
        }
        for fact in d.relations where proof([fact.evidence], units) {
            if !p.relations.contains(where: {
                $0.from == fact.from && $0.to == fact.to && $0.statement == fact.statement
            }) {
                p.relations.append(fact)
            }
        }
        let lastIDs = Set(r.panels.last?.cast.map { $0.characterID.uuidString } ?? [])
        for id in Array(r.continuity.castStates.keys) {
            r.continuity.castStates[id]?["active"] = lastIDs.contains(id) ? "true" : "false"
        }
        r.doneBatches += 1
        r.summary += "\n" + d.summary
        r.continuity.scene = d.scene
        r.continuity.time = d.time
        r.continuity.notes = d.continuityNotes
        project = p
        run = r
    }
}
