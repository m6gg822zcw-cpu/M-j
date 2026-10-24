import MoxuCore
import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject private var studio: StudioModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var draft: APIProfile?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("模型各司其职").font(.title2.bold())
                        Text("文本负责分镜与记忆，生图负责画面。每条连接独立保存地址、模型、密钥与画师方案。").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Section("默认连接") {
                    Picker("文本模型", selection: setting(\.textProfileID)) {
                        Text("未选择").tag(Optional<UUID>.none)
                        ForEach(studio.settings.profiles.filter { $0.kind.isText }) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    Picker("生图模型", selection: setting(\.imageProfileID)) {
                        Text("未选择").tag(Optional<UUID>.none)
                        ForEach(studio.settings.profiles.filter { !$0.kind.isText }) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                }
                Section("已保存的连接") {
                    ForEach(studio.settings.profiles) { p in
                        NavigationLink {
                            APIProfileEditor(profile: p)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: p.kind.isText ? "text.bubble" : "paintbrush.pointed").foregroundStyle(
                                    p.kind.isText ? Ink.teal : Ink.accent
                                ).frame(width: 26)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(p.name)
                                    Text(p.model.isEmpty ? p.kind.title : p.model).font(.caption).foregroundStyle(
                                        .secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    Menu {
                        ForEach(APIKind.allCases) { kind in
                            Button(kind.title) {
                                var value = APIProfile()
                                value.kind = kind
                                value.name = kind.title
                                value.baseURL = kind.defaultBase
                                if kind == .responses { value.temperature = nil }
                                if kind == .novelAI { value.model = "nai-diffusion-4-5-full" }
                                draft = value
                            }
                        }
                    } label: {
                        Label("添加 API 连接", systemImage: "plus")
                    }
                }
                Section {
                    Stepper(
                        "每批约 \(studio.settings.chunkCharacters) 字符", value: setting(\.chunkCharacters), in: 1500...6000,
                        step: 500)
                    TextField("可选：自定义章标题正则", text: setting(\.headingPattern), axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(
                            .system(.footnote, design: .monospaced))
                    Toggle("出图后进行视觉辅助检查", isOn: setting(\.performVisionCheck)).tint(Ink.accent)
                    if studio.settings.performVisionCheck {
                        Picker("支持图片输入的文本模型", selection: setting(\.visionProfileID)) {
                            Text("跟随默认文本模型").tag(Optional<UUID>.none)
                            ForEach(studio.settings.profiles.filter { $0.kind.isText }) { p in
                                Text(p.name).tag(Optional(p.id))
                            }
                        }
                    }
                } header: {
                    Text("生成与检查")
                } footer: {
                    Text("视觉检查额外调用文本 API，只标记差异，不自动重绘。每批分镜、每张图片完成后保存。iOS 后台时间有限，离开应用会在当前请求保存后暂停。")
                }
                Section("外观") {
                    Picker("显示模式", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色纸张").tag("light")
                        Text("深色墨页").tag("dark")
                    }
                }
                Section {
                    Text("密钥仅保存在本机 Keychain，不写入工程备份。支持上述接口格式的平台可填写自定义地址；独有协议需要另加适配器。").font(.footnote).foregroundStyle(
                        .secondary)
                }
            }.scrollContentBackground(.hidden).background(Ink.paper).navigationTitle("API 连接")
                .navigationBarTitleDisplayMode(.inline)
                .disabled(studio.isWorking)
                .sheet(item: $draft) { profile in NavigationStack { APIProfileEditor(profile: profile) } }
        }
    }
    private func setting<T>(_ path: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { studio.settings[keyPath: path] },
            set: { value in
                var s = studio.settings
                s[keyPath: path] = value
                Task { do { try await studio.saveSettings(s) } catch { studio.report(error) } }
            })
    }
}

struct APIProfileEditor: View {
    @EnvironmentObject private var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State var profile: APIProfile
    @State private var token = ""
    @State private var models: [String] = []
    @State private var status = ""
    @State private var busy = false
    @State private var loaded = false
    @State private var showAdvanced = false
    @State private var initialBase = ""
    var body: some View {
        Form {
            Section("连接") {
                TextField("名称", text: $profile.name)
                LabeledContent("接口格式", value: profile.kind.title)
                TextField("API 根地址或完整接口", text: $profile.baseURL, axis: .vertical).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(1...3)
                SecureField("API Key / Bearer Token", text: $token).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().privacySensitive()
                TextField("模型 ID", text: $profile.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(profile.kind == .novelAI ? "查看 NAI 内置模型候选" : "读取平台模型列表") { fetchModels() }.disabled(busy)
                if !models.isEmpty {
                    Picker("从候选选择", selection: $profile.model) {
                        Text("手动填写 / 当前值").tag(profile.model)
                        ForEach(models.filter { $0 != profile.model }, id: \.self) { Text($0).tag($0) }
                    }
                }
                if profile.kind.isText {
                    Button("发送一条文本测试") { testText() }.disabled(busy)
                    Text("测试会发送极短文本请求，可能产生少量费用。").font(.caption).foregroundStyle(.secondary)
                }
                if busy { ProgressView() }
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if profile.kind.isText { textSettings } else { imageSettings }
            Section {
                Toggle("允许 HTTP 地址", isOn: $profile.allowHTTP)
            } footer: {
                Text("默认要求 HTTPS。仅在你信任的自建或局域网服务需要 HTTP 时开启。密钥会发往你填写的地址，改变主地址会清空编辑框中的原密钥。")
            }
            Section {
                Button("编辑高级 JSON 参数") { showAdvanced = true }
                Text(profile.extraJSON).font(.system(.caption, design: .monospaced)).lineLimit(4).foregroundStyle(
                    .secondary)
            } footer: {
                Text(
                    "用于平台支持的 quality、output_format、reasoning 等扩展字段。不允许覆盖模型、提示词、参考图与密钥。NAI 扩展写在 parameters 内；其他平台写在请求顶层。"
                )
            }
        }
        .scrollContentBackground(.hidden).background(Ink.paper).navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }.disabled(busy || studio.isWorking || !loaded)
            }
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        }
        .task {
            guard !loaded else { return }
            initialBase = profile.baseURL
            do { token = try await studio.vault.value(profile.id) } catch { studio.report(error) }
            loaded = true
        }
        .onChange(of: profile.baseURL) { _, _ in if loaded, profile.baseURL != initialBase { token = "" } }
        .sheet(isPresented: $showAdvanced) {
            SheetTextEditor(title: "高级请求参数", detail: "输入一个 JSON 对象。留空参数使用 {}。不要在这里填写密钥。", text: $profile.extraJSON)
        }
    }
    @ViewBuilder private var textSettings: some View {
        Section("文本生成") {
            Stepper("最大输出 \(profile.textMaxTokens) tokens", value: $profile.textMaxTokens, in: 4000...64000, step: 2000)
            if profile.kind == .chat {
                Picker("输出上限字段", selection: $profile.textTokenField) {
                    Text("max_tokens · 通用兼容").tag("max_tokens")
                    Text("max_completion_tokens · 推理模型").tag("max_completion_tokens")
                }
            }
            Toggle(
                "发送 temperature",
                isOn: Binding(get: { profile.temperature != nil }, set: { profile.temperature = $0 ? 0.3 : nil }))
            if profile.temperature != nil {
                HStack {
                    Text("Temperature")
                    Slider(
                        value: Binding(get: { profile.temperature ?? 0.3 }, set: { profile.temperature = $0 }),
                        in: 0...1, step: 0.05)
                    Text(String(format: "%.2f", profile.temperature ?? 0.3)).monospacedDigit()
                }
            }
        }
    }
    @ViewBuilder private var imageSettings: some View {
        Section("独立画师方案") {
            Picker("默认画师串", selection: $profile.artistPresetID) {
                Text("使用首个方案").tag(Optional<UUID>.none)
                ForEach(studio.settings.artists) { a in Text(a.name).tag(Optional(a.id)) }
            }
        }
        if profile.kind != .geminiImage {
            Section("画幅") {
                HStack {
                    Text("宽")
                    Spacer()
                    TextField("宽度", value: $profile.width, format: .number).keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("高")
                    Spacer()
                    TextField("高度", value: $profile.height, format: .number).keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("方形") {
                        profile.width = 1024
                        profile.height = 1024
                    }
                    Spacer()
                    Button("竖页") {
                        profile.width = 1024
                        profile.height = profile.kind == .novelAI ? 1536 : 1536
                    }
                    Spacer()
                    Button("横幅") {
                        profile.width = 1536
                        profile.height = 1024
                    }
                }
            }
        }
        if profile.kind == .novelAI {
            naiSettings
        } else {
            Section {
                Toggle("发送人物参考图", isOn: $profile.useImageReferences)
                Stepper("一次最多 \(profile.maxReferences) 张参考", value: $profile.maxReferences, in: 1...8)
                if profile.kind == .openAIImage {
                    TextField("可选：完整图像编辑接口", text: $profile.editURL, axis: .vertical).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(1...3)
                }
            } header: {
                Text("人物参考")
            } footer: {
                Text(
                    "有参考图时，OpenAI 兼容接口调用 images/edits（multipart image[]）；Gemini 发送 inlineData。平台必须支持对应模型的多图输入，超过设定数量时合成编号对照板。自动补建缺失定妆图也会调用生图 API。"
                )
            }
        }
    }
    @ViewBuilder private var naiSettings: some View {
        Section("NAI 参数") {
            Stepper("步数 \(profile.steps)", value: $profile.steps, in: 1...50)
            HStack {
                Text("CFG \(profile.guidance, specifier:"%.1f")")
                Slider(value: $profile.guidance, in: 1...10, step: 0.1)
            }
            TextField("采样器，例如 k_euler_ancestral", text: $profile.sampler).textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("噪声调度，例如 karras", text: $profile.noiseSchedule).textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("固定随机种子", isOn: Binding(get: { profile.seed != nil }, set: { profile.seed = $0 ? 1 : nil }))
            if profile.seed != nil {
                TextField(
                    "Seed", text: Binding(get: { String(profile.seed ?? 1) }, set: { profile.seed = UInt32($0) ?? 1 })
                ).keyboardType(.numberPad)
            }
        }
        Section {
            Picker("参考方式", selection: $profile.referenceMode) {
                Text("固定身份与独立角色标签").tag(APIProfile.ReferenceMode.off)
                Text("精确参考 · 实验性").tag(APIProfile.ReferenceMode.precise)
                Text("图生图 · 单人物").tag(APIProfile.ReferenceMode.imageToImage)
            }
            if profile.referenceMode != .off {
                HStack {
                    Text("强度 \(profile.referenceStrength,specifier:"%.2f")")
                    Slider(value: $profile.referenceStrength, in: 0...1, step: 0.05)
                }
            }
            if profile.referenceMode == .precise {
                HStack {
                    Text("保真度 \(profile.referenceFidelity,specifier:"%.2f")")
                    Slider(value: $profile.referenceFidelity, in: 0...1, step: 0.05)
                }
            }
        } header: {
            Text("NAI 人物一致性")
        } footer: {
            Text(
                "默认使用 V4 系列独立角色提示词，本适配器每格最多6人。精确参考仅开放 V4.5 单人物，参数尚未进行实机 API 验证，默认关闭；多人镜头继续使用独立提示词，避免多张精确参考混脸。标签和参考均不能保证绝对一致，请逐格核对。"
            )
        }
    }
    private func validate() throws {
        guard !profile.name.isEmpty, !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioError.invalid("请填写名称与模型 ID。")
        }
        _ = try RequestBuilder.endpoint(profile, suffix: "models")
        guard let data = profile.extraJSON.data(using: .utf8),
            (try JSONSerialization.jsonObject(with: data)) is [String: Any]
        else { throw StudioError.invalid("高级参数必须为 JSON 对象。") }
        if !profile.editURL.isEmpty {
            _ = try RequestBuilder.endpoint(profile, suffix: "images/edits", override: profile.editURL)
        }
        if profile.kind == .novelAI {
            guard profile.width % 64 == 0, profile.height % 64 == 0, profile.width >= 64, profile.height >= 64,
                profile.width <= 2048, profile.height <= 2048
            else { throw StudioError.invalid("NAI 宽高须为64的倍数，且在64—2048之间。") }
        }
    }
    private func save() {
        do { try validate() } catch {
            studio.report(error)
            return
        }
        busy = true
        Task {
            do {
                try await studio.saveProfile(profile, token: token)
                dismiss()
            } catch { studio.report(error) }
            busy = false
        }
    }
    private func fetchModels() {
        busy = true
        status = ""
        Task {
            do {
                models = try await studio.client.models(profile: profile, token: token)
                status =
                    models.isEmpty
                    ? "接口未提供模型列表，请手动填写模型 ID。"
                    : profile.kind == .novelAI ? "这是内置候选，未发送网络请求；可手动填写平台支持的其他 ID。" : "已读取 \(models.count) 个模型。"
            } catch { status = error.localizedDescription }
            busy = false
        }
    }
    private func testText() {
        do { try validate() } catch {
            studio.report(error)
            return
        }
        busy = true
        status = ""
        var test = profile
        test.textMaxTokens = 64
        Task {
            do {
                status = "连接返回：" + (try await studio.client.complete(profile: test, token: token, prompt: "只回复：墨序连接成功"))
            } catch { status = error.localizedDescription }
            busy = false
        }
    }
}
