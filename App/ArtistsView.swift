import MoxuCore
import SwiftUI

struct ArtistsView: View {
    @EnvironmentObject private var studio: StudioModel
    @State private var adding = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    QuietTitle(eyebrow: "风格书签", title: "你的画师串，原样保留。", subtitle: "每个平台可以绑定自己的方案，作品也可以单独选择。")
                    ForEach(studio.settings.artists) { preset in
                        NavigationLink {
                            ArtistEditor(preset: preset)
                        } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(preset.name).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right").foregroundStyle(Ink.accent)
                                }
                                Text(preset.positive.isEmpty ? "添加正面、负面、人物与背景四组串" : preset.positive).font(
                                    .system(.footnote, design: .monospaced)
                                ).lineLimit(3).foregroundStyle(.secondary).frame(
                                    maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Text("正面 \(preset.positive.count) 字符")
                                    Text("人物 \(preset.character.count) 字符")
                                    Spacer()
                                    Text("v\(preset.revision)")
                                }.font(.caption).foregroundStyle(.secondary)
                                Divider()
                            }
                        }.buttonStyle(.plain)
                    }
                    Button("新建画师方案", systemImage: "plus") { adding = true }.buttonStyle(.bordered).tint(Ink.accent)
                    Text("画师串不会交给文本模型翻译、去重或重排。NAI 的括号与权重语法原样发送；自然语言平台只会把原串作为画风要求，支持程度取决于该平台。").font(.footnote)
                        .foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 850)
            }.background(Ink.paper).navigationTitle("画师串").navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $adding) { NavigationStack { ArtistEditor(preset: ArtistPreset()) } }
        }
    }
}

struct ArtistEditor: View {
    @EnvironmentObject private var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State var preset: ArtistPreset
    @State private var editing = 0
    @State private var showEditor = false
    @State private var saving = false
    private let names = ["正面画师串", "负面串", "人物附加串", "背景附加串"]
    var body: some View {
        Form {
            Section { TextField("方案名称", text: $preset.name) }
            Section {
                ForEach(0..<4, id: \.self) { index in
                    Button {
                        editing = index
                        showEditor = true
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(names[index]).foregroundStyle(.primary)
                                Spacer()
                                Text("\(text(index).wrappedValue.count) 字符").font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(text(index).wrappedValue.isEmpty ? "点此输入，支持换行与原始权重语法" : text(index).wrappedValue).font(
                                .system(.footnote, design: .monospaced)
                            ).foregroundStyle(.secondary).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } footer: {
                Text("保存时保留原有空格、换行、标签顺序和权重，不静默改写。人物串按角色附加，背景串进入场景提示。")
            }
            Section("画面指导 · 给分镜导演") {
                TextEditor(text: $preset.guidance).frame(minHeight: 100)
                Text("这里可写线条、上色、画幅与叙事偏好；四组原始画师串不会进入人物提取请求。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("拼接顺序", selection: $preset.placement) {
                    Text("剧情与身份在前，画风在后").tag(ArtistPlacement.afterFacts)
                    Text("画风在前，剧情与身份在后").tag(ArtistPlacement.beforeFacts)
                }
            } footer: {
                Text("默认优先明确剧情与固定身份。更改方案后旧图仍保留，漫画页会提示待更新。")
            }
            Section {
                Button("复制为新方案", systemImage: "doc.on.doc") {
                    var copy = preset
                    copy.id = UUID()
                    copy.name += " · 副本"
                    copy.revision = 0
                    save(copy)
                }
            }
        }
        .scrollContentBackground(.hidden).background(Ink.paper).navigationTitle("编辑画师串").navigationBarTitleDisplayMode(
            .inline
        )
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中…" : "保存") { save(preset) }.disabled(saving || studio.isWorking)
            }
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        }
        .sheet(isPresented: $showEditor) {
            SheetTextEditor(title: names[editing], detail: "按原文保存。可直接粘贴长串，不会自动翻译或整理。", text: text(editing))
        }
        .disabled(saving || studio.isWorking)
    }
    private func text(_ index: Int) -> Binding<String> {
        switch index {
        case 0: return $preset.positive
        case 1: return $preset.negative
        case 2: return $preset.character
        default: return $preset.background
        }
    }
    private func save(_ value: ArtistPreset) {
        guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            studio.error = "请填写方案名称。"
            return
        }
        saving = true
        Task {
            do {
                try await studio.saveArtist(value)
                dismiss()
            } catch { studio.report(error) }
            saving = false
        }
    }
}
