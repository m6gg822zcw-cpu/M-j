import Foundation

public enum Codec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
private struct Journal: Codable { var project: Project, chapter: ChapterRun }
public actor Repository {
    public nonisolated let root: URL
    private let fm = FileManager.default
    public init(root: URL) { self.root = root }
    public func prepare() throws {
        try fm.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
    }
    public func settings() throws -> AppSettings {
        let file = root.appendingPathComponent("Settings.json")
        if fm.fileExists(atPath: file.path) { return try Codec.decode(AppSettings.self, Data(contentsOf: file)) }
        let value = AppSettings()
        try saveSettings(value)
        return value
    }
    public func saveSettings(_ settings: AppSettings) throws {
        try Codec.encode(settings).write(to: root.appendingPathComponent("Settings.json"), options: .atomic)
    }
    public func folder(_ id: UUID) -> URL {
        root.appendingPathComponent("Projects", isDirectory: true).appendingPathComponent(
            id.uuidString, isDirectory: true)
    }
    public func file(_ id: UUID, _ relative: String) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.contains("\\"), !relative.split(separator: "/").contains("..") else {
            throw StudioError.invalid("工程路径无效。")
        }
        let base = folder(id).standardizedFileURL
        let path = base.appendingPathComponent(relative).standardizedFileURL
        guard path.path.hasPrefix(base.path + "/") else { throw StudioError.invalid("工程路径越界。") }
        return path
    }
    private func put<T: Encodable>(_ value: T, id: UUID, path: String) throws {
        let url = try file(id, path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Codec.encode(value).write(to: url, options: .atomic)
    }
    private func read<T: Decodable>(_ type: T.Type, id: UUID, path: String) throws -> T {
        try Codec.decode(type, Data(contentsOf: file(id, path), options: .mappedIfSafe))
    }
    public func recover() throws {
        for dir in try fm.contentsOfDirectory(
            at: root.appendingPathComponent("Projects"), includingPropertiesForKeys: nil)
        {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let pending = try file(id, "Journal.json")
            if fm.fileExists(atPath: pending.path) {
                let journal = try Codec.decode(Journal.self, Data(contentsOf: pending))
                guard journal.project.id == id else { throw StudioError.invalid("工程事务归属不一致。") }
                try put(journal.chapter, id: id, path: "Chapters/\(journal.chapter.ordinal)-run.json")
                try put(journal.project, id: id, path: "Project.json")
                try fm.removeItem(at: pending)
            }
        }
    }
    public func list() throws -> [ProjectSummary] {
        try recover()
        return try fm.contentsOfDirectory(at: root.appendingPathComponent("Projects"), includingPropertiesForKeys: nil)
            .compactMap { dir in
                guard let id = UUID(uuidString: dir.lastPathComponent),
                    fm.fileExists(atPath: dir.appendingPathComponent("Project.json").path)
                else { return nil }
                return ProjectSummary(try project(id))
            }.sorted { $0.updated > $1.updated }
    }
    public func project(_ id: UUID) throws -> Project { try read(Project.self, id: id, path: "Project.json") }
    public func save(_ project: Project) throws {
        var p = project
        p.updated = Date()
        try put(p, id: p.id, path: "Project.json")
    }
    public func commit(_ project: Project, _ incoming: ChapterRun, preserveLettering: Bool = true) throws {
        var chapter = incoming
        // Pipeline snapshots must never erase a newer manual lettering edit.
        if preserveLettering,
            let saved = try? read(ChapterRun.self, id: project.id, path: "Chapters/\(chapter.ordinal)-run.json")
        {
            let layers = Dictionary(
                uniqueKeysWithValues: saved.panels.compactMap { panel in panel.lettering.map { (panel.id, $0) } })
            for i in chapter.panels.indices {
                if let layer = layers[chapter.panels[i].id] { chapter.panels[i].lettering = layer }
            }
        }
        guard let i = project.chapters.firstIndex(where: { $0.ordinal == chapter.ordinal }) else {
            throw StudioError.invalid("章节不属于当前工程。")
        }
        var p = project
        p.updated = Date()
        p.chapters[i].planned = chapter.planned
        p.chapters[i].totalPanels = chapter.panels.count
        p.chapters[i].completedPanels = chapter.panels.filter { $0.imageFile != nil }.count
        try put(Journal(project: p, chapter: chapter), id: p.id, path: "Journal.json")
        try put(chapter, id: p.id, path: "Chapters/\(chapter.ordinal)-run.json")
        try put(p, id: p.id, path: "Project.json")
        try fm.removeItem(at: file(p.id, "Journal.json"))
    }
    public func saveLettering(
        _ id: UUID, chapter ordinal: Int, panelID: String, lettering: ComicLettering,
        expectedImage: String, expectedRevision: Int
    ) throws -> ComicPanel {
        let p = try project(id)
        var run = try read(ChapterRun.self, id: id, path: "Chapters/\(ordinal)-run.json")
        guard let index = run.panels.firstIndex(where: { $0.id == panelID }) else {
            throw StudioError.invalid("画格不存在。")
        }
        guard run.panels[index].imageFile == expectedImage else { throw StudioError.invalid("这格漫画已被重绘，请重新打开气泡编辑器。") }
        guard (run.panels[index].lettering?.revision ?? 0) == expectedRevision else {
            throw StudioError.invalid("此格气泡已在其他窗口修改，请重新打开后编辑。")
        }
        var layer = try lettering.validated()
        layer.revision = expectedRevision + 1
        run.panels[index].lettering = layer
        try commit(p, run, preserveLettering: false)
        return run.panels[index]
    }
    public func importChapters(_ chapters: [RawChapter], title: String, artistID: UUID?, chunk: Int) throws -> Project {
        guard !chapters.isEmpty else { throw StudioError.invalid("没有可导入章节。") }
        let p = Project(
            title: title,
            chapters: chapters.enumerated().map {
                ChapterIndex(ordinal: $0.offset + 1, title: $0.element.title, characterCount: $0.element.text.count)
            }, artistID: artistID)
        for (i, c) in chapters.enumerated() {
            let units = ChapterParser.units(c.text)
            try put(units, id: p.id, path: "Chapters/\(i+1)-source.json")
        }
        try save(p)
        return p
    }
    public func chapter(_ id: UUID, ordinal: Int, chunk: Int) throws -> ChapterRun {
        let path = "Chapters/\(ordinal)-run.json"
        if fm.fileExists(atPath: try file(id, path).path) { return try read(ChapterRun.self, id: id, path: path) }
        let p = try project(id)
        guard let index = p.chapters.first(where: { $0.ordinal == ordinal }) else {
            throw StudioError.invalid("章节不存在。")
        }
        let units = try read([SourceUnit].self, id: id, path: "Chapters/\(ordinal)-source.json")
        var run = ChapterRun(
            ordinal: ordinal, title: index.title, units: units, batches: ChapterParser.batches(units, limit: chunk))
        if ordinal > 1, fm.fileExists(atPath: try file(id, "Chapters/\(ordinal-1)-run.json").path) {
            let previous = try read(ChapterRun.self, id: id, path: "Chapters/\(ordinal-1)-run.json")
            run.memoryBefore = previous.memoryAfter
            run.continuity = previous.continuity
        } else {
            run.continuity.notes = "此前章节尚未处理，不将未知前史补为既成事实。"
        }
        return run
    }
    public func asset(_ id: UUID, path: String) throws -> Data {
        try Data(contentsOf: file(id, path), options: .mappedIfSafe)
    }
    public func saveAsset(_ id: UUID, path: String, data: Data) throws {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else { throw StudioError.invalid("图片为空或大于64MB。") }
        let url = try file(id, path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    public func exists(_ id: UUID, path: String) throws -> Bool { fm.fileExists(atPath: try file(id, path).path) }
    public func receipt(_ id: UUID, chapter: Int) throws -> ImageReceipt? {
        let path = "Receipts/\(chapter).json"
        return fm.fileExists(atPath: try file(id, path).path) ? try read(ImageReceipt.self, id: id, path: path) : nil
    }
    public func beginReceipt(
        projectID: UUID, chapter: Int, target: String, fingerprint: String, prompt: String, requestJSON: String
    ) throws -> ImageReceipt {
        let id = UUID()
        let r = ImageReceipt(
            id: id, projectID: projectID, chapter: chapter, target: target, fingerprint: fingerprint, prompt: prompt,
            requestJSON: requestJSON, assetFile: "Images/\(id.uuidString).png", created: Date())
        try put(r, id: projectID, path: "Receipts/\(chapter).json")
        return r
    }
    public func clearReceipt(_ id: UUID, chapter: Int) throws {
        let url = try file(id, "Receipts/\(chapter).json")
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }
    public func jobs() throws -> [StudioJob] {
        let url = root.appendingPathComponent("Jobs.json")
        return fm.fileExists(atPath: url.path) ? try Codec.decode([StudioJob].self, Data(contentsOf: url)) : []
    }
    public func saveJobs(_ jobs: [StudioJob]) throws {
        try Codec.encode(jobs).write(to: root.appendingPathComponent("Jobs.json"), options: .atomic)
    }
    public func exportProject(_ id: UUID, artist: ArtistPreset, destination: URL) throws {
        try put(artist, id: id, path: "Artist.json")
        var exported = try project(id)
        exported.artistID = artist.id
        let snapshot = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".json")
        try Codec.encode(exported).write(to: snapshot, options: .atomic)
        defer { try? fm.removeItem(at: snapshot) }
        let base = folder(id)
        var files: [String: URL] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let iterator = fm.enumerator(at: base, includingPropertiesForKeys: keys) else {
            throw StudioError.invalid("无法读取工程。")
        }
        for case let url as URL in iterator {
            let info = try url.resourceValues(forKeys: Set(keys))
            if info.isRegularFile == true, info.isSymbolicLink != true {
                let relative = String(url.path.dropFirst(base.path.count + 1))
                if !relative.hasPrefix("Receipts/") && relative != "Journal.json" { files[relative] = url }
            }
        }
        files["Project.json"] = snapshot
        try ZIPArchive.write(files: files, to: destination)
    }
    public func restoreProject(_ data: Data) throws -> Project {
        let zip = try ZIPArchive(data: data)
        let old = try Codec.decode(Project.self, zip.read("Project.json"))
        var p = old
        p.id = UUID()
        p.updated = Date()
        var complete = false
        defer { if !complete { try? fm.removeItem(at: folder(p.id)) } }
        for e in zip.entries where !e.name.hasSuffix("/") {
            guard ["Chapters/", "Images/"].contains(where: { e.name.hasPrefix($0) }) || e.name == "Artist.json" else {
                continue
            }
            let bytes = try zip.read(e.name)
            let url = try file(p.id, e.name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
        }
        if zip.entries.contains(where: { $0.name == "Artist.json" }) {
            var artist = try Codec.decode(ArtistPreset.self, zip.read("Artist.json"))
            var s = try settings()
            if let existing = s.artists.first(where: { $0.id == artist.id }), existing != artist {
                artist.id = UUID()
                artist.name += " · 导入"
            }
            p.artistID = artist.id
            if !s.artists.contains(where: { $0.id == artist.id }) {
                s.artists.append(artist)
                try saveSettings(s)
            }
        }
        try save(p)
        complete = true
        return p
    }
}
