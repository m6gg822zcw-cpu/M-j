import MoxuCore
import SwiftUI
import UIKit

struct WorkspaceView: View {
    @EnvironmentObject private var studio: StudioModel
    let projectID: UUID
    @State private var project: Project?
    @State private var run: ChapterRun?
    @State private var ordinal = 1
    @State private var pane = 0
    @State private var count = 1
    @State private var scriptOnly = true
    @State private var choosingChapter = false
    @State private var addCharacter = false
    @State private var showSource = false
    @State private var exporting = false
    @State private var share: ShareItem?
    var body: some View {
        Group {
            if let project {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        QuietTitle(
                            eyebrow: "逐章制作", title: project.title,
                            subtitle: "\(project.chapters.count) 个章节 · \(project.characters.count) 位人物")
                        Button {
                            choosingChapter = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("当前章节").font(.caption).foregroundStyle(.secondary)
                                    Text(run?.title ?? "正在读取…").font(.headline).foregroundStyle(.primary)
                                }
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").foregroundStyle(Ink.accent)
                            }
                        }.padding(.vertical, 8)
                        Picker("工作区", selection: $pane) {
                            Text("章节").tag(0)
                            Text("人物").tag(1)
                            Text("漫画").tag(2)
                        }.pickerStyle(.segmented)
                        if pane == 0 {
                            chapterPane(project)
                        } else if pane == 1 {
                            charactersPane(project)
                        } else {
                            comicPane(project)
                        }
                    }.padding(24).frame(maxWidth: 1100)
                }.background(Ink.paper)
            } else {
                ProgressView("读取工程…").frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.paper)
            }
        }
        .navigationTitle("漫画工作台").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("完整工程备份", systemImage: "archivebox") { export(.backup) }
                    Button("漫画 PDF", systemImage: "doc.richtext") { export(.pdf) }
                    Button("漫画 PNG 页", systemImage: "photo.stack") { export(.png) }
                    Button("离线漫画 HTML", systemImage: "doc.text") { export(.html) }
                } label: {
                    if exporting { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
                }.disabled(exporting || project == nil)
            }
        }
        .task(id: "\(ordinal)-\(studio.revision)") { await reload() }
        .sheet(isPresented: $choosingChapter) {
            if let project { ChapterChooser(chapters: project.chapters, ordinal: $ordinal) }
        }
        .sheet(isPresented: $showSource) { if let run { SourceReader(run: run) } }
        .sheet(isPresented: $addCharacter) {
            NavigationStack {
                CharacterEditor(
                    projectID: projectID,
                    card: CharacterCard(
                        name: "新人物", stage: "常态",
                        identity: [
                            "gender": "未明确", "age": "未明确", "species": "人类", "height": "待设定", "build": "待设定",
                            "skin": "待设定", "face": "待设定", "hair": "黑色头发", "eyes": "棕色眼睛", "marks": "无",
                        ], naiIdentity: "person, black hair, brown eyes",
                        costumes: [
                            Costume(
                                layers: [
                                    "base": "不透明基础衣装", "top": "素色上衣", "bottom": "长裤", "outer": "无", "footwear": "普通鞋",
                                    "accessories": "无",
                                ],
                                naiLayers: [
                                    "base": "undershirt", "top": "plain shirt", "bottom": "long pants", "outer": "none",
                                    "footwear": "shoes", "accessories": "none",
                                ])
                        ], designNotes: "用户手动建档。未依据原著的外观为制作补设。"))
            }
        }
        .sheet(item: $share) { ShareSheet(urls: [$0.url]) }
    }
    private func reload() async {
        do {
            let p = try await studio.repository.project(projectID)
            let r = try await studio.repository.chapter(
                projectID, ordinal: ordinal, chunk: studio.settings.chunkCharacters)
            if !Task.isCancelled {
                project = p
                run = r
            }
        } catch { if !Task.isCancelled { studio.report(error) } }
    }
    @ViewBuilder private func chapterPane(_ p: Project) -> some View {
        if let run {
            HStack(spacing: 22) {
                stat("分镜", "\(run.panels.count) 格")
                stat("已出图", "\(run.panels.filter{$0.imageFile != nil}.count) 格")
                stat("批次", "\(run.doneBatches)/\(run.batches.count)")
            }
            VStack(alignment: .leading, spacing: 12) {
                Toggle("先只制作分镜脚本", isOn: $scriptOnly).tint(Ink.accent)
                Text("先提取人物并校准定妆。取消此项后会实际调用生图服务。").font(.footnote).foregroundStyle(.secondary)
                Stepper("连续制作 \(count) 章", value: $count, in: 1...10)
                BusyButton(
                    title: "制作 / 从断点继续", icon: "play.fill",
                    busy: studio.jobs.contains {
                        $0.projectID == projectID && $0.chapter == ordinal && $0.state == .running
                    }
                ) {
                    Task {
                        for i in ordinal..<min(p.chapters.count + 1, ordinal + count) {
                            await studio.enqueue(StudioJob(projectID: projectID, chapter: i, scriptOnly: scriptOnly))
                        }
                    }
                }
            }.padding(.vertical, 8)
            Divider()
            Text("本章原文").font(.title3.bold())
            Text(run.units.prefix(3).map(\.text).joined(separator: "\n\n")).lineLimit(10).foregroundStyle(.secondary)
                .font(.subheadline)
            Button("查看完整原文与段落编号") { showSource = true }
            if !run.memoryAfter.isEmpty {
                Divider()
                Text("融合记忆").font(.title3.bold())
                Text(run.memoryAfter).font(.footnote).foregroundStyle(.secondary).lineLimit(8)
            }
            if !p.conflicts.isEmpty {
                Divider()
                Label("\(p.conflicts.count) 条外观差异待核实", systemImage: "exclamationmark.bubble").foregroundStyle(.orange)
                ForEach(p.conflicts.suffix(5)) { c in
                    Text("第\(c.chapter)章 · \(c.field)：锁定‘\(c.locked)’，新描述‘\(c.proposed)’").font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Picker(
                "画师方案",
                selection: Binding(
                    get: { p.artistID },
                    set: { id in
                        Task {
                            do {
                                var value = try await studio.repository.project(projectID)
                                value.artistID = id
                                try await studio.repository.save(value)
                                await studio.refresh()
                            } catch { studio.report(error) }
                        }
                    })
            ) {
                Text("跟随生图连接默认方案").tag(Optional<UUID>.none)
                ForEach(studio.settings.artists) { a in Text(a.name).tag(Optional(a.id)) }
            }.disabled(studio.isWorking)
        }
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func charactersPane(_ p: Project) -> some View {
        HStack {
            Text("固定身份，独立换装").font(.headline)
            Spacer()
            Button {
                addCharacter = true
            } label: {
                Image(systemName: "person.badge.plus")
            }.disabled(studio.isWorking)
        }
        Text("脸、头发、体型与年龄阶段属于身份层；服装、动作、表情分别随剧情变化。").font(.footnote).foregroundStyle(.secondary)
        if p.characters.isEmpty {
            EmptyHint(icon: "person.crop.square", title: "还没有人物档案", detail: "完成首批分镜后会自动建档；也可以手动添加。")
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], spacing: 22) {
            ForEach(p.characters) { c in
                NavigationLink {
                    CharacterEditor(projectID: projectID, card: c)
                } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        AsyncArtwork(url: studio.assetURL(projectID, c.referenceFile), side: 440, mode: .fill).frame(
                            height: 190
                        ).clipped().clipShape(RoundedRectangle(cornerRadius: 9))
                        Text(c.name).font(.headline).foregroundStyle(.primary)
                        Text("\(c.stage) · 外观 v\(c.revision)").font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
        }
    }
    @ViewBuilder private func comicPane(_ p: Project) -> some View {
        if let run, !run.panels.isEmpty {
            LazyVStack(spacing: 28) { ForEach(run.panels) { panel in PanelCell(project: p, run: run, panel: panel) } }
        } else {
            EmptyHint(icon: "rectangle.split.2x2", title: "本章还没有分镜", detail: "回到章节页，开始制作这一个章节。")
        }
    }
    private func export(_ kind: ExportKind) {
        guard let project, let run else { return }
        exporting = true
        Task {
            do {
                let url = try await ComicExporter.shared.export(
                    kind, project: project, run: run, repository: studio.repository, artist: studio.artist(for: project)
                )
                share = ShareItem(url: url)
            } catch { studio.report(error) }
            exporting = false
        }
    }
}
private struct ChapterChooser: View {
    let chapters: [ChapterIndex]
    @Binding var ordinal: Int
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var filtered: [ChapterIndex] {
        query.isEmpty
            ? chapters
            : chapters.filter { $0.title.localizedCaseInsensitiveContains(query) || String($0.ordinal) == query }
    }
    var body: some View {
        NavigationStack {
            List(filtered) { c in
                Button {
                    ordinal = c.ordinal
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(c.ordinal). \(c.title)").foregroundStyle(.primary)
                            Text(c.planned ? "\(c.completedPanels)/\(c.totalPanels)格已出图" : "\(c.characterCount) 字符")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if c.ordinal == ordinal { Image(systemName: "checkmark").foregroundStyle(Ink.accent) }
                    }
                }
            }.searchable(text: $query, prompt: "搜索标题或目录序号").navigationTitle("选择章节").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
    }
}
private struct SourceReader: View {
    let run: ChapterRun
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(run.units) { u in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(u.id).font(.caption.monospaced()).foregroundStyle(Ink.accent)
                            Text(u.text).textSelection(.enabled)
                        }
                    }.padding(24)
                }
            }.background(Ink.paper).navigationTitle(run.title).navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
private struct PanelCell: View {
    @EnvironmentObject private var studio: StudioModel
    let project: Project, run: ChapterRun, panel: ComicPanel
    @State private var showDetails = false
    @State private var showImage = false
    @State private var showBubbleEditor = false
    private var stale: Bool {
        guard panel.imageFile != nil, let profile = studio.profile(studio.settings.imageProfileID, text: false),
            let current = try? PromptComposer.compose(
                panel: panel, project: project, artist: studio.artist(for: project), profile: profile)
        else { return false }
        return current.fingerprint != panel.fingerprint
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(panel.id).font(.caption.monospaced())
                Spacer()
                Text(stale ? "外观或画风已改 · 待更新" : panel.review.title).foregroundStyle(stale ? .orange : panel.review.color)
                    .font(.caption)
            }
            if panel.imageFile == nil, !panel.narration.isEmpty {
                Text(panel.narration).font(.subheadline).padding(.vertical, 4)
            }
            if panel.imageFile == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(panel.shot) · \(panel.camera)").font(.caption).foregroundStyle(Ink.teal)
                    Text(panel.action).font(.body)
                    Text("\(panel.setting) · \(panel.time)").font(.footnote).foregroundStyle(.secondary)
                    Text(
                        "入镜："
                            + panel.cast.compactMap { cast in
                                project.characters.first { $0.id == cast.characterID }?.name
                            }.joined(separator: "、")
                    ).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } else {
                Button {
                    showImage = true
                } label: {
                    LetteredArtwork(url: studio.assetURL(project.id, panel.imageFile), panel: panel, side: 1200).frame(
                        maxWidth: .infinity
                    ).frame(minHeight: 160).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if panel.imageFile == nil {
                ForEach(Array(panel.dialogue.enumerated()), id: \.offset) { _, d in
                    HStack(alignment: .top) {
                        Text(
                            d.kind == "thought"
                                ? "\(d.speaker)·心声" : d.kind == "offscreen" ? "\(d.speaker)·画外音" : d.speaker
                        ).fontWeight(.semibold)
                        Text(d.text)
                    }.font(.subheadline)
                }
                if !panel.sfx.isEmpty { Text("音效 · \(panel.sfx)").font(.caption).foregroundStyle(Ink.teal) }
            }
            HStack {
                Button("查看提示词") { showDetails = true }
                Button("调整气泡", systemImage: "bubble.left.and.text.bubble.right") { showBubbleEditor = true }.disabled(
                    panel.imageFile == nil || studio.isWorking)
                Spacer()
                Menu {
                    Button("人工确认一致", systemImage: "checkmark.seal") { approve() }
                    Button("只重绘这一格", systemImage: "arrow.clockwise") {
                        var j = StudioJob(projectID: project.id, chapter: run.ordinal, scriptOnly: false)
                        j.panelID = panel.id
                        Task { await studio.enqueue(j) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }.disabled(studio.isWorking)
            }.font(.footnote)
            Divider()
        }
        .sheet(isPresented: $showDetails) { PanelDetails(project: project, run: run, panel: panel) }
        .sheet(isPresented: $showImage) {
            if let url = studio.assetURL(project.id, panel.imageFile) { ImagePreview(url: url, panel: panel) }
        }
        .fullScreenCover(isPresented: $showBubbleEditor) {
            BubbleEditor(projectID: project.id, chapter: run.ordinal, panel: panel)
        }
    }
    private func approve() {
        guard panel.imageFile != nil, !stale else {
            studio.error = "请先生成或更新这一格，再确认一致。"
            return
        }
        Task {
            do {
                let p = try await studio.repository.project(project.id)
                var r = try await studio.repository.chapter(
                    project.id, ordinal: run.ordinal, chunk: studio.settings.chunkCharacters)
                if let i = r.panels.firstIndex(where: { $0.id == panel.id }) {
                    r.panels[i].review = .approved
                    r.panels[i].reviewNotes = "用户已人工核对"
                    try await studio.repository.commit(p, r)
                    await studio.refresh()
                }
            } catch { studio.report(error) }
        }
    }
}
private struct PanelDetails: View {
    let project: Project, run: ChapterRun, panel: ComicPanel
    @EnvironmentObject private var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var preview = ""
    @State private var pendingJSON = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("当前配置的组合预览").font(.headline)
                    Text("人物参考顺序在实际请求时追加。若修改了档案或画师串，此处会与历史请求不同。").font(.caption).foregroundStyle(.secondary)
                    Text(preview.isEmpty ? "请先选择生图连接" : preview).font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button("复制当前组合") { UIPasteboard.general.string = preview }
                    Divider()
                    Text("最近一次实际发送").font(.headline)
                    Text(panel.lastPrompt.isEmpty ? "尚无完成的生图请求" : panel.lastPrompt).font(
                        .system(.footnote, design: .monospaced)
                    ).textSelection(.enabled)
                    Text("实际请求参数（密钥已隐藏）").font(.headline)
                    Text(pendingJSON.isEmpty ? panel.requestJSON : pendingJSON).font(
                        .system(.caption, design: .monospaced)
                    ).textSelection(.enabled)
                    Button("复制实际请求参数") {
                        UIPasteboard.general.string = pendingJSON.isEmpty ? panel.requestJSON : pendingJSON
                    }
                    Divider()
                    Text("校对记录").font(.headline)
                    Text(panel.reviewNotes.isEmpty ? panel.review.title : panel.reviewNotes)
                    Divider()
                    Text("原文依据").font(.headline)
                    ForEach(run.units.filter { panel.units.contains($0.id) }) { u in
                        Text("\(u.id)\n\(u.text)").font(.footnote)
                    }
                }.padding(24)
            }.background(Ink.paper).navigationTitle(panel.id).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task {
                    if let api = studio.profile(studio.settings.imageProfileID, text: false),
                        let effective = try? RequestBuilder.imageProfile(
                            profile: api, artist: studio.artist(for: project)),
                        let q = try? PromptComposer.compose(
                            panel: panel, project: project, artist: studio.artist(for: project), profile: effective)
                    {
                        if effective.kind == .novelAI {
                            preview =
                                q.naiBase + "\n\n"
                                + q.characters.enumerated().map { "角色\($0.offset+1)：\($0.element.prompt)" }.joined(
                                    separator: "\n") + "\n\n负面：" + q.negative
                        } else {
                            preview = q.natural
                        }
                    }
                    if let receipt = try? await studio.repository.receipt(project.id, chapter: run.ordinal),
                        receipt.target == "panel:" + panel.id
                    {
                        pendingJSON = receipt.requestJSON
                    }
                }
        }
    }
}
private struct ImagePreview: View {
    let url: URL
    let panel: ComicPanel
    @Environment(\.dismiss) private var dismiss
    @State private var bitmap: CachedBitmap?
    var body: some View {
        NavigationStack {
            Group { if let bitmap { ZoomImage(image: bitmap.image) } else { ProgressView() } }.background(.black)
                .navigationTitle("画格预览").navigationBarTitleDisplayMode(.inline).toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }.task { bitmap = try? await ComicExporter.shared.preview(url: url, panel: panel) }
        }
    }
}
private struct ZoomImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.delegate = context.coordinator
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        ])
        return scroll
    }
    func updateUIView(_ view: UIScrollView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { scrollView.subviews.first }
    }
}
