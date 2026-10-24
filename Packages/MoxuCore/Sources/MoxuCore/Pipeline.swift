import Foundation

public protocol ImageProcessor: Sendable {
    func prepare(_ images: [ReferenceImage], profile: APIProfile) async throws -> [ReferenceImage]
    func normalize(_ image: Data) async throws -> Data
}
public struct PipelineConfiguration: Sendable {
    public var text: APIProfile?, image: APIProfile?, vision: APIProfile?, artist: ArtistPreset, chunk: Int
    public var textToken: String, imageToken: String, visionToken: String, checkVision: Bool
    public init(
        text: APIProfile?, image: APIProfile?, vision: APIProfile?, artist: ArtistPreset, chunk: Int, textToken: String,
        imageToken: String, visionToken: String, checkVision: Bool
    ) {
        self.text = text
        self.image = image
        self.vision = vision
        self.artist = artist
        self.chunk = chunk
        self.textToken = textToken
        self.imageToken = imageToken
        self.visionToken = visionToken
        self.checkVision = checkVision
    }
}
public struct PipelinePaused: Error {}
public actor Pipeline {
    private let repository: Repository, client: ProviderClient, processor: any ImageProcessor
    private var pauseRequested = Set<UUID>()
    public init(repository: Repository, client: ProviderClient, processor: any ImageProcessor) {
        self.repository = repository
        self.client = client
        self.processor = processor
    }
    public func pause(_ id: UUID) { pauseRequested.insert(id) }
    private func checkpoint(_ job: StudioJob) throws {
        try Task.checkCancellation()
        if pauseRequested.contains(job.id) { throw PipelinePaused() }
    }
    public func run(_ job: StudioJob, config: PipelineConfiguration, event: @Sendable (PipelineEvent) async -> Void)
        async throws
    {
        pauseRequested.remove(job.id)
        var project = try await repository.project(job.projectID)
        var run = try await repository.chapter(job.projectID, ordinal: job.chapter, chunk: config.chunk)
        if job.referenceCharacterID == nil {
            while run.doneBatches < run.batches.count {
                guard let text = config.text else { throw StudioError.invalid("先在连接页选择文本 API。") }
                try checkpoint(job)
                let ids = Set(run.batches[run.doneBatches])
                let units = run.units.filter { ids.contains($0.id) }
                await event(
                    PipelineEvent(
                        0.35 * Double(run.doneBatches) / Double(max(1, run.batches.count)),
                        "拆分镜 \(run.doneBatches+1)/\(run.batches.count)批"))
                let prompt = try PromptTemplates.planning(
                    project: project, run: run, units: units, artist: config.artist)
                let raw = try await client.complete(profile: text, token: config.textToken, prompt: prompt)
                do { try Analysis.apply(Analysis.decode(raw), units: units, project: &project, run: &run) } catch {
                    try checkpoint(job)
                    let repaired = try await client.complete(
                        profile: text, token: config.textToken,
                        prompt: prompt + "\n上次结构不合格：\(error.localizedDescription)。请完整重写JSON，补足所有段落和必要字段。")
                    try Analysis.apply(Analysis.decode(repaired), units: units, project: &project, run: &run)
                }
                try await repository.commit(project, run)
            }
            if !run.planned {
                guard let text = config.text else { throw StudioError.invalid("先在连接页选择文本 API 以融合章节记忆。") }
                try checkpoint(job)
                await event(PipelineEvent(0.37, "融合本章记忆"))
                let raw = try await client.complete(
                    profile: text, token: config.textToken, prompt: PromptTemplates.memory(run))
                guard let obj = try JSONSerialization.jsonObject(with: Analysis.objectData(raw)) as? [String: Any],
                    let memory = obj["memory"] as? String, !memory.isEmpty, memory.count <= 10000
                else { throw StudioError.invalid("总记忆结构无效，分镜已保留，继续时仅补做记忆。") }
                run.memoryAfter = memory
                run.planned = true
                try await repository.commit(project, run)
            }
            if job.scriptOnly {
                await event(PipelineEvent(1, "本章分镜已完成，可校准人物后继续出图"))
                return
            }
        }
        guard let configuredImage = config.image else { throw StudioError.invalid("分镜已保存，先在连接页选择生图 API。") }
        let imageProfile = try RequestBuilder.imageProfile(profile: configuredImage, artist: config.artist)
        let recovered = try await recoverReceipt(
            job, config: config, project: &project, run: &run, imageProfile: imageProfile)
        if let id = job.referenceCharacterID {
            if recovered == "ref:" + id.uuidString {
                await event(PipelineEvent(1, "已恢复保存的定妆图"))
                return
            }
            guard let i = project.characters.firstIndex(where: { $0.id == id }) else {
                throw StudioError.invalid("人物不存在。")
            }
            project.characters[i].referenceFile = nil
            try await reference(
                index: i, job: job, config: config, profile: imageProfile, project: &project, run: &run, event: event)
            await event(PipelineEvent(1, "人物定妆图已保存，请人工核对"))
            return
        }
        let targets = run.panels.indices.filter { job.panelID == nil || run.panels[$0].id == job.panelID }
        for (position, index) in targets.enumerated() {
            try checkpoint(job)
            let ids = Set(run.panels[index].cast.map(\.characterID))
            let usesReferences =
                imageProfile.kind == .novelAI
                ? imageProfile.referenceMode != .off && ids.count == 1 : imageProfile.useImageReferences
            if usesReferences {
                for c in project.characters.indices
                where ids.contains(project.characters[c].id) && project.characters[c].referenceFile == nil {
                    try await reference(
                        index: c, job: job, config: config, profile: imageProfile, project: &project, run: &run,
                        event: event)
                }
            }
            var prompt = try PromptComposer.compose(
                panel: run.panels[index], project: project, artist: config.artist, profile: imageProfile)
            if job.panelID == nil || recovered == "panel:" + run.panels[index].id, run.panels[index].imageFile != nil,
                run.panels[index].fingerprint == prompt.fingerprint
            {
                continue
            }
            var refs: [ReferenceImage] = []
            if usesReferences {
                for cast in run.panels[index].cast {
                    guard let c = project.characters.first(where: { $0.id == cast.characterID }),
                        let file = c.referenceFile
                    else { continue }
                    if !refs.contains(where: { $0.label.hasPrefix(c.id.uuidString) }) {
                        refs.append(
                            ReferenceImage(
                                data: try await repository.asset(project.id, path: file),
                                label: c.id.uuidString + " " + c.name + " / " + c.stage))
                    }
                }
            }
            refs = try await processor.prepare(refs, profile: imageProfile)
            prompt.natural +=
                "\n参考顺序：" + refs.enumerated().map { "\($0.offset+1)：\($0.element.label)" }.joined(separator: "；")
            let request = try RequestBuilder.image(
                profile: imageProfile, token: config.imageToken, prompt: prompt, references: refs)
            let receipt = try await repository.beginReceipt(
                projectID: project.id, chapter: run.ordinal, target: "panel:" + run.panels[index].id,
                fingerprint: prompt.fingerprint,
                prompt: imageProfile.kind == .novelAI ? prompt.naiBase : prompt.natural,
                requestJSON: request.redactedJSON)
            await event(
                PipelineEvent(
                    0.4 + 0.55 * Double(position) / Double(max(1, targets.count)),
                    "绘制 \(run.panels[index].id) · \(position+1)/\(targets.count)"))
            let bytes = try await receive(request, profile: imageProfile, receipt: receipt)
            run.panels[index].imageFile = receipt.assetFile
            run.panels[index].fingerprint = prompt.fingerprint
            run.panels[index].lastPrompt = receipt.prompt
            run.panels[index].requestJSON = receipt.requestJSON
            run.panels[index].review = .pending
            if imageProfile.kind == .novelAI && ids.count > 1 {
                run.panels[index].reviewNotes = "NAI 多人物使用独立角色提示词，未叠加会混合人物的多张精确参考。需人工校对。"
            }
            try await repository.commit(project, run)
            try await repository.clearReceipt(project.id, chapter: run.ordinal)
            try checkpoint(job)
            if config.checkVision, let vision = config.vision {
                do {
                    let check = try await client.complete(
                        profile: vision, token: config.visionToken,
                        prompt:
                            "你是漫画视觉校对师。前面是定妆参考，最后一张是候选画格。核对脸型、发色、年龄阶段、人数、体型、衣着、动作、站位和左右手。看不见的要素不猜。只输出JSON {\"pass\":true或false,\"issues\":[\"可见差异\"]}。要求：\(prompt.natural)",
                        images: refs + [ReferenceImage(data: bytes)])
                    if let obj = try JSONSerialization.jsonObject(with: Analysis.objectData(check)) as? [String: Any],
                        let pass = obj["pass"] as? Bool, let issues = obj["issues"] as? [String]
                    {
                        run.panels[index].review = pass && issues.isEmpty ? .assistedPass : .mismatch
                        run.panels[index].reviewNotes = issues.joined(separator: "；")
                    }
                } catch { run.panels[index].reviewNotes = "视觉接口未完成检查，请人工核对。" }
                try await repository.commit(project, run)
            }
        }
        await event(PipelineEvent(1, "本章出图完成，请检查画格一致性"))
    }
    private func referenceFingerprint(_ c: CharacterCard, artist: ArtistPreset, profile: APIProfile) throws -> String {
        StableID.digest(
            String(data: try Codec.encode(c.identity), encoding: .utf8)! + c.naiIdentity + String(c.revision) + String(
                data: try Codec.encode(artist), encoding: .utf8)! + String(
                    data: try Codec.encode(profile), encoding: .utf8)!)
    }
    private func reference(
        index: Int, job: StudioJob, config: PipelineConfiguration, profile: APIProfile, project: inout Project,
        run: inout ChapterRun, event: @Sendable (PipelineEvent) async -> Void
    ) async throws {
        try checkpoint(job)
        let c = project.characters[index]
        let facts =
            "绘制同一人物的漫画定妆设定图：正面全身、侧面和脸部近景。简洁背景，穿得体、不透明的中性基础衣装，不用剧情服装遮盖身份特征。所有视图必须同一个人，不改变年龄、物种、脸型、发色、眼睛和体型。无文字、无编号、无水印。固定身份：\(c.name) \(c.stage) \(String(data: try Codec.encode(c.identity), encoding: .utf8)!)。画风指导：\(config.artist.guidance)"
        let style = [config.artist.positive, config.artist.character].filter { !$0.isEmpty }.joined(separator: "\n")
        var natural = (config.artist.placement == .beforeFacts ? [style, facts] : [facts, style]).filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !config.artist.negative.isEmpty { natural += "\n避免以下内容：\n" + config.artist.negative }
        let identityFacts =
            c.naiIdentity
            + ", reference sheet, multiple views, standing, full body, face focus, simple background, plain opaque clothes, no text"
        let artistTags = [config.artist.positive, config.artist.character].filter { !$0.isEmpty }.joined(
            separator: ", ")
        let identity =
            (config.artist.placement == .beforeFacts ? [artistTags, identityFacts] : [identityFacts, artistTags]).filter
        { !$0.isEmpty }.joined(separator: ", ")
        let signature = try referenceFingerprint(c, artist: config.artist, profile: profile)
        let prompt = ComposedPrompt(
            natural: natural, naiBase: identity, negative: config.artist.negative, characters: [],
            fingerprint: signature)
        var referenceProfile = profile
        referenceProfile.referenceMode = .off
        let request = try RequestBuilder.image(
            profile: referenceProfile, token: config.imageToken, prompt: prompt, references: [])
        let receipt = try await repository.beginReceipt(
            projectID: project.id, chapter: run.ordinal, target: "ref:" + c.id.uuidString, fingerprint: signature,
            prompt: profile.kind == .novelAI ? identity : natural, requestJSON: request.redactedJSON)
        await event(PipelineEvent(0.4, "定妆图 · \(c.name) \(c.stage)"))
        _ = try await receive(request, profile: referenceProfile, receipt: receipt)
        project.characters[index].referenceFile = receipt.assetFile
        try await repository.commit(project, run)
        try await repository.clearReceipt(project.id, chapter: run.ordinal)
    }
    private func recoverReceipt(
        _ job: StudioJob, config: PipelineConfiguration, project: inout Project, run: inout ChapterRun,
        imageProfile: APIProfile
    ) async throws -> String? {
        guard let receipt = try await repository.receipt(project.id, chapter: run.ordinal) else { return nil }
        if try await repository.exists(project.id, path: receipt.assetFile) {
            let raw = try await repository.asset(project.id, path: receipt.assetFile)
            do {
                let normalized = try await processor.normalize(raw)
                try await repository.saveAsset(project.id, path: receipt.assetFile, data: normalized)
            } catch {
                if job.retryAuthorized {
                    try await repository.clearReceipt(project.id, chapter: run.ordinal)
                    return nil
                }
                throw StudioError.uncertainRequest("已收到图片，但无法解码；请先核实平台记录")
            }
            if receipt.target.hasPrefix("ref:"), let id = UUID(uuidString: String(receipt.target.dropFirst(4))),
                let i = project.characters.firstIndex(where: { $0.id == id }),
                receipt.fingerprint
                    == (try referenceFingerprint(project.characters[i], artist: config.artist, profile: imageProfile))
            {
                project.characters[i].referenceFile = receipt.assetFile
            } else if receipt.target.hasPrefix("panel:"),
                let i = run.panels.firstIndex(where: { $0.id == String(receipt.target.dropFirst(6)) }),
                receipt.fingerprint
                    == (try PromptComposer.compose(
                        panel: run.panels[i], project: project, artist: config.artist, profile: imageProfile))
                    .fingerprint
            {
                run.panels[i].imageFile = receipt.assetFile
                run.panels[i].fingerprint = receipt.fingerprint
                run.panels[i].lastPrompt = receipt.prompt
                run.panels[i].requestJSON = receipt.requestJSON
                run.panels[i].review = .pending
            } else if job.retryAuthorized {
                try await repository.clearReceipt(project.id, chapter: run.ordinal)
                return nil
            } else {
                throw StudioError.uncertainRequest("已保存图片与当前人物/画风版本不一致，旧图已保留")
            }
            try await repository.commit(project, run)
            try await repository.clearReceipt(project.id, chapter: run.ordinal)
            return receipt.target
        } else if job.retryAuthorized {
            try await repository.clearReceipt(project.id, chapter: run.ordinal)
        } else {
            throw StudioError.uncertainRequest(receipt.target)
        }
        return nil
    }
    private func receive(_ request: PreparedRequest, profile: APIProfile, receipt: ImageReceipt) async throws -> Data {
        let raw: Data
        do { raw = try await client.generate(request, profile: profile) } catch {
            try await definiteFailure(error, projectID: receipt.projectID, chapter: receipt.chapter)
            throw error
        }
        // Persist the paid response before decoding; recovery can finish normalization without a second POST.
        try await repository.saveAsset(receipt.projectID, path: receipt.assetFile, data: raw)
        let bytes = try await processor.normalize(raw)
        try await repository.saveAsset(receipt.projectID, path: receipt.assetFile, data: bytes)
        return bytes
    }
    private func definiteFailure(_ error: Error, projectID: UUID, chapter: Int) async throws {
        if case StudioError.http(let code) = error, [400, 401, 403, 404, 422].contains(code) {
            try await repository.clearReceipt(projectID, chapter: chapter)
        }
    }
}
