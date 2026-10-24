import MoxuCore
import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var studio: StudioModel
    @State private var retry: StudioJob?
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    QuietTitle(eyebrow: "慢慢画，稳稳存", title: "制作队列", subtitle: "按顺序处理章节，保留每批分镜和每张图片的完成记录。")
                    if studio.jobs.isEmpty { EmptyHint(icon: "tray", title: "目前没有任务", detail: "从书架打开小说，选择章节后开始制作。") }
                    ForEach(studio.jobs.reversed()) { job in
                        VStack(alignment: .leading, spacing: 13) {
                            HStack {
                                Text(title(job)).font(.headline)
                                Spacer()
                                Text(job.state.title).font(.caption.weight(.medium)).foregroundStyle(
                                    job.state == .finished ? Ink.teal : job.state == .needsReview ? .orange : Ink.accent
                                )
                            }
                            HStack {
                                Text("第 \(job.chapter) 章")
                                Text(
                                    job.referenceCharacterID != nil
                                        ? "人物定妆"
                                        : job.panelID != nil ? "重绘 \(job.panelID!)" : job.scriptOnly ? "分镜脚本" : "分镜与出图")
                            }.font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: job.progress).tint(Ink.accent)
                            Text(job.message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack {
                                if [.running, .queued].contains(job.state) {
                                    Button("暂停", systemImage: "pause") { Task { await studio.pause(job.id) } }
                                }
                                if [.paused, .failed, .needsReview].contains(job.state) {
                                    Button(job.state == .needsReview ? "检查本地断点" : "继续制作", systemImage: "play") {
                                        Task { await studio.resume(job.id) }
                                    }
                                }
                                if job.state == .needsReview {
                                    Spacer()
                                    Button("核实后重新请求") { retry = job }.foregroundStyle(.orange)
                                }
                            }.font(.footnote)
                            Divider()
                        }
                    }
                    Text("图片请求超时或返回情况不明确时会停止自动提交。先在服务平台核实是否已生成，再决定重试，避免重复扣费。后台保存时间由 iOS 决定，关闭应用后任务不会持续运行。").font(
                        .footnote
                    ).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 850)
            }.background(Ink.paper).navigationTitle("任务").navigationBarTitleDisplayMode(.inline)
                .confirmationDialog(
                    "重新提交图片请求？", isPresented: Binding(get: { retry != nil }, set: { if !$0 { retry = nil } }),
                    titleVisibility: .visible
                ) {
                    if let retry {
                        Button("确认已核实，重新请求（可能计费）") {
                            Task { await studio.resume(retry.id, authorizeRetry: true) }
                            self.retry = nil
                        }
                    }
                    Button("取消", role: .cancel) { retry = nil }
                } message: {
                    Text("本机没有能直接使用的完成记录时，将向平台再次发送请求。旧请求可能已经计费。")
                }
        }
    }
    private func title(_ job: StudioJob) -> String {
        studio.projects.first(where: { $0.id == job.projectID })?.title ?? "小说工程"
    }
}
