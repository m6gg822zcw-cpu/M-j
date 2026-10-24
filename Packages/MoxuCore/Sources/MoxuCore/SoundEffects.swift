import Foundation

/// Display policy for an unsaved panel's sound effects. Never rewrites the source field or a saved lettering layer.
public enum SoundEffects {
    public static func displayText(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["音效：", "音效:", "拟声词：", "拟声词:", "sfx:", "sfx："] {
            if text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        let key = text.lowercased().components(separatedBy: separators).joined()
        guard !key.isEmpty, !placeholders.contains(key) else { return nil }
        if let sound = environmentalSounds[text.trimmingCharacters(in: separators)] { return sound }

        if isShortSoundText(text) { return text }

        // A legacy value may label an actual expression, e.g. “雨声：淅沥” or “淅沥（雨声）”.
        // Only keep independent sound expressions; never turn a fragment of descriptive prose into a sound.
        let fragments = text.components(separatedBy: labelBoundaries)
        guard fragments.count > 1 else { return nil }
        let sounds = fragments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(isShortSoundText)
        let result = sounds.joined(separator: " ")
        return result.isEmpty || result.count > 64 ? nil : result
    }

    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters).union(.symbols)
    private static let labelBoundaries = CharacterSet(charactersIn: ":：()（）[]【】;；")
    private static let placeholders: Set<String> = [
        "无", "没有", "无音效", "暂无", "暂无音效", "无需", "无需音效", "无拟声词", "无环境声", "无声", "静音", "静默", "安静",
        "环境声", "环境音", "环境音效", "背景声", "背景音", "音效", "拟声词", "待定",
        "none", "null", "nil", "na", "nosfx", "nosound", "silence", "silent", "ambient", "ambience",
        "ambientsound", "backgroundsound", "soundeffect", "soundeffects", "sfx", "tbd",
    ]
    // Exact names only: additional scene detail must not cause us to invent a sound.
    private static let environmentalSounds = [
        "雨声": "淅沥淅沥", "小雨声": "淅沥淅沥", "细雨声": "淅沥淅沥", "下雨声": "淅沥淅沥",
        "大雨声": "哗啦啦", "暴雨声": "哗啦啦", "雨滴声": "滴答", "水滴声": "滴答",
        "风声": "呼呼", "雷声": "轰隆", "流水声": "潺潺", "溪流声": "潺潺", "海浪声": "哗啦",
        "鸟鸣": "啾啾", "鸟鸣声": "啾啾", "虫鸣": "唧唧", "虫鸣声": "唧唧",
    ]
    private static let soundCharacters = Set(
        "哗啦沙咚砰嘭啪噼乒乓哐咣当叮铛铃轰隆咔喀嚓咯吱嘎嗒哒答滴嘀淅沥潺哧嗤呲呼呜嗖飕啾唧叽喳吼嗡嘶咝嘟扑噗卟咕噜汩哔啵怦嗵锵铿啷咻唰刷噌窸窣簌淙噔呱吁嘘哈呵嘿啊呀哇呃嗯嗷喵汪咩哞喔咳呕哼嘤啧嗝嗞滋叭嗙嘣"
    )
    private static let englishSounds: Set<String> = [
        "bang", "bam", "boom", "beep", "bzz", "buzz", "clang", "clank", "clatter", "clink", "click", "crack", "crash",
        "creak", "ding", "dong", "drip", "hiss", "knock", "plop", "pop", "pow", "pitter", "patter", "ring",
        "roar", "rumble", "rustle", "shh", "sizzle", "snap", "splat", "splash", "swish", "swoosh", "tap", "thud",
        "thump", "tick", "tock", "vroom", "wham", "whoosh", "woosh", "zap", "zip", "zzz",
    ]
    private static func isShortSoundText(_ text: String) -> Bool {
        let words = text.components(separatedBy: separators).filter { !$0.isEmpty }
        return text.count <= 64 && !words.isEmpty && words.allSatisfy(isSoundExpression)
    }
    private static func isSoundExpression(_ word: String) -> Bool {
        let lowercase = word.lowercased()
        if englishSounds.contains(lowercase) { return true }
        if lowercase.count <= 12,
            (lowercase.hasPrefix("sh") && lowercase.dropFirst().allSatisfy { $0 == "h" })
                || (lowercase.hasPrefix("zz") && lowercase.allSatisfy { $0 == "z" })
        { return true }
        var sound = word
        // Keep genuine expressions containing 声, e.g. “砰的一声”, instead of banning that character.
        for suffix in ["的一声", "地一声", "一声", "的声音", "声音", "声", "作响"] where sound.hasSuffix(suffix) {
            sound = String(sound.dropLast(suffix.count))
            break
        }
        if ["噼里啪啦", "噼哩啪啦", "叽里咕噜", "叽里呱啦"].contains(sound) { return true }
        return !sound.isEmpty && sound.allSatisfy { soundCharacters.contains($0) }
    }
}
