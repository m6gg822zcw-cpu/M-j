import MoxuCore
import PDFKit
import SwiftUI
import UIKit

@MainActor final class StudioModel: ObservableObject {
    let repository: Repository
    let vault = SecureVault(), client = ProviderClient(), processor = AssetProcessor()
    let pipeline: Pipeline
    @Published var settings = AppSettings()
    @Published var projects: [ProjectSummary] = []
    @Published var jobs: [StudioJob] = []
    @Published var loading = true
    @Published var importing = false
    @Published var importNotice: String?
    @Published var error: String?
    @Published var revision = 0
    @Published var selectedTab = 0
    private var worker: Task<Void, Never>?
    private var backgroundID: UIBackgroundTaskIdentifier = .invalid
    private var inBackground = false
    private var loadingTask: Task<Void, Never>?
    #if DEBUG
        private var didRunNativeSmokeChecks = false
    #endif
    var isWorking: Bool { jobs.contains { $0.state == .running } }
    init() {
        let root = URL.applicationSupportDirectory.appendingPathComponent("Moxu", isDirectory: true)
        let repo = Repository(root: root)
        repository = repo
        pipeline = Pipeline(repository: repo, client: client, processor: processor)
    }
    func load() async {
        if let task = loadingTask {
            await task.value
            return
        }
        // A file URL can launch the App before the root view's task has completed.
        // All callers await the same initialization instead of returning midway through it.
        let task = Task { @MainActor [self] in
            do {
                try await repository.prepare()
                settings = try await repository.settings()
                projects = try await repository.list()
                jobs = try await repository.jobs()
                for i in jobs.indices where jobs[i].state == .running || jobs[i].state == .queued {
                    jobs[i].state = .paused
                    jobs[i].message = "已恢复断点，点继续制作"
                }
                try await repository.saveJobs(jobs)
            } catch { report(error) }
            loading = false
        }
        loadingTask = task
        await task.value
    }
    func refresh() async {
        do {
            projects = try await repository.list()
            revision += 1
        } catch { report(error) }
    }
    func report(_ e: Error) { error = e.localizedDescription }
    func reportImportFailure(_ e: Error, fileName: String? = nil) {
        guard !CoordinatedImport.isCancellation(e) else { return }
        #if DEBUG
            PickerUITestTrace.record("import.failed", detail: e.localizedDescription)
        #endif
        let context = fileName.map { "未能导入「\($0)」" } ?? "未能选择导入文件"
        error = "\(context)：\(e.localizedDescription)"
    }
    func saveSettings(_ value: AppSettings) async throws {
        try await repository.saveSettings(value)
        settings = value
    }
    func saveProfile(_ p: APIProfile, token: String) async throws {
        let old = settings.profiles.first { $0.id == p.id }
        if let old, old.baseURL != p.baseURL { try await vault.save("", id: p.id) }
        try await vault.save(token, id: p.id)
        var s = settings
        if let i = s.profiles.firstIndex(where: { $0.id == p.id }) { s.profiles[i] = p } else { s.profiles.append(p) }
        if p.kind.isText && s.textProfileID == nil { s.textProfileID = p.id }
        if !p.kind.isText && s.imageProfileID == nil { s.imageProfileID = p.id }
        try await saveSettings(s)
    }
    func saveArtist(_ preset: ArtistPreset) async throws {
        var s = settings
        var a = preset
        a.revision += 1
        if let i = s.artists.firstIndex(where: { $0.id == a.id }) { s.artists[i] = a } else { s.artists.append(a) }
        try await saveSettings(s)
        revision += 1
    }
    func artist(for project: Project) -> ArtistPreset {
        let selected = project.artistID ?? profile(settings.imageProfileID, text: false)?.artistPresetID
        return settings.artists.first(where: { $0.id == selected }) ?? settings.artists.first ?? ArtistPreset()
    }
    func assetURL(_ id: UUID, _ path: String?) -> URL? {
        guard let path, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        return repository.root.appendingPathComponent("Projects", isDirectory: true).appendingPathComponent(
            id.uuidString, isDirectory: true
        ).appendingPathComponent(path)
    }
    func profile(_ id: UUID?, text: Bool) -> APIProfile? {
        settings.profiles.first(where: { $0.id == id && $0.kind.isText == text })
    }
    func importFile(_ url: URL) async {
        #if DEBUG
            PickerUITestTrace.record("import.requested", detail: url.lastPathComponent)
        #endif
        await load()
        guard !importing else {
            error = "正在导入另一份文件，请等它完成后再选择这份小说。"
            return
        }
        importing = true
        importNotice = nil
        error = nil
        defer { importing = false }
        do {
            let repo = repository
            let artistID: UUID? = nil
            let chunk = settings.chunkCharacters
            let headingPattern = settings.headingPattern
            let project: Project = try await Task.detached(priority: .userInitiated) {
                // Coordination and provider downloads may wait; keep all source-file work off the main actor.
                let data = try CoordinatedImport.read(url)
                let ext = url.pathExtension.lowercased()
                if ext == "moxu" { return try await repo.restoreProject(data) }
                let title = url.deletingPathExtension().lastPathComponent
                let chapters: [RawChapter]
                if ext == "pdf" {
                    guard let text = PDFDocument(data: data)?.string,
                        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { throw StudioError.invalid("PDF 没有可提取文字，扫描版请先 OCR。") }
                    chapters = try ChapterParser.parse(text, title: title, headingPattern: headingPattern)
                } else {
                    chapters = try DocumentReader.chapters(
                        data: data, extension: ext, title: title, headingPattern: headingPattern)
                }
                return try await repo.importChapters(chapters, title: title, artistID: artistID, chunk: chunk)
            }.value
            await finishImport(project)
        } catch { reportImportFailure(error, fileName: url.lastPathComponent) }
    }
    func importSample() async {
        guard !importing else { return }
        importing = true
        importNotice = nil
        error = nil
        defer { importing = false }
        do {
            let chapters = try ChapterParser.parse(
                "第一章 雨声\n\n林舟穿着深蓝外套站在书店门口。他二十四岁，黑色短发，左眉尾留着一道浅疤。\n\n苏禾推门出来，黑色齐肩发沾着雨。她戴着红围巾，右手提一盏铜灯，笑着说：‘走吧。’\n\n第二章 桥灯\n\n林舟与苏禾走到桥头，雨水从青石栏杆流下。\n\n苏禾将铜灯交给林舟，摘下湿透的红围巾，放进布袋里。",
                title: "雨声与桥灯")
            let project = try await repository.importChapters(
                chapters, title: "雨声与桥灯 · 示例", artistID: settings.artists.first?.id, chunk: settings.chunkCharacters)
            await finishImport(project)
        } catch { report(error) }
    }
    private func finishImport(_ project: Project) async {
        #if DEBUG
            PickerUITestTrace.record("import.saved", detail: project.title)
        #endif
        importNotice = "已导入《\(project.title)》，共 \(project.chapters.count) 章。"
        selectedTab = 0
        do {
            settings = try await repository.settings()
            projects = try await repository.list()
            revision += 1
        } catch {
            self.error = "《\(project.title)》已导入并保存，但书架刷新失败：\(error.localizedDescription) 请重新打开应用查看，无需重复导入。"
        }
    }
    func importLetteringDemo() async {
        guard let url = Bundle.main.url(forResource: "LetteringDemo", withExtension: "moxu") else {
            error = "未找到离线排版示例，请检查 Xcode 资源是否完整。"
            return
        }
        await importFile(url)
    }
    #if DEBUG
        /// Creates source documents only; UI tests must select them through the system picker.
        func preparePickerUITestFilesIfRequested() {
            guard ProcessInfo.processInfo.arguments.contains("--moxu-picker-ui-test") else { return }
            do {
                let directory = URL.documentsDirectory.appendingPathComponent("PickerUI", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // This bare preface reproduced the old heading parser consuming the first body paragraph.
                let txtURL = directory.appendingPathComponent("PickerNovel.txt")
                if !FileManager.default.fileExists(atPath: txtURL.path) {
                    try Data("序章\n林舟推开书店的门。原文与 emoji 🙂 应完整导入。".utf8)
                        .write(to: txtURL, options: .atomic)
                }
                let jsonURL = directory.appendingPathComponent("PickerChapters.json")
                if !FileManager.default.fileExists(atPath: jsonURL.path) {
                    let json = try JSONSerialization.data(withJSONObject: [
                        "chapters": [["title": "第一章 桥灯", "text": "苏禾提着铜灯走过桥头。"]]
                    ])
                    try json.write(to: jsonURL, options: .atomic)
                }
            } catch { report(error) }
        }
        /// Runs only when explicitly requested by the simulator verification script.
        @MainActor func runNativeSmokeChecksIfRequested() async {
            guard ProcessInfo.processInfo.arguments.contains("--moxu-native-smoke"), !didRunNativeSmokeChecks else {
                return
            }
            didRunNativeSmokeChecks = true
            let fm = FileManager.default
            let output = URL.documentsDirectory.appendingPathComponent("NativeSmoke", isDirectory: true)
            let sources = fm.temporaryDirectory.appendingPathComponent("MoxuNativeSmoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: sources) }
            var checks: [String] = []
            var failure: String?
            func require(_ condition: Bool, _ message: String) throws {
                guard condition else { throw StudioError.invalid(message) }
            }
            do {
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
                let previousResult = output.appendingPathComponent("result.json")
                if fm.fileExists(atPath: previousResult.path) { try fm.removeItem(at: previousResult) }
                try fm.createDirectory(at: sources, withIntermediateDirectories: true)
                try require(!loading && !importing, "原生冒烟检查需要先完成书架加载。")
                try require(error == nil, "书架加载失败：\(error ?? "未知错误")")
                let txtText = "林舟推开书店的门。中文、引号“原文”和 emoji 🙂 都应保留。\n\n窗外的雨还在下。"
                let mdText = "苏禾把红围巾放进布袋。Markdown 正文保持原样。"
                let jsonText = "铜灯照亮桥头的青石。\n‘走吧。’苏禾说。"
                let jsonData = try JSONSerialization.data(withJSONObject: [
                    "chapters": [["title": "JSON 原文章", "text": jsonText]]
                ])
                let fixtures: [(name: String, data: Data, expected: String)] = [
                    ("原生导入-TXT.txt", Data(txtText.utf8), txtText),
                    ("原生导入-Markdown.md", Data(("# 第一章 桥灯\n\n" + mdText).utf8), mdText),
                    ("原生导入-章节.json", jsonData, jsonText),
                ]
                for fixture in fixtures {
                    let source = sources.appendingPathComponent(fixture.name)
                    try fixture.data.write(to: source, options: .atomic)
                    let previousIDs = Set(projects.map(\.id))
                    await importFile(source)
                    try require(error == nil, "\(fixture.name) 导入失败：\(error ?? "未知错误")")
                    try require(importNotice?.contains("已导入") == true, "\(fixture.name) 缺少导入成功反馈。")
                    let imported = projects.filter { !previousIDs.contains($0.id) }
                    try require(imported.count == 1, "\(fixture.name) 未恰好新增一部作品。")
                    let project = try await repository.project(imported[0].id)
                    try require(project.chapters.count == 1, "\(fixture.name) 的章节数量不符。")
                    let run = try await repository.chapter(project.id, ordinal: 1, chunk: settings.chunkCharacters)
                    try require(run.units.map(\.text).joined(separator: "\n\n") == fixture.expected,
                                "\(fixture.name) 导入后的原文与预期不一致。")
                    let unchangedSource = try Data(contentsOf: source)
                    try require(unchangedSource == fixture.data, "\(fixture.name) 的源文件被修改。")
                    checks.append("\(fixture.name)：真实文件导入、成功反馈、章节原文和源文件保留通过")
                }

                let beforeDemo = Set(projects.map(\.id))
                await importLetteringDemo()
                try require(error == nil, "离线工程导入失败：\(error ?? "未知错误")")
                try require(importNotice?.contains("已导入") == true, "离线工程缺少导入成功反馈。")
                let demos = projects.filter { !beforeDemo.contains($0.id) }
                try require(demos.count == 1, "离线工程未恰好新增一部作品。")
                let project = try await repository.project(demos[0].id)
                var run = try await repository.chapter(project.id, ordinal: 1, chunk: settings.chunkCharacters)
                guard let original = run.panels.first, let imageFile = original.imageFile else {
                    throw StudioError.invalid("离线工程没有带图片的示例分镜。")
                }
                let sourceUnits = run.units
                let originalImage = try await repository.asset(project.id, path: imageFile)
                guard let image = UIImage(data: originalImage), image.size.height > 0 else {
                    throw StudioError.invalid("离线工程的示例图片无法解码。")
                }
                let aspect = Double(image.size.width / image.size.height)
                // The bundled demo currently has no saved layer. Persist a small explicit layer on one copy
                // so this check exercises a real manual layer, while the fourth copy keeps the original value.
                let manualLayer = try (original.lettering ?? ComicLettering(bubbles: [
                    ComicBubble(text: "手工字", frame: BubbleRect(x: 0.06, y: 0.06, width: 0.40, height: 0.14),
                                style: .caption, fontScale: 0.028, showSpeaker: false, tailEnabled: false)
                ])).validated()
                run.panels = (1...4).map { index in
                    var panel = original
                    panel.id = "NativeSmoke-P\(index)-\(UUID().uuidString)"
                    if index == 1 {
                        panel.lettering = manualLayer
                    } else if index == 2 {
                        panel.lettering = nil
                        panel.sfx = "雨声"
                    } else if index == 3 {
                        panel.lettering = ComicLettering(bubbles: [])
                        panel.sfx = "雨声"
                    }
                    return panel
                }
                try require(Set(run.panels.map(\.id)).count == 4, "冒烟分镜编号不唯一。")
                try await repository.commit(project, run, preserveLettering: false)
                run = try await repository.chapter(project.id, ordinal: 1, chunk: settings.chunkCharacters)
                try require(run.panels.count == 4 && run.units == sourceUnits, "分镜存档改变了原文或遗漏了画格。")
                try require(run.panels.allSatisfy { $0.imageFile == imageFile }, "分镜存档改变了原图引用。")
                try require(run.panels[0].lettering == manualLayer && run.panels[3].lettering == original.lettering,
                            "分镜存档改变了保存的手工层或原排版层。")
                try require(LetteringDefaults.layout(for: run.panels[0], imageAspect: aspect) == manualLayer,
                            "保存后的手工层未被显示布局采用。")
                try require(run.panels[1].sfx == "雨声" && run.panels[2].sfx == "雨声", "音效显示规则改写了原始音效。")
                let defaultLayer = LetteringDefaults.layout(for: run.panels[1], imageAspect: aspect)
                try require(defaultLayer.bubbles.contains { $0.sourceKey == "sfx" && $0.text == "淅沥淅沥" },
                            "未保存手工层的雨声音效没有显示为拟声词。")
                try require(LetteringDefaults.layout(for: run.panels[2], imageAspect: aspect).bubbles.isEmpty,
                            "空手工层未抑制原对白或音效。")
                let unchangedImage = try await repository.asset(project.id, path: imageFile)
                try require(unchangedImage == originalImage, "示例原图被修改。")
                checks.append("离线 MOXU 恢复、四格存档、原文/原图保留、手工层存档和音效显示规则通过")

                let selectedArtist = artist(for: project)
                for panelsPerPage in [1, 2, 4] {
                    let exported = try await ComicExporter.shared.export(
                        .png, project: project, run: run, repository: repository, artist: selectedArtist,
                        panelsPerPage: panelsPerPage)
                    defer { try? fm.removeItem(at: exported.deletingLastPathComponent()) }
                    let archiveData = try Data(contentsOf: exported)
                    let archive = try ZIPArchive(data: archiveData)
                    let pages = archive.entries.filter { $0.name.lowercased().hasSuffix(".png") }
                    try require(pages.count == 4 / panelsPerPage, "每页 \(panelsPerPage) 格的 PNG 页数错误。")
                    for page in pages {
                        let png = try archive.read(page.name)
                        guard let decoded = UIImage(data: png) else {
                            throw StudioError.invalid("导出的 \(page.name) 不是可解码的 PNG。")
                        }
                        try require(decoded.size == CGSize(width: 1170, height: 1656), "导出的 PNG 页面尺寸错误。")
                    }
                    if panelsPerPage == 4 {
                        try archive.read("001.png").write(to: output.appendingPathComponent("page-4.png"), options: .atomic)
                        try archiveData.write(to: output.appendingPathComponent("pages-4.zip"), options: .atomic)
                    }
                    checks.append("PNG 每页 \(panelsPerPage) 格：\(pages.count) 页，ZIP 校验及原生 PNG 解码通过")
                }
                for artifact in [(kind: ExportKind.pdf, name: "page-4.pdf"), (kind: ExportKind.html, name: "page-4.html")] {
                    let exported = try await ComicExporter.shared.export(
                        artifact.kind, project: project, run: run, repository: repository, artist: selectedArtist,
                        panelsPerPage: 4)
                    defer { try? fm.removeItem(at: exported.deletingLastPathComponent()) }
                    let data = try Data(contentsOf: exported)
                    try require(!data.isEmpty, "\(artifact.name) 导出为空。")
                    if artifact.kind == .pdf {
                        try require(PDFDocument(data: data)?.pageCount == 1, "四格 PDF 不是一页。")
                    } else {
                        try require(String(data: data, encoding: .utf8)?.contains("data:image/png;base64,") == true,
                                    "离线 HTML 未嵌入漫画页面。")
                    }
                    try data.write(to: output.appendingPathComponent(artifact.name), options: .atomic)
                    checks.append("\(artifact.name) 原生导出通过并已保存实物")
                }
                projects = try await repository.list()
                revision += 1
            } catch {
                failure = error.localizedDescription
            }
            do {
                let payload: [String: Any] = [
                    "success": failure == nil, "checks": checks, "error": failure.map { $0 as Any } ?? NSNull(),
                ]
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent("result.json"), options: .atomic)
                print("Moxu native smoke \(failure == nil ? "passed" : "failed"): \(checks.count) checks; \(failure ?? "no error")")
            } catch {
                self.error = "原生冒烟检查结果写入失败：\(error.localizedDescription)"
                print(self.error ?? "Native smoke result could not be saved")
            }
        }
    #endif
    func enqueue(_ job: StudioJob) async {
        if jobs.contains(where: {
            $0.projectID == job.projectID && $0.chapter == job.chapter && ($0.state == .running || $0.state == .queued)
        }) {
            error = "这个章节已有任务，请等待或暂停后重试。"
            return
        }
        if job.referenceCharacterID == nil && profile(settings.textProfileID, text: true) == nil {
            let existing = try? await repository.chapter(
                job.projectID, ordinal: job.chapter, chunk: settings.chunkCharacters)
            if existing?.planned != true {
                error = "先在连接页配置文本 API。"
                selectedTab = 2
                return
            }
        }
        if !job.scriptOnly && profile(settings.imageProfileID, text: false) == nil {
            error = "先在连接页配置生图 API。"
            selectedTab = 2
            return
        }
        jobs.append(job)
        try? await repository.saveJobs(jobs)
        startWorker()
    }
    func resume(_ id: UUID, authorizeRetry: Bool = false) async {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .running else { return }
        guard
            !jobs.contains(where: {
                $0.id != id && $0.projectID == jobs[i].projectID && $0.chapter == jobs[i].chapter
                    && [.running, .queued].contains($0.state)
            })
        else {
            error = "这个章节已有排队或运行中的任务。"
            return
        }
        jobs[i].state = .queued
        jobs[i].retryAuthorized = authorizeRetry
        jobs[i].message = "等待继续"
        try? await repository.saveJobs(jobs)
        startWorker()
    }
    func pause(_ id: UUID) async {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].state == .running {
            await pipeline.pause(id)
            jobs[i].message = "当前请求保存后暂停"
        } else {
            jobs[i].state = .paused
        }
        try? await repository.saveJobs(jobs)
    }
    func pauseForBackground() {
        inBackground = true
        for i in jobs.indices where jobs[i].state == .queued {
            jobs[i].state = .paused
            jobs[i].message = "应用进入后台，已保存队列"
        }
        if let j = jobs.first(where: { $0.state == .running }) { Task { await pause(j.id) } }
    }
    func becameActive() { inBackground = false }
    private func configuration(projectID: UUID) async throws -> PipelineConfiguration {
        let p = try await repository.project(projectID)
        let text = profile(settings.textProfileID, text: true)
        let image = profile(settings.imageProfileID, text: false)
        let vision = profile(settings.visionProfileID ?? settings.textProfileID, text: true)
        return PipelineConfiguration(
            text: text, image: image, vision: vision, artist: artist(for: p), chunk: settings.chunkCharacters,
            textToken: try await token(text), imageToken: try await token(image), visionToken: try await token(vision),
            checkVision: settings.performVisionCheck)
    }
    private func token(_ p: APIProfile?) async throws -> String {
        guard let p else { return "" }
        return try await vault.value(p.id)
    }
    private func startWorker() {
        guard worker == nil, !inBackground else { return }
        worker = Task {
            await workLoop()
            worker = nil
        }
    }
    private func workLoop() async {
        while let index = jobs.firstIndex(where: { $0.state == .queued }) {
            let job = jobs[index]
            jobs[index].state = .running
            jobs[index].message = "准备制作"
            try? await repository.saveJobs(jobs)
            backgroundID = UIApplication.shared.beginBackgroundTask(withName: "墨序保存当前请求") { [weak self] in
                Task { @MainActor in self?.worker?.cancel() }
            }
            do {
                let cfg = try await configuration(projectID: job.projectID)
                try await pipeline.run(job, config: cfg) { [weak self] event in await self?.event(job.id, event) }
                setState(job.id, .finished, "已完成")
            } catch is PipelinePaused { setState(job.id, .paused, "已保存断点，点继续制作") } catch is CancellationError {
                setState(job.id, .paused, "系统已暂停；下次会检查未完成请求")
            } catch {
                let receipt = try? await repository.receipt(job.projectID, chapter: job.chapter)
                if receipt != nil {
                    setState(job.id, .needsReview, error.localizedDescription)
                } else {
                    setState(job.id, .failed, error.localizedDescription)
                }
            }
            if backgroundID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundID)
                backgroundID = .invalid
            }
            if let completed = jobs.first(where: { $0.id == job.id }), completed.state != .finished {
                for i in jobs.indices
                where jobs[i].state == .queued && jobs[i].projectID == job.projectID && jobs[i].chapter >= job.chapter {
                    jobs[i].state = .paused
                    jobs[i].message = "前序任务未完成，已保留断点"
                }
            }
            try? await repository.saveJobs(jobs)
            await refresh()
            if Task.isCancelled || inBackground { break }
        }
    }
    private func event(_ id: UUID, _ e: PipelineEvent) async {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].progress = e.progress
        jobs[i].message = e.message
        revision += 1
        try? await repository.saveJobs(jobs)
    }
    private func setState(_ id: UUID, _ state: JobState, _ message: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = state
        jobs[i].message = message
        if state == .finished { jobs[i].progress = 1 }
    }
}

private enum CoordinatedImport {
    static let maximumBytes = 512 * 1024 * 1024
    static let extensions: Set<String> = ["txt", "md", "markdown", "json", "epub", "docx", "pdf", "moxu"]

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError { return true }
        if value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isCancellation(underlying)
        }
        return false
    }

    // Called only from a background task. Never modify or move the user's original file.
    static func read(_ source: URL) throws -> Data {
        guard extensions.contains(source.pathExtension.lowercased()) else {
            throw StudioError.invalid("请选择 TXT、MD（Markdown）、JSON、EPUB、DOCX、PDF 或 MOXU 文件，并保留正确的扩展名。")
        }
        try Task.checkCancellation()
        let scoped = source.startAccessingSecurityScopedResource()
        // App-bundled and sandbox-local files do not need a security scope and can return false here.
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("MoxuImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = directory.appendingPathComponent("source.\(source.pathExtension)")
        var coordinationError: NSError?
        var copied: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            copied = Result { try copyBounded(from: readable, to: snapshot) }
        }
        if let copied {
            try copied.get()
        } else if let coordinationError {
            if isCancellation(coordinationError) { throw coordinationError }
            throw StudioError.invalid("无法读取文件：\(coordinationError.localizedDescription) 若文件位于云盘，请先在「文件」App 中下载并确认可以打开，再重新选择。")
        } else {
            throw StudioError.invalid("文件提供器没有返回可读取的文件，请在「文件」App 中下载后重新选择。")
        }
        try Task.checkCancellation()
        // Own the bytes before deleting the snapshot or releasing the provider's security scope.
        return try Data(contentsOf: snapshot)
    }

    private static func copyBounded(from source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values.isDirectory != true else { throw StudioError.invalid("请选择小说或工程文件，不能导入文件夹。") }
        if let size = values.fileSize, size > maximumBytes {
            throw StudioError.invalid("文件超过 512 MB，请按章拆分后导入。")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw StudioError.invalid("无法创建导入临时文件，请检查设备储存空间后重试。")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var total = 0
        while true {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty else { break }
            // Provider metadata can be absent or stale; enforce the limit on bytes actually read as well.
            guard bytes.count <= maximumBytes - total else {
                throw StudioError.invalid("文件超过 512 MB，请按章拆分后导入。")
            }
            try output.write(contentsOf: bytes)
            total += bytes.count
        }
    }
}
