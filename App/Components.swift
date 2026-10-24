import MoxuCore
import SwiftUI
import UIKit

enum Ink {
    static let accent = Color(red: 0.76, green: 0.35, blue: 0.27)
    static let teal = Color(red: 0.27, green: 0.49, blue: 0.49)
    static let paper = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
                : UIColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1)
        })
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}
struct QuietTitle: View {
    let eyebrow: String, title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow).font(.caption.weight(.medium)).tracking(3).foregroundStyle(Ink.accent)
            Text(title).font(.system(size: 34, weight: .bold, design: .serif))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct EmptyHint: View {
    let icon: String, title: String, detail: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(detail)
        }.frame(minHeight: 220)
    }
}
struct BusyButton: View {
    let title: String, icon: String
    var busy: Bool = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                if busy { ProgressView().tint(.white) } else { Image(systemName: icon) }
                Text(title).fontWeight(.semibold)
            }.frame(maxWidth: .infinity).padding(.vertical, 8)
        }.buttonStyle(.borderedProminent).tint(Ink.accent).disabled(busy)
    }
}
struct AsyncArtwork: View {
    let url: URL?
    var side = 720
    var mode: ContentMode = .fit
    @State private var bitmap: CachedBitmap?
    var body: some View {
        Group {
            if let bitmap {
                Image(uiImage: bitmap.image).resizable().aspectRatio(contentMode: mode)
            } else {
                Rectangle().fill(Ink.teal.opacity(0.08)).overlay {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(Ink.teal.opacity(0.35))
                }
            }
        }.task(id: "\(url?.path ?? "")/\(side)") {
            bitmap = nil
            guard let url else { return }
            let value = try? await BitmapCache.shared.load(url, side: side)
            if !Task.isCancelled { bitmap = value }
        }
    }
}
struct SheetTextEditor: View {
    let title: String, detail: String
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }.padding().background(Ink.paper).navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
extension ReviewState {
    var title: String {
        switch self {
        case .notGenerated: return "未出图"
        case .pending: return "待人工校对"
        case .approved: return "已确认一致"
        case .mismatch: return "发现画面差异"
        case .assistedPass: return "视觉辅助检查通过"
        }
    }
    var color: Color {
        switch self {
        case .approved, .assistedPass: return Ink.teal
        case .mismatch: return .orange
        default: return .secondary
        }
    }
}
extension JobState {
    var title: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "制作中"
        case .paused: return "已暂停"
        case .finished: return "已完成"
        case .failed: return "需处理"
        case .needsReview: return "请求待核实"
        }
    }
}
