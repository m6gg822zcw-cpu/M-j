import Foundation

public enum StudioError: Error, LocalizedError {
    case invalid(String)
    case http(Int)
    case emptyResponse
    case uncertainRequest(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let s): return s
        case .http(let code): return "服务返回 HTTP \(code)，请检查地址、模型、额度与密钥。"
        case .emptyResponse: return "服务没有返回可用内容。"
        case .uncertainRequest(let s): return "上次图片请求结果不确定（\(s)）。先检查平台任务记录，再选择是否重试。"
        }
    }
}
public enum APIKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat, responses, anthropic, geminiText, novelAI, openAIImage, geminiImage
    public var id: String { rawValue }
    public var isText: Bool { [.chat, .responses, .anthropic, .geminiText].contains(self) }
    public var title: String {
        switch self {
        case .chat: return "OpenAI 兼容文本"
        case .responses: return "OpenAI Responses 文本"
        case .anthropic: return "Anthropic 文本"
        case .geminiText: return "Gemini 文本"
        case .novelAI: return "NovelAI 官方生图"
        case .openAIImage: return "OpenAI 兼容生图"
        case .geminiImage: return "Gemini 生图"
        }
    }
    public var defaultBase: String {
        switch self {
        case .chat, .responses, .openAIImage: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .geminiText, .geminiImage: return "https://generativelanguage.googleapis.com/v1beta"
        case .novelAI: return "https://image.novelai.net"
        }
    }
}
public struct APIProfile: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String = "新连接"
    public var kind: APIKind = .chat
    public var baseURL = "https://api.openai.com/v1"
    public var model = ""
    public var editURL = ""
    public var imageEndpointOverride: String? = nil
    public var artistPresetID: UUID? = nil
    public var width = 1024, height = 1024, steps = 28
    public var guidance = 5.0
    public var sampler = "k_euler_ancestral"
    public var noiseSchedule = "karras"
    public var seed: UInt32? = nil
    public var referenceMode: ReferenceMode = .off
    public var referenceStrength = 0.8
    public var referenceFidelity = 0.6
    public var maxReferences = 4
    public var useImageReferences = true
    public var extraJSON = "{}"
    public var allowHTTP = false
    public var textMaxTokens = 16000
    public var textTokenField = "max_tokens"
    public var temperature: Double? = 0.3
    public init() {}
    public enum ReferenceMode: String, Codable, CaseIterable, Sendable { case off, precise, imageToImage }
}
public enum ArtistPlacement: String, Codable, CaseIterable, Sendable { case afterFacts, beforeFacts }
public enum ArtistImageRequestFormat: String, Codable, CaseIterable, Sendable { case connection, novelAI }
public struct ArtistPreset: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = "我的画师串"
    public var positive = "", negative = "", character = "", background = ""
    public var guidance = "清晰的漫画线条，统一的上色、材质与人物比例。"
    public var placement: ArtistPlacement = .afterFacts
    public var imageRequestFormat: ArtistImageRequestFormat? = nil
    public var revision = 1
    public init() {}
}
public struct AppSettings: Codable, Equatable, Sendable {
    public var profiles: [APIProfile] = []
    public var artists: [ArtistPreset] = [ArtistPreset()]
    public var textProfileID: UUID?, imageProfileID: UUID?, visionProfileID: UUID?
    public var chunkCharacters = 3000
    public var headingPattern = ""
    public var performVisionCheck = false
    public init() {}
}
public struct SourceUnit: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var utf16Start: Int
    public init(id: String, text: String, utf16Start: Int = 0) {
        self.id = id
        self.text = text
        self.utf16Start = utf16Start
    }
}
public struct RawChapter: Equatable, Sendable {
    public var title: String
    public var text: String
    public var sourceStart: Int
}
public struct ChapterIndex: Codable, Identifiable, Equatable, Sendable {
    public var id: Int { ordinal }
    public var ordinal: Int, title: String, characterCount: Int
    public var completedPanels = 0, totalPanels = 0, planned = false
    public init(ordinal: Int, title: String, characterCount: Int) {
        self.ordinal = ordinal
        self.title = title
        self.characterCount = characterCount
    }
}
public struct Evidence: Codable, Equatable, Sendable {
    public var unit: String, quote: String
    public init(unit: String, quote: String) {
        self.unit = unit
        self.quote = quote
    }
}
public struct Costume: Codable, Identifiable, Equatable, Sendable {
    public var id: String { key }
    public var key: String, name: String, layers: [String: String], naiLayers: [String: String], naiTags: String
    public init(
        key: String = "daily-01", name: String = "初始衣装", layers: [String: String] = [:],
        naiLayers: [String: String] = [:], naiTags: String = ""
    ) {
        self.key = key
        self.name = name
        self.layers = layers
        self.naiLayers = naiLayers
        self.naiTags = naiTags
    }
}
public struct CharacterCard: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID(), lineageID = UUID()
    public var name: String, stage: String, aliases: [String], identity: [String: String], naiIdentity: String,
        designNotes: String
    public var evidence: [Evidence], costumes: [Costume]
    public var revision = 1
    public var referenceFile: String? = nil
    public init(
        name: String, stage: String, identity: [String: String], naiIdentity: String, costumes: [Costume],
        aliases: [String] = [], designNotes: String = "", evidence: [Evidence] = []
    ) {
        self.name = name
        self.stage = stage
        self.identity = identity
        self.naiIdentity = naiIdentity
        self.costumes = costumes
        self.aliases = aliases
        self.designNotes = designNotes
        self.evidence = evidence
        self.lineageID = self.id
    }
}
public struct AppearanceConflict: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var characterID: UUID, chapter: Int, field: String, locked: String, proposed: String
    public var evidence: [Evidence]
}
public struct RelationFact: Codable, Equatable, Sendable {
    public var from: String, to: String, statement: String, evidence: Evidence
}
public struct PanelCast: Codable, Equatable, Sendable {
    public var characterID: UUID
    public var costumeKey: String
    public var pose: String, expression: String, position: String, visible: String, props: String, injuries: String,
        naiPose: String
    public var layerStates: [String: String]
    public init(
        characterID: UUID, costumeKey: String, pose: String, expression: String, position: String, visible: String,
        props: String = "", injuries: String = "", naiPose: String = "", layerStates: [String: String] = [:]
    ) {
        self.characterID = characterID
        self.costumeKey = costumeKey
        self.pose = pose
        self.expression = expression
        self.position = position
        self.visible = visible
        self.props = props
        self.injuries = injuries
        self.naiPose = naiPose
        self.layerStates = layerStates
    }
}
public struct Dialogue: Codable, Equatable, Sendable {
    public var speaker: String, text: String, kind: String
    public init(speaker: String, text: String, kind: String = "speech") {
        self.speaker = speaker
        self.text = text
        self.kind = kind
    }
}
public enum ReviewState: String, Codable, Sendable { case notGenerated, pending, approved, mismatch, assistedPass }
public struct ComicPanel: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var units: [String], scene: String, setting: String, time: String, shot: String, camera: String,
        lighting: String, action: String
    public var naiScene: String
    public var cast: [PanelCast], dialogue: [Dialogue], narration: String, sfx: String
    public var imageFile: String? = nil
    public var fingerprint = "", lastPrompt = "", requestJSON = "", reviewNotes = ""
    public var review: ReviewState = .notGenerated
    /// Optional for v1.0 backups. A saved empty layer means intentionally no lettering.
    public var lettering: ComicLettering? = nil
    public init(
        id: String, units: [String], scene: String, setting: String, time: String = "", shot: String = "中景",
        camera: String = "平视", lighting: String = "", action: String, naiScene: String = "", cast: [PanelCast] = [],
        dialogue: [Dialogue] = [], narration: String = "", sfx: String = ""
    ) {
        self.id = id
        self.units = units
        self.scene = scene
        self.setting = setting
        self.time = time
        self.shot = shot
        self.camera = camera
        self.lighting = lighting
        self.action = action
        self.naiScene = naiScene
        self.cast = cast
        self.dialogue = dialogue
        self.narration = narration
        self.sfx = sfx
    }
}
public struct Continuity: Codable, Equatable, Sendable {
    public var scene = "", time = "", notes = ""
    public var castStates: [String: [String: String]] = [:]
    public init() {}
}
public struct ChapterRun: Codable, Equatable, Sendable {
    public var ordinal: Int, title: String, units: [SourceUnit], batches: [[String]]
    public var doneBatches = 0
    public var panels: [ComicPanel] = []
    public var summary = "", memoryBefore = "", memoryAfter = ""
    public var continuity = Continuity()
    public var planned = false
    public init(ordinal: Int, title: String, units: [SourceUnit], batches: [[String]]) {
        self.ordinal = ordinal
        self.title = title
        self.units = units
        self.batches = batches
    }
}
public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title: String, chapters: [ChapterIndex]
    public var characters: [CharacterCard] = [], conflicts: [AppearanceConflict] = [], relations: [RelationFact] = []
    public var artistID: UUID?
    public var created = Date(), updated = Date()
    public init(title: String, chapters: [ChapterIndex], artistID: UUID? = nil) {
        self.title = title
        self.chapters = chapters
        self.artistID = artistID
    }
}
public struct ProjectSummary: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID, title: String, chapterCount: Int, drawn: Int, characters: Int, updated: Date
    public init(_ p: Project) {
        id = p.id
        title = p.title
        chapterCount = p.chapters.count
        drawn = p.chapters.reduce(0) { $0 + $1.completedPanels }
        characters = p.characters.count
        updated = p.updated
    }
}
public enum JobState: String, Codable, Sendable { case queued, running, paused, finished, failed, needsReview }
public struct StudioJob: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID(), projectID: UUID
    public var chapter: Int, scriptOnly: Bool
    public var referenceCharacterID: UUID? = nil
    public var panelID: String? = nil
    public var state: JobState = .queued
    public var progress = 0.0, message = "等待制作"
    public var retryAuthorized = false
    public var created = Date()
    public init(projectID: UUID, chapter: Int, scriptOnly: Bool) {
        self.projectID = projectID
        self.chapter = chapter
        self.scriptOnly = scriptOnly
    }
}
public struct ImageReceipt: Codable, Sendable {
    public var id: UUID, projectID: UUID, chapter: Int, target: String, fingerprint: String, prompt: String,
        requestJSON: String
    public var assetFile: String, created: Date
}
public struct PipelineEvent: Sendable {
    public var progress: Double, message: String
    public init(_ progress: Double, _ message: String) {
        self.progress = progress
        self.message = message
    }
}

public enum StableID {
    public static func digest(_ s: String) -> String {
        var h: UInt64 = 14_695_981_039_346_656_037
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        return String(h, radix: 16)
    }
}
