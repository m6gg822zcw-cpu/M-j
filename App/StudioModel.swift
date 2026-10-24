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
    @Published var error: String?
    @Published var revision = 0
    @Published var selectedTab = 0
    private var worker: Task<Void, Never>?
    private var backgroundID: UIBackgroundTaskIdentifier = .invalid
    private var inBackground = false
    private var didStartLoading = false
    var isWorking: Bool { jobs.contains { $0.state == .running } }
    init() {
        let root = URL.applicationSupportDirectory.appendingPathComponent("Moxu", isDirectory: true)
        let repo = Repository(root: root)
        repository = repo
        pipeline = Pipeline(repository: repo, client: client, processor: processor)
    }
    func load() async {
        guard !didStartLoading else { return }
        didStartLoading = true
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
    func refresh() async {
        do {
            projects = try await repository.list()
            revision += 1
        } catch { report(error) }
    }
    func report(_ e: Error) { error = e.localizedDescription }
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
        guard !importing else { return }
        importing = true
        defer { importing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let repo = repository
            let artistID: UUID? = nil
            let chunk = settings.chunkCharacters
            let headingPattern = settings.headingPattern
            let project: Project = try await Task.detached(priority: .userInitiated) {
                let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard size < 512 * 1024 * 1024 else { throw StudioError.invalid("文件超过512MB，请按章拆分。") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
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
            _ = project
            settings = try await repository.settings()
            await refresh()
        } catch { report(error) }
    }
    func importSample() async {
        do {
            let chapters = try ChapterParser.parse(
                "第一章 雨声\n\n林舟穿着深蓝外套站在书店门口。他二十四岁，黑色短发，左眉尾留着一道浅疤。\n\n苏禾推门出来，黑色齐肩发沾着雨。她戴着红围巾，右手提一盏铜灯，笑着说：‘走吧。’\n\n第二章 桥灯\n\n林舟与苏禾走到桥头，雨水从青石栏杆流下。\n\n苏禾将铜灯交给林舟，摘下湿透的红围巾，放进布袋里。",
                title: "雨声与桥灯")
            _ = try await repository.importChapters(
                chapters, title: "雨声与桥灯 · 示例", artistID: settings.artists.first?.id, chunk: settings.chunkCharacters)
            await refresh()
        } catch { report(error) }
    }
    func importLetteringDemo() async {
        guard let url = Bundle.main.url(forResource: "LetteringDemo", withExtension: "moxu") else {
            error = "未找到离线排版示例，请检查 Xcode 资源是否完整。"
            return
        }
        await importFile(url)
    }
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
