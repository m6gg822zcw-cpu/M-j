import SwiftUI

struct PasteNovelSheet: View {
    @EnvironmentObject private var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var submitting = false
    @State private var imported = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case title, body }
    private var busy: Bool { submitting || studio.importing }
    private var hasBody: Bool { text.contains { !$0.isWhitespace } }

    var body: some View {
        NavigationStack {
            Form {
                Section("书名（可选）") {
                    TextField("留空时使用「粘贴的书稿」", text: $title)
                        .accessibilityIdentifier("novel-paste-title")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .title)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .disabled(busy)
                }
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        guard !busy else { return }
                        text = strings.joined(separator: "\n\n")
                        focusedField = nil
                        studio.error = nil
                    }
                    .accessibilityIdentifier("novel-paste-insert")
                    .disabled(busy)
                    TextEditor(text: $text)
                        .accessibilityIdentifier("novel-paste-body")
                        .focused($focusedField, equals: .body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 300)
                        .disabled(busy)
                } header: {
                    Text("小说正文")
                } footer: {
                    Text("先复制小说正文，再点「粘贴」；也可以直接输入或长按正文框粘贴。正文最多 16MB，长篇可以分卷导入；导入后按章节保存在本机。")
                }
                if let error = studio.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("novel-paste-error")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Ink.paper)
            .navigationTitle("粘贴小说")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) {
                        studio.error = nil
                        dismiss()
                    }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "导入中…" : "导入") {
                        guard !busy else { return }
                        focusedField = nil
                        submitting = true
                        Task {
                            let success = await studio.importText(title: title, text: text)
                            submitting = false
                            if success {
                                imported = true
                                dismiss()
                            }
                        }
                    }
                    .accessibilityIdentifier("novel-paste-confirm")
                    .disabled(busy || !hasBody)
                }
            }
            .interactiveDismissDisabled(busy)
            .onAppear { studio.error = nil }
            .onDisappear { if !imported { studio.error = nil } }
        }
    }
}
