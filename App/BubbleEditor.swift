import MoxuCore
import SwiftUI

struct BubbleEditor: View {
    @EnvironmentObject private var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let projectID: UUID
    let chapter: Int
    @State private var panel: ComicPanel
    @State private var bitmap: CachedBitmap?
    @State private var draft = ComicLettering(bubbles: [])
    @State private var baseline: ComicLettering?
    @State private var selectedID: String?
    @State private var undoStack: [ComicLettering] = []
    @State private var redoStack: [ComicLettering] = []
    @State private var interaction: Interaction?
    @State private var interactionStart: ComicLettering?
    @State private var loading = true
    @State private var saving = false
    @State private var closePrompt = false
    @State private var localError: String?
    @FocusState private var textFocused: Bool
    private enum Interaction { case text, gesture, slider }
    init(projectID: UUID, chapter: Int, panel: ComicPanel) {
        self.projectID = projectID
        self.chapter = chapter
        _panel = State(initialValue: panel)
    }
    private var aspect: Double {
        guard let bitmap else { return 1 }
        return Double(bitmap.image.size.width / max(1, bitmap.image.size.height))
    }
    private var selected: ComicBubble? { draft.bubbles.first { $0.id == selectedID } }
    private var changed: Bool { baseline.map { $0 != draft } ?? false }
    private var overflow: Set<String> { Set(BubblePainter.overflowing(draft, aspect: aspect)) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                bubbleStrip
                GeometryReader { geometry in
                    if geometry.size.width >= 700 || verticalSizeClass == .compact {
                        HStack(spacing: 0) {
                            canvas
                            Divider()
                            inspector.frame(width: min(380, geometry.size.width * 0.40))
                        }
                    } else {
                        VStack(spacing: 0) {
                            canvas
                            Divider()
                            inspector.frame(height: min(290, geometry.size.height * 0.47))
                        }
                    }
                }
            }
            .background(Ink.paper)
            .navigationTitle("气泡排版 · \(panel.id)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { requestClose() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { save() }.disabled(
                        loading || saving || bitmap == nil || studio.isWorking)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }.disabled(undoStack.isEmpty && interactionStart == nil).accessibilityLabel("撤销")
                    Button {
                        redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }.disabled(redoStack.isEmpty).accessibilityLabel("重做")
                    Spacer()
                    Button("新气泡", systemImage: "plus") { addBubble() }.disabled(
                        draft.bubbles.count >= 50 || bitmap == nil)
                    Menu {
                        Button("恢复原对白布局", systemImage: "arrow.counterclockwise") { reset() }
                        if selected != nil {
                            Button("放到最上层", systemImage: "square.3.layers.3d.top.filled") { bringToFront() }
                            Button(role: .destructive) {
                                removeSelected()
                            } label: {
                                Label("删除选中气泡", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }.accessibilityLabel("气泡操作")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") {
                        textFocused = false
                        finishInteraction()
                    }
                }
            }
            .task { await load() }
            .onChange(of: textFocused) { _, focused in if !focused, interaction == .text { finishInteraction() } }
            .interactiveDismissDisabled(changed || saving)
            .confirmationDialog("气泡修改尚未保存", isPresented: $closePrompt, titleVisibility: .visible) {
                Button("保存并关闭") { save() }
                Button("放弃本次修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
            .alert("暂未完成", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
                Button("知道了", role: .cancel) { localError = nil }
            } message: {
                Text(localError ?? "")
            }
        }
    }
    private var bubbleStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(draft.bubbles.enumerated()), id: \.element.id) { index, b in
                    Button {
                        select(b.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(index+1)").monospacedDigit()
                            if b.hidden { Image(systemName: "eye.slash") }
                            Text(b.speaker.isEmpty ? String(b.text.prefix(8)) : b.speaker).lineLimit(1)
                        }.font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 9)
                            .background(
                                selectedID == b.id ? Ink.accent.opacity(0.14) : Ink.teal.opacity(0.07), in: Capsule()
                            )
                            .foregroundStyle(selectedID == b.id ? Ink.accent : Ink.teal)
                    }.buttonStyle(.plain).accessibilityLabel("气泡\(index+1)，\(b.displayedText)")
                }
                if draft.bubbles.isEmpty { Text("点击下方「新气泡」添加对白").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                Ink.teal.opacity(0.055)
                if let bitmap {
                    let available = CGSize(width: max(1, proxy.size.width - 28), height: max(1, proxy.size.height - 22))
                    let scale = min(
                        available.width / bitmap.image.size.width, available.height / bitmap.image.size.height)
                    ComicCanvas(
                        image: bitmap.image, lettering: draft, selectedID: selectedID,
                        editable: !saving && !studio.isWorking,
                        onSelect: { select($0, dismissKeyboard: false) }, onBegin: { beginInteraction(.gesture) },
                        onChange: { replace($0) }, onEnd: { finishInteraction() }
                    )
                    .frame(width: bitmap.image.size.width * scale, height: bitmap.image.size.height * scale)
                    .overlay { Rectangle().stroke(.gray.opacity(0.2), lineWidth: 1).allowsHitTesting(false) }
                } else if loading {
                    ProgressView("读取漫画…")
                } else {
                    VStack {
                        Text("无法读取本格图片").foregroundStyle(.secondary)
                        Button("重新读取") { Task { await load() } }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                if let selected {
                    HStack {
                        Text("拖动气泡移动位置").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(selected.frame.x*100))%, \(Int(selected.frame.y*100))%").font(
                            .caption.monospacedDigit()
                        ).foregroundStyle(.secondary)
                    }
                    Text("青色角点调整大小，橙色点调整尾尖。移动气泡时，尾尖保留原指向。").font(.caption).foregroundStyle(.secondary)
                    if overflow.contains(selected.id) {
                        Label("文字放不下，请放大气泡或减少文字后保存。", systemImage: "exclamationmark.triangle").font(.caption)
                            .foregroundStyle(.orange)
                    }
                    TextField("说话者（可选）", text: text(\.speaker)).textFieldStyle(.roundedBorder).focused($textFocused)
                        .autocorrectionDisabled()
                    TextEditor(text: text(\.text)).frame(minHeight: 75, maxHeight: 100).focused($textFocused)
                        .autocorrectionDisabled()
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.2)) }
                        .accessibilityLabel("气泡文字")
                    Picker("气泡形状", selection: choice(\.style, fallback: .speech)) {
                        ForEach(BubbleStyle.allCases) { style in Text(style.title).tag(style) }
                    }.pickerStyle(.segmented)
                    HStack {
                        Toggle("显示姓名", isOn: choice(\.showSpeaker, fallback: false))
                        if selected.style != .caption { Toggle("显示尾巴", isOn: choice(\.tailEnabled, fallback: false)) }
                    }.font(.caption).tint(Ink.accent)
                    Toggle(
                        "显示此气泡",
                        isOn: Binding(
                            get: { !selected.hidden }, set: { value in perform { modify { $0.hidden = !value } } })
                    ).font(.caption).tint(Ink.accent)
                    HStack {
                        Text("字号 \(Int(selected.fontScale*1000))").font(.caption)
                        Slider(
                            value: continuous(\.fontScale), in: 0.014...0.08,
                            onEditingChanged: { active in active ? beginInteraction(.slider) : finishInteraction() })
                    }
                    Text("字号随画格同比缩放；文字较多时会适当缩小。").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("精细调整位置与大小") {
                        VStack(spacing: 12) {
                            position("水平", path: \.frame.x, range: 0.01...max(0.0101, 0.99 - selected.frame.width))
                            position("垂直", path: \.frame.y, range: 0.01...max(0.0101, 0.99 - selected.frame.height))
                            position("宽度", path: \.frame.width, range: 0.12...max(0.1201, 0.99 - selected.frame.x))
                            position("高度", path: \.frame.height, range: 0.05...max(0.0501, 0.99 - selected.frame.y))
                            if selected.tailEnabled, selected.style != .caption {
                                position("尾尖水平", path: \.tailTip.x, range: 0...1)
                                position("尾尖垂直", path: \.tailTip.y, range: 0...1)
                            }
                        }.padding(.top, 12)
                    }.font(.caption)
                } else {
                    Text("选择气泡开始调整").font(.headline)
                    Text("点击漫画里的气泡，或点上方的对白标签。原图保留，保存后会同步用于阅读和导出。").font(.footnote).foregroundStyle(.secondary)
                }
                if studio.isWorking { Text("制作任务正在进行，暂停后可保存气泡。").font(.caption).foregroundStyle(.orange) }
            }.padding(16)
        }.scrollDismissesKeyboard(.interactively).disabled(loading || saving || studio.isWorking)
    }
    private func position(_ title: String, path: WritableKeyPath<ComicBubble, Double>, range: ClosedRange<Double>)
        -> some View
    {
        HStack {
            Text(title).frame(width: 65, alignment: .leading)
            Slider(
                value: continuous(path), in: range,
                onEditingChanged: { active in active ? beginInteraction(.slider) : finishInteraction() })
            Text("\(Int((selected?[keyPath:path] ?? 0)*100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }.font(.caption)
    }
    private func text(_ path: WritableKeyPath<ComicBubble, String>) -> Binding<String> {
        Binding(
            get: { selected?[keyPath: path] ?? "" },
            set: { value in
                beginInteraction(.text)
                modify { $0[keyPath: path] = value }
            })
    }
    private func choice<T>(_ path: WritableKeyPath<ComicBubble, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { selected?[keyPath: path] ?? fallback },
            set: { value in perform { modify { $0[keyPath: path] = value } } })
    }
    private func continuous(_ path: WritableKeyPath<ComicBubble, Double>) -> Binding<Double> {
        let fallback = selected?[keyPath: path] ?? 0
        return Binding(
            get: { selected?[keyPath: path] ?? fallback },
            set: { value in
                beginInteraction(.slider)
                modify { $0[keyPath: path] = value }
            })
    }
    private func select(_ id: String?, dismissKeyboard: Bool = true) {
        if dismissKeyboard || id == nil { textFocused = false }
        finishInteraction()
        selectedID = id
    }
    private func replace(_ bubble: ComicBubble) {
        if let index = draft.bubbles.firstIndex(where: { $0.id == bubble.id }) {
            draft.bubbles[index] = bubble.clamped()
        }
    }
    private func modify(_ action: (inout ComicBubble) -> Void) {
        guard var b = selected else { return }
        action(&b)
        replace(b)
    }
    private func beginInteraction(_ kind: Interaction) {
        if interaction == kind { return }
        finishInteraction()
        interaction = kind
        interactionStart = draft
    }
    private func finishInteraction() {
        if let before = interactionStart, before != draft { remember(before) }
        interactionStart = nil
        interaction = nil
    }
    private func remember(_ before: ComicLettering) {
        undoStack.append(before)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack = []
    }
    private func perform(_ edit: () -> Void) {
        textFocused = false
        finishInteraction()
        let before = draft
        edit()
        if before != draft { remember(before) }
    }
    private func undo() {
        textFocused = false
        finishInteraction()
        guard let last = undoStack.popLast() else { return }
        redoStack.append(draft)
        draft = last
        repairSelection()
    }
    private func redo() {
        textFocused = false
        finishInteraction()
        guard let last = redoStack.popLast() else { return }
        undoStack.append(draft)
        draft = last
        repairSelection()
    }
    private func repairSelection() {
        if !draft.bubbles.contains(where: { $0.id == selectedID }) { selectedID = draft.bubbles.first?.id }
    }
    private func addBubble() {
        perform {
            let b = ComicBubble(text: "在这里输入对白", showSpeaker: false)
            draft.bubbles.append(b)
            selectedID = b.id
        }
    }
    private func removeSelected() {
        perform {
            draft.bubbles.removeAll { $0.id == selectedID }
            selectedID = draft.bubbles.first?.id
        }
    }
    private func bringToFront() {
        perform {
            guard let i = draft.bubbles.firstIndex(where: { $0.id == selectedID }) else { return }
            let bubble = draft.bubbles.remove(at: i)
            draft.bubbles.append(bubble)
        }
    }
    private func reset() {
        perform {
            var original = panel
            original.lettering = nil
            draft = LetteringDefaults.layout(for: original, imageAspect: aspect)
            selectedID = draft.bubbles.first?.id
        }
    }
    private func requestClose() {
        textFocused = false
        finishInteraction()
        if changed { closePrompt = true } else { dismiss() }
    }
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let run = try await studio.repository.chapter(
                projectID, ordinal: chapter, chunk: studio.settings.chunkCharacters)
            guard let current = run.panels.first(where: { $0.id == panel.id }),
                let url = studio.assetURL(projectID, current.imageFile)
            else { throw StudioError.invalid("本格尚未出图。") }
            let image = try await BitmapCache.shared.load(url, side: 2400)
            try Task.checkCancellation()
            panel = current
            bitmap = image
            draft = LetteringDefaults.layout(
                for: current, imageAspect: Double(image.image.size.width / image.image.size.height))
            baseline = draft
            selectedID = draft.bubbles.first?.id
            undoStack = []
            redoStack = []
        } catch is CancellationError {} catch { localError = error.localizedDescription }
    }
    private func save() {
        textFocused = false
        finishInteraction()
        guard let image = panel.imageFile, !studio.isWorking, !saving else { return }
        do { _ = try draft.validated() } catch {
            localError = error.localizedDescription
            return
        }
        guard overflow.isEmpty else {
            localError = "有气泡文字放不下，请放大气泡、调低字号或减少文字后保存。"
            return
        }
        saving = true
        Task {
            do {
                _ = try await studio.repository.saveLettering(
                    projectID, chapter: chapter, panelID: panel.id, lettering: draft,
                    expectedImage: image, expectedRevision: panel.lettering?.revision ?? 0)
                await studio.refresh()
                dismiss()
            } catch { localError = error.localizedDescription }
            saving = false
        }
    }
}
