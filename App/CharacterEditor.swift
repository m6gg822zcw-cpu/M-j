import MoxuCore
import PhotosUI
import SwiftUI

struct CharacterEditor: View {
    @EnvironmentObject private var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    private let initial: CharacterCard
    @State private var draft: CharacterCard
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var saving = false
    @State private var uploaded = false
    @State private var addingStage = false
    @State private var stageName = ""
    private let identityFields = [
        ("gender", "性别"), ("age", "年龄"), ("species", "物种"), ("height", "身高"), ("build", "体型"), ("skin", "肤色"),
        ("face", "脸型"), ("hair", "发型 / 发色"), ("eyes", "眼睛"), ("marks", "痣、疤痕等辨识点"),
    ]
    init(projectID: UUID, card: CharacterCard) {
        self.projectID = projectID
        self.initial = card
        _draft = State(initialValue: card)
    }
    var body: some View {
        Form {
            Section {
                AsyncArtwork(url: studio.assetURL(projectID, draft.referenceFile), side: 1000).frame(height: 280).frame(
                    maxWidth: .infinity)
                HStack {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label(importing ? "正在导入…" : "上传定妆 / 人物参考", systemImage: "photo.on.rectangle")
                    }.disabled(importing)
                    Spacer()
                    if draft.referenceFile != nil {
                        Button(role: .destructive) {
                            draft.referenceFile = nil
                            uploaded = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                Button {
                    save(generate: true)
                } label: {
                    Label("用当前生图连接生成定妆图", systemImage: "sparkles")
                }.disabled(saving || importing)
            } footer: {
                Text("上传清晰的单人参考或多视图设定。定妆图固定脸与体型，剧情衣装独立替换。生成定妆图会调用生图 API。")
            }
            Section("身份层 · 跨章固定") {
                TextField("姓名", text: $draft.name)
                TextField("年龄 / 变身阶段", text: $draft.stage)
                TextField(
                    "别名，用逗号分隔",
                    text: Binding(
                        get: { draft.aliases.joined(separator: ",") },
                        set: {
                            draft.aliases = $0.components(separatedBy: CharacterSet(charactersIn: ",，")).filter {
                                !$0.isEmpty
                            }
                        }))
                ForEach(identityFields, id: \.0) { key, label in
                    TextField(label, text: identity(key), axis: .vertical).lineLimit(1...4)
                }
            }
            Section {
                TextEditor(text: $draft.naiIdentity).frame(minHeight: 100).font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("NAI 固定身份标签 · 英文")
            } footer: {
                Text("只写物种、年龄、脸、头发、眼睛、体型等固定特征。衣服、姿势、画师串在其他层保存。")
            }
            Section("服装层 · 纸娃娃衣柜") {
                ForEach($draft.costumes) { $costume in
                    NavigationLink {
                        CostumeEditor(costume: $costume)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(costume.name)
                            Text(costume.layers["top"] ?? costume.key).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("添加另一套服装", systemImage: "plus") {
                    draft.costumes.append(
                        Costume(
                            key: "outfit-" + UUID().uuidString.prefix(8), name: "新衣装",
                            layers: [
                                "base": "不透明基础衣装", "top": "待设定", "bottom": "待设定", "outer": "无", "footwear": "鞋",
                                "accessories": "无",
                            ],
                            naiLayers: [
                                "base": "undershirt", "top": "shirt", "bottom": "pants", "outer": "none",
                                "footwear": "shoes", "accessories": "none",
                            ]))
                }
            }
            Section("原著与制作补设") {
                TextEditor(text: $draft.designNotes).frame(minHeight: 85)
                ForEach(Array(draft.evidence.enumerated()), id: \.offset) { _, ev in
                    Text("\(ev.unit) · \(ev.quote)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("新增年龄 / 变身阶段", systemImage: "person.crop.rectangle.stack") { addingStage = true }
            } footer: {
                Text("新阶段另建身份档案并关联同一人物，不覆盖旧阶段的脸。修改本页固定身份后，旧定妆图将失效；已有漫画保留并标记待更新。")
            }
        }
        .scrollContentBackground(.hidden).background(Ink.paper).disabled(studio.isWorking || saving)
        .navigationTitle(draft.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中…" : "保存") { save() }.disabled(studio.isWorking || saving || importing)
            }
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .alert("新建独立阶段", isPresented: $addingStage) {
            TextField("例如：成年常态 / 少年", text: $stageName)
            Button("创建") { save(newStage: stageName) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("复制外观作为编辑起点，新阶段使用独立编号与定妆参考。")
        }
        .safeAreaInset(edge: .bottom) {
            if studio.isWorking {
                Text("制作进行中，档案暂时只读").font(.caption).frame(maxWidth: .infinity).padding(10).background(.regularMaterial)
            }
        }
    }
    private func identity(_ key: String) -> Binding<String> {
        Binding(get: { draft.identity[key] ?? "" }, set: { draft.identity[key] = $0 })
    }
    private func importPhoto(_ item: PhotosPickerItem) async {
        importing = true
        defer { importing = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), data.count <= 64 * 1024 * 1024 else {
                throw StudioError.invalid("参考图为空或超过64MB。")
            }
            let normalized = try await studio.processor.normalize(data)
            let path = "Images/upload-\(UUID().uuidString).png"
            try await studio.repository.saveAsset(projectID, path: path, data: normalized)
            draft.referenceFile = path
            uploaded = true
        } catch { studio.report(error) }
    }
    private func save(generate: Bool = false, newStage: String? = nil) {
        guard !studio.isWorking, !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !draft.stage.isEmpty, !draft.naiIdentity.isEmpty
        else {
            studio.error = "请填写姓名、阶段与 NAI 固定身份标签。"
            return
        }
        if let newStage, newStage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            studio.error = "请输入新阶段名称。"
            return
        }
        saving = true
        Task {
            do {
                var project = try await studio.repository.project(projectID)
                var card = draft
                let changed =
                    card.identity != initial.identity || card.naiIdentity != initial.naiIdentity
                    || card.stage != initial.stage
                if changed {
                    card.revision = initial.revision + 1
                    if !uploaded { card.referenceFile = nil }
                }
                if let newStage {
                    card.id = UUID()
                    card.stage = newStage
                    card.revision = 1
                    card.referenceFile = nil
                }
                if project.characters.contains(where: {
                    $0.id != card.id && $0.name == card.name && $0.stage == card.stage
                }) {
                    throw StudioError.invalid("此姓名与阶段已有档案，请编辑现有档案。")
                }
                if let i = project.characters.firstIndex(where: { $0.id == card.id }) {
                    project.characters[i] = card
                } else {
                    project.characters.append(card)
                }
                try await studio.repository.save(project)
                await studio.refresh()
                if generate {
                    var job = StudioJob(projectID: projectID, chapter: 1, scriptOnly: false)
                    job.referenceCharacterID = card.id
                    await studio.enqueue(job)
                }
                dismiss()
            } catch { studio.report(error) }
            saving = false
        }
    }
}

private struct CostumeEditor: View {
    @Binding var costume: Costume
    private let layers = [
        ("base", "基础内层"), ("top", "上装"), ("bottom", "下装"), ("outer", "外套"), ("footwear", "鞋袜"), ("accessories", "配饰"),
    ]
    var body: some View {
        Form {
            Section {
                TextField("衣装名称", text: $costume.name)
                LabeledContent("固定编号", value: costume.key).font(.caption)
            }
            ForEach(layers, id: \.0) { key, label in
                Section(label) {
                    TextField("中文外观", text: binding(key, nai: false), axis: .vertical).lineLimit(1...4)
                    TextField("NAI 英文标签", text: binding(key, nai: true), axis: .vertical).font(
                        .system(.footnote, design: .monospaced)
                    ).textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(1...5)
                }
            }
            Section {
                TextEditor(text: $costume.naiTags).font(.system(.footnote, design: .monospaced)).frame(minHeight: 80)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("通用衣装标签")
            } footer: {
                Text("可穿脱的物品应写入各层；通用标签只写材质、时代等整体特征，避免脱下外套后仍被重复画出。无该部件请写 none。")
            }
        }.scrollContentBackground(.hidden).background(Ink.paper).navigationTitle("纸娃娃 · \(costume.name)")
            .navigationBarTitleDisplayMode(.inline)
    }
    private func binding(_ key: String, nai: Bool) -> Binding<String> {
        Binding(
            get: { (nai ? costume.naiLayers : costume.layers)[key] ?? "" },
            set: { if nai { costume.naiLayers[key] = $0 } else { costume.layers[key] = $0 } })
    }
}
