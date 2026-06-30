import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var model: CBrainViewModel
    @State private var showingFolderPicker = false
    @State private var showingS3Settings = false
    @State private var pendingAction: NodeAction?
    @State private var inputText = ""
    @State private var confirmDelete = false
    @State private var existingLinkAction: ExistingLinkAction?
    @State private var previewMode = false
    @State private var editorCommand: EditorWrapCommand?
    @State private var showingFullEditor = false
    @State private var fullEditorCommand: EditorWrapCommand?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("CBrain")
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                        Button {
                            model.openHistory(-1)
                        } label: {
                            Label("上", systemImage: "chevron.left")
                        }

                        Button {
                            model.openHistory(1)
                        } label: {
                            Label("下", systemImage: "chevron.right")
                        }
                    }

                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button {
                            model.homeNode()
                        } label: {
                            Label("主页", systemImage: "house")
                        }

                        Button {
                            showingFolderPicker = true
                        } label: {
                            Label("导入", systemImage: "folder.badge.plus")
                        }

                        Button {
                            model.openRandomNote()
                        } label: {
                            Label("随机", systemImage: "shuffle")
                        }
                    }
                }
        } detail: {
            detail
                .navigationTitle(model.selectedNode?.topic ?? "CBrain")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button {
                            model.saveCurrentNote()
                        } label: {
                            Label("保存", systemImage: "square.and.arrow.down")
                        }
                        .disabled(model.selectedNode == nil || !model.noteDirty)

                        Menu {
                            Button {
                                begin(.child)
                            } label: {
                                Label("子节点", systemImage: "arrow.down.right")
                            }
                            Button {
                                begin(.parent)
                            } label: {
                                Label("父节点", systemImage: "arrow.up.left")
                            }
                            Button {
                                begin(.related)
                            } label: {
                                Label("相关节点", systemImage: "link")
                            }
                            Divider()
                            Button {
                                existingLinkAction = .parent
                            } label: {
                                Label("链接已有父节点", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            Button {
                                existingLinkAction = .child
                            } label: {
                                Label("链接已有子节点", systemImage: "arrow.down.right.and.arrow.up.left")
                            }
                            Button {
                                existingLinkAction = .related
                            } label: {
                                Label("链接已有相关节点", systemImage: "link.badge.plus")
                            }
                            Divider()
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
        .sheet(item: $existingLinkAction) { action in
            NavigationStack {
                ExistingLinkPicker(action: action) { node in
                    existingLinkAction = nil
                    model.linkExisting(node, as: action)
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
                VStack(spacing: 0) {
                    MarkdownEditor(text: $model.noteText, command: fullEditorCommand)
                        .padding(12)
                }
                .navigationTitle(model.selectedNode?.topic ?? "编辑")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
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
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button {
                            model.saveCurrentNote()
                        } label: {
                            Label("保存", systemImage: "square.and.arrow.down")
                        }
                        .disabled(!model.noteDirty)

                        Button("缩小") {
                            showingFullEditor = false
                        }
                    }
                }
            }
        }
    }

    private var sidebar: some View {
        List {
            Section(model.libraryName) {
                if model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(model.nodes) { node in
                        NodeRow(node: node, isSelected: node.id == model.selectedNode?.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectNode(node)
                            }
                    }
                } else {
                    ForEach(model.searchResults) { result in
                        Button {
                            if let node = model.nodes.first(where: { $0.id == result.nodeId }) {
                                model.selectNode(node)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title)
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
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selected.topic)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    RelationStrip(title: "父节点", nodes: model.parents, relation: .parent, onSelect: model.selectNode, onDelete: model.removeRelation)
                    RelationStrip(title: "子节点", nodes: model.children, relation: .child, onSelect: model.selectNode, onDelete: model.removeRelation)
                    RelationStrip(title: "相关", nodes: model.related, relation: .related, onSelect: model.selectNode, onDelete: model.removeRelation)
                }
                .padding([.horizontal, .top], 16)

                HStack(spacing: 8) {
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

                    Spacer()

                    Picker("模式", selection: $previewMode) {
                        Text("编辑").tag(false)
                        Text("预览").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)

                    Button {
                        showingFullEditor = true
                    } label: {
                        Label("最大", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)

                if previewMode {
                    ScrollView {
                        Text(tryAttributedMarkdown(model.noteText))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .background(Color(.systemBackground))
                    .overlay(alignment: .top) {
                        Divider()
                    }
                } else {
                    MarkdownEditor(text: $model.noteText, command: editorCommand)
                        .background(Color(.systemBackground))
                        .padding(.horizontal, 12)
                        .overlay(alignment: .top) {
                            Divider()
                        }
                }
            }
            .background(Color(.systemGroupedBackground))
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
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        var lastCommandID: UUID?

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
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
    var onSelect: (CBrainNode) -> Void
    var onDelete: (CBrainNode, RelationKind) -> Void

    var body: some View {
        if !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(nodes) { node in
                            Button {
                                onSelect(node)
                            } label: {
                                Text(node.topic)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .contextMenu {
                                Button(role: .destructive) {
                                    onDelete(node, relation)
                                } label: {
                                    Label("删除关系", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ExistingLinkPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: CBrainViewModel
    var action: ExistingLinkAction
    var onSelect: (CBrainNode) -> Void
    @State private var query = ""

    private var candidates: [CBrainNode] {
        let currentId = model.selectedNode?.id
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.nodes.filter { node in
            node.id != currentId && (trimmed.isEmpty || node.topic.localizedCaseInsensitiveContains(trimmed))
        }
    }

    var body: some View {
        List(candidates) { node in
            Button {
                onSelect(node)
            } label: {
                Text(node.topic)
                    .lineLimit(1)
            }
        }
        .searchable(text: $query, prompt: "搜索已有节点")
        .navigationTitle(action.title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
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
            return "链接已有父节点"
        case .child:
            return "链接已有子节点"
        case .related:
            return "链接已有相关节点"
        }
    }
}
