import MoxuCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var studio: StudioModel
    @State private var importing = false
    @State private var pickerSessionID = UUID()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                QuietTitle(eyebrow: "墨序 · 小说漫画工作室", title: "把文字，\n画成一部漫画。", subtitle: "让每个章节，拥有自己的镜头。\n让每个人物，始终是同一个人。")
                HStack {
                    Label("\(studio.projects.count) 部作品", systemImage: "books.vertical")
                    Spacer()
                    Label("本地保存", systemImage: "externaldrive")
                }.font(.caption).foregroundStyle(.secondary)
                BusyButton(title: studio.importing ? "正在读取书稿…" : "导入小说 / 工程", icon: "plus", busy: studio.importing) {
                    pickerSessionID = UUID()
                    importing = true
                }.accessibilityIdentifier("novel-import-primary-button")
                if let notice = studio.importNotice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(Ink.teal)
                        .accessibilityIdentifier("import-success")
                }
                Button("离线试用气泡编辑", systemImage: "bubble.left.and.text.bubble.right") {
                    Task { await studio.importLetteringDemo() }
                }.font(.footnote).disabled(studio.importing)
                if studio.loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if studio.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("从第一章开始").font(.title2.bold())
                        Text("支持 TXT、Markdown、EPUB、DOCX、文字 PDF 和章节 JSON。也能恢复 .moxu 工程。原文只按当前批次发送到你配置的文本服务。").font(
                            .subheadline
                        ).foregroundStyle(.secondary)
                        Button("试用一份示例书稿（不联网）") { Task { await studio.importSample() } }
                            .buttonStyle(.bordered).disabled(studio.importing)
                    }.padding(.vertical, 14)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(studio.projects) { p in
                            NavigationLink {
                                WorkspaceView(projectID: p.id)
                            } label: {
                                BookRow(project: p)
                            }.buttonStyle(.plain)
                            Divider().padding(.vertical, 20)
                        }
                    }
                }
                if !studio.isWorking {
                    Text("先配置文本与生图连接，再挑选或填写自己的画师串。你也可以只制作分镜，校准人物后再开始出图。").font(.footnote).foregroundStyle(.secondary)
                        .padding(.vertical, 14)
                }
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")）")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("app-version")
            }.padding(24).frame(maxWidth: 900)
        }.background(Ink.paper).navigationTitle("书架").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        pickerSessionID = UUID()
                        importing = true
                    } label: {
                        Image(systemName: "plus")
                    }.accessibilityLabel("导入小说").accessibilityIdentifier("novel-import-button")
                        .disabled(studio.importing)
                }
            }
            .sheet(isPresented: $importing) {
                NovelDocumentPicker(onPick: { urls in
                    importing = false
                    guard let url = urls.first else { return }
                    #if DEBUG
                        PickerUITestTrace.record("view.selected")
                    #endif
                    // The system picker can dismiss itself before SwiftUI calls onDismiss.
                    // Deliver the selected file directly from its delegate callback.
                    Task { await studio.importFile(url) }
                }, onCancel: {
                    importing = false
                }).id(pickerSessionID).ignoresSafeArea()
            }
    }
}
private struct BookRow: View {
    let project: ProjectSummary
    var body: some View {
        HStack(spacing: 18) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 7).fill(
                    LinearGradient(
                        colors: [Ink.teal.opacity(0.9), Color(red: 0.11, green: 0.23, blue: 0.26)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                Rectangle().fill(.white.opacity(0.2)).frame(width: 1).padding(.leading, 9)
                Text(String(project.title.prefix(5))).font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(.white).padding(13)
            }.frame(width: 86, height: 117).shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
            VStack(alignment: .leading, spacing: 9) {
                Text(project.title).font(.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                Text("\(project.chapterCount) 章 · \(project.characters) 位人物").font(.caption).foregroundStyle(.secondary)
                Label("已绘制 \(project.drawn) 格", systemImage: "square.grid.2x2").font(.caption).foregroundStyle(Ink.teal)
                Text(project.updated, style: .date).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }
}
