import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var model: CBrainViewModel
    @State private var showingFolderPicker = false
    @State private var showingSidebarSheet = false
    @State private var showingS3Settings = false
    @State private var pendingAction: NodeAction?
    @State private var inputText = ""
    @State private var confirmDelete = false
    @State private var addRelationAction: ExistingLinkAction?
    @State private var previewMode = false
    @State private var editorCommand: EditorWrapCommand?
    @State private var showingFullEditor = false
    @State private var fullEditorCommand: EditorWrapCommand?
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var whiteboardStart: WhiteboardStart?
    @State private var selectedNoteText = ""
    @State private var showingSearchSheet = false

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                NavigationStack {
                    compactDetail
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationTitle("CBrain")
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                        Button {
                            model.openHistory(-1)
                            closeSidebar()
                        } label: {
                            Label("上", systemImage: "chevron.left")
                        }

                        Button {
                            model.openHistory(1)
                            closeSidebar()
                        } label: {
                            Label("下", systemImage: "chevron.right")
                        }
                    }

                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button {
                            showingFolderPicker = true
                        } label: {
                            Label("导入", systemImage: "folder.badge.plus")
                        }
                    }
                }
        } detail: {
            detail
                .navigationTitle(model.selectedNode?.topic ?? "CBrain")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                        Button {
                            toggleSidebar()
                        } label: {
                            Label("资料库", systemImage: "sidebar.left")
                        }

                        Button {
                            model.homeNode()
                        } label: {
                            Label("主页", systemImage: "house")
                        }
                    }

                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Menu {
                            Button {
                                begin(.rename)
                            } label: {
                                Label("改名", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                confirmDelete = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        } label: {
                            Label("更多", systemImage: "ellipsis.circle")
                        }
                        .disabled(model.selectedNode == nil)

                        Button {
                            showingS3Settings = true
                        } label: {
                            Label("同步", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(model.isSyncing)
                    }
                }
        }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .onAppear {
            preferDetailColumn()
        }
        .onChange(of: horizontalSizeClass) { _ in
            preferDetailColumn()
        }
        .sheet(isPresented: $showingSidebarSheet) {
            NavigationStack {
                sidebar
                    .navigationTitle("CBrain")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") {
                                showingSidebarSheet = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button {
                                showingSidebarSheet = false
                                DispatchQueue.main.async {
                                    showingFolderPicker = true
                                }
                            } label: {
                                Label("导入", systemImage: "folder.badge.plus")
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in
                showingFolderPicker = false
                model.importLibrary(from: url)
            }
        }
        .sheet(isPresented: $showingS3Settings) {
            NavigationStack {
                S3SettingsView()
            }
        }
        .sheet(item: $addRelationAction) { action in
            NavigationStack {
                RelationAddPicker(action: action) { node in
                    addRelationAction = nil
                    model.linkExisting(node, as: action)
                } onCreate: { title in
                    addRelationAction = nil
                    switch action {
                    case .parent:
                        model.addParent(title: title)
                    case .child:
                        model.addChild(title: title)
                    case .related:
                        model.addRelated(title: title)
                    }
                }
                .environmentObject(model)
            }
        }
        .fullScreenCover(item: $whiteboardStart) { start in
            NavigationStack {
                WhiteboardView(start: start)
                    .environmentObject(model)
            }
            .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $showingSearchSheet) {
            NavigationStack {
                SearchResultsSheet { result in
                    openSearchResult(result)
                }
                    .environmentObject(model)
            }
        }
        .alert(pendingAction?.title ?? "", isPresented: actionBinding) {
            TextField("名称", text: $inputText)
            Button("确定") {
                submitInput()
            }
            Button("取消", role: .cancel) {
                pendingAction = nil
            }
        }
        .alert("删除节点", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                model.deleteSelected()
            }
            Button("取消", role: .cancel) {
            }
        }
        .alert("错误", isPresented: errorBinding) {
            Button("好", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .fullScreenCover(isPresented: $showingFullEditor) {
            NavigationStack {
                MarkdownEditor(text: $model.noteText, command: fullEditorCommand, selectedText: $selectedNoteText)
                    .padding(12)
                    .navigationTitle(model.selectedNode?.topic ?? "编辑")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItemGroup(placement: .navigationBarLeading) {
                            Button {
                                model.saveCurrentNote()
                            } label: {
                                Label("保存", systemImage: "checkmark.circle")
                            }
                            .disabled(!model.noteDirty)

                            Button {
                                fullEditorCommand = EditorWrapCommand(before: "**", after: "**")
                            } label: {
                                Label("加粗", systemImage: "bold")
                            }
                            Button {
                                fullEditorCommand = EditorWrapCommand(before: "==", after: "==")
                            } label: {
                                Label("高亮", systemImage: "highlighter")
                            }
                            Button {
                                copyReferenceLink()
                            } label: {
                                Label("引用", systemImage: "link")
                            }
                            .disabled(selectedNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        ToolbarItemGroup(placement: .navigationBarTrailing) {
                            Button {
                                showingFullEditor = false
                            } label: {
                                Label("缩小", systemImage: "arrow.down.right.and.arrow.up.left")
                            }
                        }
                    }
            }
        }
    }

    private var compactDetail: some View {
        detail
            .navigationTitle(model.selectedNode?.topic ?? "CBrain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button {
                        toggleSidebar()
                    } label: {
                        Label("资料库", systemImage: "sidebar.left")
                    }

                    Button {
                        model.homeNode()
                    } label: {
                        Label("主页", systemImage: "house")
                    }
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            begin(.rename)
                        } label: {
                            Label("改名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                    .disabled(model.selectedNode == nil)

                    Button {
                        showingS3Settings = true
                    } label: {
                        Label("同步", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.isSyncing)
                }
            }
    }

    private func toggleSidebar() {
        if horizontalSizeClass == .compact {
            showingSidebarSheet = true
            return
        }

        withAnimation {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    private func preferDetailColumn() {
        columnVisibility = .detailOnly
    }

    private func closeSidebar() {
        showingSidebarSheet = false
        columnVisibility = .detailOnly
    }

    private func compactButton(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func selectFromSidebar(_ node: CBrainNode) {
        model.selectNode(node, updateGraph: true)
        closeSidebar()
    }

    private func openSearchResult(_ result: CBrainSearchResult) {
        if let node = model.nodes.first(where: { $0.id == result.nodeId }) {
            selectFromSidebar(node)
        }
        guard result.kind == "whiteboard" else { return }
        do {
            whiteboardStart = try model.makeWhiteboardStart(
                drawingId: result.drawingId,
                focusElementId: result.elementId,
                focusElementIndex: result.elementIndex
            )
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private var sidebar: some View {
        List {
            Section(model.libraryName) {
                if model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(model.nodes) { node in
                        Button {
                            selectFromSidebar(node)
                        } label: {
                            NodeRow(node: node, isSelected: node.id == model.selectedNode?.id)
                        }
                    }
                } else if model.searchResults.isEmpty {
                    Text("没有结果")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.searchResults) { result in
                        Button {
                            openSearchResult(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text((result.kind == "whiteboard" ? "[白板] " : "") + result.title)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(result.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $model.searchQuery, placement: .sidebar, prompt: "搜索")
        .safeAreaInset(edge: .bottom) {
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.bar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected = model.selectedNode {
            GeometryReader { geometry in
            let noteHeight = min(
                max(220, geometry.size.height * 0.65),
                max(180, geometry.size.height - 224)
            )
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text(model.libraryName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: 140, alignment: .leading)
                        compactButton("选择", "folder.badge.plus") { showingFolderPicker = true }
                        compactButton("搜索", "magnifyingglass") { showingSearchSheet = true }
                        compactButton("白板", "square.and.pencil") { openCurrentWhiteboard() }
                        compactButton("+父", "arrow.up.left") { addRelationAction = .parent }
                        compactButton("+子", "arrow.down.right") { addRelationAction = .child }
                        compactButton("+相关", "link") { addRelationAction = .related }
                        compactButton("上", "chevron.left") { model.openHistory(-1) }
                        compactButton("随机", "shuffle") { model.openRandomNote() }
                        compactButton("下", "chevron.right") { model.openHistory(1) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(height: 40)
                .background(Color(.systemGroupedBackground))

                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.topic)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    HStack(alignment: .top, spacing: 8) {
                        RelationStrip(title: "父", nodes: model.parents, relation: .parent, previewedNodeId: model.selectedNode?.id, onTap: model.graphNodeTapped, onOpen: model.selectGraphNode, onDelete: model.removeRelation)
                            .frame(maxWidth: .infinity)
                        RelationStrip(title: "兄弟", nodes: model.siblings, relation: .sibling, previewedNodeId: model.selectedNode?.id, onTap: model.graphNodeTapped, onOpen: model.selectGraphNode, onDelete: { _, _ in })
                            .frame(maxWidth: .infinity)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        RelationStrip(title: "子", nodes: model.children, relation: .child, previewedNodeId: model.selectedNode?.id, onTap: model.graphNodeTapped, onOpen: model.selectGraphNode, onDelete: model.removeRelation)
                            .frame(maxWidth: .infinity)
                        RelationStrip(title: "相关", nodes: model.related, relation: .related, previewedNodeId: model.selectedNode?.id, onTap: model.graphNodeTapped, onOpen: model.selectGraphNode, onDelete: model.removeRelation)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(height: 104, alignment: .top)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button {
                            model.saveCurrentNote()
                        } label: {
                            Label("保存", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.selectedNode == nil || !model.noteDirty)

                        Button {
                            editorCommand = EditorWrapCommand(before: "**", after: "**")
                        } label: {
                            Label("加粗", systemImage: "bold")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(previewMode)

                        Button {
                            editorCommand = EditorWrapCommand(before: "==", after: "==")
                        } label: {
                            Label("高亮", systemImage: "highlighter")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(previewMode)

                        Button {
                            copyReferenceLink()
                        } label: {
                            Label("引用", systemImage: "link")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Picker("模式", selection: $previewMode) {
                            Text("编辑").tag(false)
                            Text("预览").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 112)

                        Button {
                            showingFullEditor = true
                        } label: {
                            Label("最大", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(height: 32)
                .padding(.horizontal, 12)
                .font(.caption)

                if previewMode {
                    ScrollView {
                        Text(tryAttributedMarkdown(model.noteText))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: noteHeight)
                    .background(Color(.systemBackground))
                    .overlay(alignment: .top) {
                        Divider()
                    }
                    .onTapGesture(count: 2) {
                        showingFullEditor = true
                    }
                } else {
                    MarkdownEditor(text: $model.noteText, command: editorCommand, selectedText: $selectedNoteText)
                        .background(Color(.systemBackground))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: noteHeight)
                        .overlay(alignment: .top) {
                            Divider()
                        }
                        .onTapGesture(count: 2) {
                            showingFullEditor = true
                        }
                }
                Text([model.whiteboardStatus, model.status].filter { !$0.isEmpty }.joined(separator: "  "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(Color(.secondarySystemGroupedBackground))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "folder")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("导入知识库", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
        }
    }

    private var actionBinding: Binding<Bool> {
        Binding(
            get: { pendingAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingAction = nil
                }
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.errorMessage = nil
                }
            }
        )
    }

    private func begin(_ action: NodeAction) {
        pendingAction = action
        inputText = action == .rename ? (model.selectedNode?.topic ?? "") : ""
    }

    private func submitInput() {
        let title = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let action = pendingAction else {
            pendingAction = nil
            return
        }
        switch action {
        case .child:
            model.addChild(title: title)
        case .parent:
            model.addParent(title: title)
        case .related:
            model.addRelated(title: title)
        case .rename:
            model.renameSelected(to: title)
        }
        pendingAction = nil
    }

    private func openCurrentWhiteboard() {
        do {
            whiteboardStart = try model.makeWhiteboardStart()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func copyReferenceLink() {
        guard let node = model.selectedNode else { return }
        let text = selectedNoteText
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        UIPasteboard.general.string = "[\(escaped)](https://app.cbrain.site/index?nodeid=\(node.id))"
        model.status = "已复制引用: \(text)"
    }

    private func tryAttributedMarkdown(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(markdown: text) {
            return attributed
        }
        return AttributedString(text)
    }
}

private struct EditorWrapCommand: Equatable {
    let id = UUID()
    var before: String
    var after: String
}

private struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    var command: EditorWrapCommand?
    @Binding var selectedText: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .yes
        view.autocapitalizationType = .sentences
        view.isScrollEnabled = true
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            let selected = uiView.selectedRange
            uiView.text = text
            uiView.selectedRange = selected.location <= (uiView.text as NSString).length ? selected : NSRange(location: 0, length: 0)
        }

        guard let command, context.coordinator.lastCommandID != command.id else { return }
        context.coordinator.lastCommandID = command.id
        let source = uiView.text as NSString
        let range = uiView.selectedRange
        let boundedRange = NSRange(location: min(range.location, source.length), length: min(range.length, max(0, source.length - min(range.location, source.length))))
        let selected = source.substring(with: boundedRange)
        let replacement = command.before + selected + command.after
        uiView.text = source.replacingCharacters(in: boundedRange, with: replacement)
        let cursor = boundedRange.location + command.before.count + selected.count
        uiView.selectedRange = NSRange(location: cursor, length: selected.isEmpty ? 0 : selected.count)
        text = uiView.text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectedText: $selectedText)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var selectedText: String
        var lastCommandID: UUID?

        init(text: Binding<String>, selectedText: Binding<String>) {
            _text = text
            _selectedText = selectedText
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let source = textView.text as NSString
            let range = textView.selectedRange
            guard range.location != NSNotFound,
                  range.length > 0,
                  range.location + range.length <= source.length else {
                selectedText = ""
                return
            }
            selectedText = source.substring(with: range)
        }
    }
}

private struct NodeRow: View {
    var node: CBrainNode
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Text(node.topic)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

private struct RelationStrip: View {
    var title: String
    var nodes: [CBrainNode]
    var relation: RelationKind
    var previewedNodeId: String?
    var onTap: (CBrainNode) -> Void
    var onOpen: (CBrainNode) -> Void
    var onDelete: (CBrainNode, RelationKind) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if nodes.isEmpty {
                        Text("None")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .leading)
                    } else {
                        ForEach(nodes) { node in
                            Button {
                                onTap(node)
                            } label: {
                                Text(node.topic)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .frame(maxWidth: 120)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .overlay {
                                if node.id == previewedNodeId {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                        .foregroundStyle(Color.primary)
                                }
                            }
                            .contextMenu {
                                Button {
                                    onOpen(node)
                                } label: {
                                    Label("打开", systemImage: "arrow.up.forward")
                                }
                                if relation != .sibling {
                                    Button(role: .destructive) {
                                        onDelete(node, relation)
                                    } label: {
                                        Label("移除连接", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 30)
    }
}

private struct RelationAddPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: CBrainViewModel
    var action: ExistingLinkAction
    var onSelect: (CBrainNode) -> Void
    var onCreate: (String) -> Void
    @State private var query = ""
    @FocusState private var queryFocused: Bool

    private var candidates: [CBrainNode] {
        let currentId = model.graphNode?.id
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(model.nodes.filter { node in
            node.id != currentId && (trimmed.isEmpty || node.topic.localizedCaseInsensitiveContains(trimmed))
        }.prefix(80))
    }

    private var titleForCreate: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名" : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索已有节点或输入新标题", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .onAppear {
                    DispatchQueue.main.async {
                        queryFocused = true
                    }
                }
                .padding()

            List {
                Section("已有节点") {
                    if candidates.isEmpty {
                        Text("没有匹配节点")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates) { node in
                            Button {
                                onSelect(node)
                            } label: {
                                Text(node.topic)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("添加关系")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("新建") {
                    onCreate(titleForCreate)
                }
            }
        }
    }
}

private struct SearchResultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: CBrainViewModel
    var onOpen: (CBrainSearchResult) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索标题、正文或白板文字", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onAppear {
                    DispatchQueue.main.async {
                        searchFocused = true
                    }
                }
                .padding()

            List {
                if model.searchResults.isEmpty {
                    Text("没有结果")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.searchResults) { result in
                        Button {
                            onOpen(result)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text((result.kind == "whiteboard" ? "[白板] " : "[笔记] ") + result.title)
                                    .lineLimit(1)
                                Text(result.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
    }
}

private struct S3SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: CBrainViewModel
    @State private var config = S3Config.load()

    var body: some View {
        Form {
            Section("S3") {
                TextField("Endpoint", text: $config.endpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Bucket", text: $config.bucket)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Region", text: $config.region)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Prefix", text: $config.prefix)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Path style", isOn: $config.pathStyle)
            }
            Section("Credentials") {
                TextField("Access key", text: $config.accessKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Secret key", text: $config.secretKey)
            }
            Section {
                Button {
                    config.save()
                    dismiss()
                    model.runS3Sync()
                } label: {
                    Label("双向同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.isSyncing)

                Button {
                    config.save()
                    dismiss()
                    model.runS3DownloadAll()
                } label: {
                    Label("从 S3 全量下载", systemImage: "icloud.and.arrow.down")
                }
                .disabled(model.isSyncing)

                Button {
                    config.save()
                    model.checkS3Config()
                } label: {
                    Label("检查配置", systemImage: "checkmark.seal")
                }
                .disabled(model.isSyncing)
            }

            Section {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("同步")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    config.save()
                    dismiss()
                }
            }
        }
    }
}

private enum NodeAction: Identifiable {
    case child
    case parent
    case related
    case rename

    var id: String {
        title
    }

    var title: String {
        switch self {
        case .child:
            return "新增子节点"
        case .parent:
            return "新增父节点"
        case .related:
            return "新增相关节点"
        case .rename:
            return "改名"
        }
    }
}

extension ExistingLinkAction: Identifiable {
    var id: String {
        title
    }

    var title: String {
        switch self {
        case .parent:
            return "添加父节点"
        case .child:
            return "添加子节点"
        case .related:
            return "添加相关节点"
        }
    }
}
