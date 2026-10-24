import Foundation

public struct CharacterPrompt: Equatable, Sendable {
    public var prompt: String, negative: String, x: Double, y: Double
    public init(prompt: String, negative: String = "", x: Double = 0.5, y: Double = 0.5) {
        self.prompt = prompt
        self.negative = negative
        self.x = x
        self.y = y
    }
}
public struct ComposedPrompt: Sendable {
    public var natural: String, naiBase: String, negative: String, characters: [CharacterPrompt], fingerprint: String
}
public enum PromptComposer {
    private static func join(_ values: [String], delimiter: String) -> String {
        values.filter { !$0.isEmpty }.joined(separator: delimiter)
    }
    public static func compose(panel: ComicPanel, project: Project, artist: ArtistPreset, profile: APIProfile) throws
        -> ComposedPrompt
    {
        var locked: [[String: Any]] = []
        var chars: [CharacterPrompt] = []
        for cast in panel.cast {
            guard let c = project.characters.first(where: { $0.id == cast.characterID }),
                let outfit = c.costumes.first(where: { $0.key == cast.costumeKey })
            else { throw StudioError.invalid("画格引用的人物或服装档案不存在。") }
            locked.append([
                "id": c.id.uuidString, "name": c.name, "stage": c.stage, "identity": c.identity,
                "costume": outfit.layers, "layerStates": cast.layerStates, "pose": cast.pose,
                "expression": cast.expression, "position": cast.position, "visible": cast.visible, "props": cast.props,
                "injuries": cast.injuries,
            ])
            let position = cast.position.lowercased()
            let x =
                position.contains("左") || position.contains("left")
                ? 0.2 : (position.contains("右") || position.contains("right") ? 0.8 : 0.5)
            let activeLayers = ["base", "top", "bottom", "outer", "footwear", "accessories"].compactMap {
                key -> String? in
                guard cast.layerStates[key] != "removed", let tag = outfit.naiLayers[key], !tag.isEmpty, tag != "none"
                else { return nil }
                let state = cast.layerStates[key] ?? "worn"
                return ["open", "torn", "wet", "loose"].contains(state) ? state + " " + tag : tag
            }.joined(separator: ", ")
            let characterFacts = join([c.naiIdentity, outfit.naiTags, activeLayers, cast.naiPose], delimiter: ", ")
            chars.append(
                CharacterPrompt(
                    prompt: join(
                        artist.placement == .beforeFacts
                            ? [artist.character, characterFacts] : [characterFacts, artist.character], delimiter: ", "),
                    x: x))
        }
        let identityJSON = String(
            data: try JSONSerialization.data(withJSONObject: locked, options: [.sortedKeys]), encoding: .utf8)!
        let facts =
            "绘制一格叙事漫画，不自行分格。\n剧情瞬间：\(panel.action)\n场景：\(panel.setting)\n时间：\(panel.time)\n镜头：\(panel.shot)，\(panel.camera)\n光照：\(panel.lighting)\n入镜主要人物：\(panel.cast.count)人。只画确实入镜者，不把被提及、通信或回忆中的人物加入现场。\n固定身份与服装分层：\(identityJSON)\n按人物编号分别匹配参考图，不交换脸型、头发、体型、衣服或左右手。定妆图里的基础衣装不覆盖剧情衣装。无文字、无对话框、无水印；中文由排版层添加。\n画风指导：\(artist.guidance)"
        let style = join(
            [
                artist.positive, artist.character, artist.background,
                artist.negative.isEmpty ? "" : "避免以下内容：\n" + artist.negative,
            ], delimiter: "\n")
        let natural =
            artist.placement == .beforeFacts
            ? join([style, facts], delimiter: "\n") : join([facts, style], delimiter: "\n")
        let sceneTags = join([panel.naiScene, artist.background], delimiter: ", ")
        let base =
            artist.placement == .beforeFacts
            ? join([artist.positive, sceneTags], delimiter: ", ") : join([sceneTags, artist.positive], delimiter: ", ")
        let references = panel.cast.compactMap { id in project.characters.first(where: { $0.id == id.characterID }) }
            .map { "\($0.id)/\($0.revision)/\($0.referenceFile ?? "")" }.joined(separator: "|")
        let effectiveProfile = try RequestBuilder.imageProfile(profile: profile, artist: artist)
        let profileData = String(data: try Codec.encode(effectiveProfile), encoding: .utf8)!
        let signature = StableID.digest(
            natural + base + artist.negative + chars.map(\.prompt).joined() + references + profileData)
        return ComposedPrompt(
            natural: natural, naiBase: base, negative: artist.negative, characters: chars, fingerprint: signature)
    }
}
