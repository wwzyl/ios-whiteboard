import Foundation

@MainActor
final class CBrainViewModel: ObservableObject {
    @Published private(set) var libraryName = "未导入"
    @Published private(set) var nodes: [CBrainNode] = []
    @Published private(set) var parents: [CBrainNode] = []
    @Published private(set) var siblings: [CBrainNode] = []
    @Published private(set) var children: [CBrainNode] = []
    @Published private(set) var related: [CBrainNode] = []
    @Published private(set) var searchResults: [CBrainSearchResult] = []
    @Published private(set) var selectedNode: CBrainNode?
    @Published private(set) var graphNode: CBrainNode?
    @Published var noteText = "" {
        didSet {
            if !loadingNote {
                noteDirty = true
            }
        }
    }
    @Published var searchQuery = "" {
        didSet {
            runSearch()
        }
    }
    @Published var status = ""
    @Published private(set) var whiteboardStatus = ""
    @Published var errorMessage: String?
    @Published var isSyncing = false
    @Published private(set) var noteDirty = false

    private var store: LibraryStore?
    private var repository: CBrainRepository?
    private var history: [String] = []
    private var historyIndex = -1
    private var navigatingHistory = false
    private var loadingNote = false
    private var lastGraphTapNodeId = ""
    private var lastGraphTapTime = Date.distantPast

    init() {
        openExistingLibrary()
    }

    func openExistingLibrary() {
        guard let appStore = LibraryStore.appStore() else {
            status = "请先导入知识库"
            return
        }
        open(store: appStore)
    }

    func importLibrary(from url: URL) {
        do {
            let imported = try LibraryStore.importLibrary(from: url)
            open(store: imported)
            status = "已导入 \(imported.displayName)"
        } catch {
            report(error)
        }
    }

    func selectNode(_ node: CBrainNode, updateGraph: Bool = false) {
        guard let repository else { return }
        do {
            saveCurrentNote()
            selectedNode = node
            if updateGraph || graphNode == nil {
                graphNode = node
            }
            recordHistory(node.id)
            loadingNote = true
            defer { loadingNote = false }
            noteText = try repository.readNote(node)
            noteDirty = false
            refreshGraphRelations()
            updateWhiteboardStatus(node.id)
            status = node.topic
        } catch {
            report(error)
        }
    }

    func saveCurrentNote() {
        guard let node = selectedNode, let repository, noteDirty else { return }
        do {
            try repository.saveNote(node, note: noteText)
            noteDirty = false
            refresh(keeping: node.id, updateSelected: false)
            status = "已保存"
        } catch {
            report(error)
        }
    }

    func addChild(title: String) {
        guard let node = graphNode, let repository else { return }
        do {
            saveCurrentNote()
            let child = try repository.addChild(parentId: node.id, title: title)
            refresh(keeping: child.id)
            selectNode(child, updateGraph: true)
        } catch {
            report(error)
        }
    }

    func addParent(title: String) {
        guard let node = graphNode, let repository else { return }
        do {
            saveCurrentNote()
            let parent = try repository.addParent(childId: node.id, title: title)
            refresh(keeping: parent.id)
            selectNode(parent, updateGraph: true)
        } catch {
            report(error)
        }
    }

    func addRelated(title: String) {
        guard let node = graphNode, let repository else { return }
        do {
            saveCurrentNote()
            let next = try repository.addRelated(sourceId: node.id, title: title)
            refresh(keeping: next.id)
            selectNode(next, updateGraph: true)
        } catch {
            report(error)
        }
    }

    func renameSelected(to title: String) {
        guard let node = selectedNode, let repository else { return }
        do {
            let renamed = try repository.renameNode(nodeId: node.id, title: title)
            refresh(keeping: renamed.id)
            selectNode(renamed, updateGraph: graphNode?.id == renamed.id)
        } catch {
            report(error)
        }
    }

    func deleteSelected() {
        guard let node = selectedNode, let repository else { return }
        do {
            let deletedId = node.id
            let deletedTitle = node.topic
            let fallback = fallbackAfterDelete(node.id)
            try repository.deleteNoteFile(node)
            try repository.softDeleteNode(node.id)
            try repository.load()
            removeHistoryNode(deletedId)
            selectedNode = nil
            graphNode = nil
            loadingNote = true
            noteText = ""
            noteDirty = false
            loadingNote = false
            parents = []
            siblings = []
            children = []
            related = []
            whiteboardStatus = ""
            refresh()
            if let fallback,
               let fallbackNode = repository.node(fallback),
               fallbackNode.isActive {
                selectNode(fallbackNode, updateGraph: true)
            } else {
                selectedNode = nil
            }
            status = "已删除节点: \(deletedTitle)"
        } catch {
            report(error)
        }
    }

    func openRandomNote() {
        guard let repository else { return }
        if let node = repository.randomNoteNode(excluding: selectedNode?.id) {
            selectNode(node, updateGraph: true)
            status = "随机打开: \(node.topic)"
        } else {
            status = "notes 文件夹中没有可用笔记"
        }
    }

    func refreshSearch() {
        runSearch()
    }

    func makeWhiteboardStart(drawingId: String? = nil, focusElementId: String = "", focusElementIndex: Int = -1) throws -> WhiteboardStart {
        guard let store, let repository else { throw CBrainError.missingLibrary }
        saveCurrentNote()
        let whiteboards = try WhiteboardRepository(store: store)
        let drawing: WhiteboardDrawing
        if let drawingId, !drawingId.isEmpty, let found = whiteboards.drawingById(drawingId) {
            drawing = found
        } else {
            guard let node = selectedNode else { throw CBrainError.nodeNotFound }
            drawing = try whiteboards.openOrCreate(for: node)
        }
        return WhiteboardStart(
            store: store,
            repository: repository,
            whiteboards: whiteboards,
            drawing: drawing,
            focusElementId: focusElementId,
            focusElementIndex: focusElementIndex
        )
    }

    func openHistory(_ direction: Int) {
        guard !history.isEmpty else { return }
        let next = historyIndex + direction
        guard next >= 0 && next < history.count else { return }
        guard let repository, let node = repository.node(history[next]) else { return }
        navigatingHistory = true
        historyIndex = next
        selectNode(node, updateGraph: true)
        navigatingHistory = false
    }

    func homeNode() {
        guard let repository else { return }
        do {
            var home = repository.nodeByMarkdownFile("日记库.md")
            if home == nil {
                _ = try repository.importOrphanMarkdownNotes()
                try repository.load()
                refresh()
                home = repository.nodeByMarkdownFile("日记库.md")
            }
            guard let home, home.isActive else {
                status = "找不到日记库.md"
                return
            }
            selectNode(home, updateGraph: true)
        } catch {
            report(error)
        }
    }

    func graphNodeTapped(_ node: CBrainNode) {
        let now = Date()
        let doubleTap = node.id == lastGraphTapNodeId && now.timeIntervalSince(lastGraphTapTime) < 0.45
        lastGraphTapNodeId = node.id
        lastGraphTapTime = now
        selectNode(node, updateGraph: doubleTap)
        if doubleTap {
            status = "导图已切换到: \(node.topic)"
        }
    }

    func selectGraphNode(_ node: CBrainNode) {
        selectNode(node, updateGraph: true)
    }

    func openGraphCenter() {
        guard let node = graphNode else { return }
        selectNode(node, updateGraph: false)
    }

    func linkExisting(_ target: CBrainNode, as action: ExistingLinkAction) {
        guard let current = graphNode, let repository else { return }
        do {
            saveCurrentNote()
            let keepNodeId = current.id
            switch action {
            case .parent:
                _ = try repository.addExistingParent(childId: current.id, parentId: target.id)
            case .child:
                _ = try repository.addExistingChild(parentId: current.id, childId: target.id)
            case .related:
                _ = try repository.addExistingRelated(sourceId: current.id, targetId: target.id)
            }
            refresh(keeping: keepNodeId)
            if let node = nodes.first(where: { $0.id == keepNodeId }) {
                selectNode(node, updateGraph: true)
            } else {
                refreshGraphRelations()
            }
            status = "已添加关系"
        } catch {
            report(error)
        }
    }

    func removeRelation(_ node: CBrainNode, relation: RelationKind) {
        guard let current = graphNode, let repository else { return }
        do {
            switch relation {
            case .parent:
                try repository.deleteLink(a: node.id, b: current.id, linkType: "1")
            case .sibling:
                return
            case .child:
                try repository.deleteLink(a: current.id, b: node.id, linkType: "1")
            case .related:
                try repository.deleteLink(a: current.id, b: node.id, linkType: "0")
            }
            refresh(keeping: current.id)
            if let refreshed = nodes.first(where: { $0.id == current.id }) {
                selectNode(refreshed, updateGraph: true)
            }
        } catch {
            report(error)
        }
    }

    func selectSearchResult(_ result: CBrainSearchResult) {
        guard let repository, let node = repository.node(result.nodeId) else { return }
        selectNode(node, updateGraph: true)
    }

    func runS3Sync() {
        guard let store else {
            report(CBrainError.missingLibrary)
            return
        }
        saveCurrentNote()
        isSyncing = true
        status = "准备同步..."
        Task {
            do {
                let config = S3Config.load()
                let service = try CBrainSyncService(store: store, config: config) { [weak self] message in
                    Task { @MainActor in
                        self?.status = message
                    }
                }
                let result = try await service.sync()
                await MainActor.run {
                    self.reloadAfterSync()
                    self.status = result.summary
                    self.isSyncing = false
                }
            } catch {
                await MainActor.run {
                    self.isSyncing = false
                    self.report(error)
                }
            }
        }
    }

    func runS3DownloadAll() {
        isSyncing = true
        status = "准备全量下载..."
        Task {
            do {
                let targetStore: LibraryStore
                if let store {
                    targetStore = store
                } else {
                    targetStore = try LibraryStore.ensureAppStore()
                    await MainActor.run {
                        self.store = targetStore
                        self.libraryName = targetStore.displayName
                    }
                }
                let config = S3Config.load()
                let service = try CBrainSyncService(store: targetStore, config: config) { [weak self] message in
                    Task { @MainActor in
                        self?.status = message
                    }
                }
                let result = try await service.downloadAll()
                await MainActor.run {
                    self.reloadAfterSync()
                    self.status = result.summary
                    self.isSyncing = false
                }
            } catch {
                await MainActor.run {
                    self.isSyncing = false
                    self.report(error)
                }
            }
        }
    }

    func checkS3Config() {
        isSyncing = true
        status = "正在检查 S3 配置..."
        Task {
            do {
                let config = S3Config.load()
                let client = try S3StorageClient(config: config)
                try await client.checkBucket()
                await MainActor.run {
                    self.status = "S3 配置正常"
                    self.isSyncing = false
                }
            } catch {
                await MainActor.run {
                    self.isSyncing = false
                    self.report(error)
                }
            }
        }
    }

    private func open(store: LibraryStore) {
        do {
            let repository = CBrainRepository(store: store)
            try repository.load()
            let imported = try repository.importOrphanMarkdownNotes()
            self.store = store
            self.repository = repository
            libraryName = store.displayName
            selectedNode = nil
            graphNode = nil
            loadingNote = true
            noteText = ""
            noteDirty = false
            loadingNote = false
            parents = []
            siblings = []
            children = []
            related = []
            whiteboardStatus = ""
            refresh()
            if selectedNode == nil, let first = modelInitialNode(repository: repository) {
                selectNode(first, updateGraph: true)
            }
            status = imported > 0 ? "已导入 \(imported) 个孤立笔记" : "已打开"
        } catch {
            report(error)
        }
    }

    private func refresh(keeping nodeId: String? = nil, updateSelected: Bool = true) {
        guard let repository else { return }
        nodes = repository.activeNodes()
        runSearch()
        if let nodeId, let current = nodes.first(where: { $0.id == nodeId }) {
            if updateSelected {
                selectedNode = current
            } else if selectedNode?.id == nodeId {
                selectedNode = current
            }
            if graphNode?.id == nodeId || graphNode == nil {
                graphNode = current
            }
            refreshGraphRelations()
        }
    }

    private func runSearch() {
        guard let repository else {
            searchResults = []
            return
        }
        var results = repository.search(searchQuery)
        results.append(contentsOf: searchWhiteboardTexts(searchQuery, limit: max(0, 80 - results.count)))
        searchResults = Array(results.prefix(80))
    }

    private func reloadAfterSync() {
        guard let store else { return }
        do {
            let repository = CBrainRepository(store: store)
            try repository.load()
            self.repository = repository
            let keep = selectedNode?.id
            let keepGraph = graphNode?.id
            refresh(keeping: keep)
            if let keepGraph, let graph = nodes.first(where: { $0.id == keepGraph }) {
                graphNode = graph
                refreshGraphRelations()
            }
            if let keep, let node = nodes.first(where: { $0.id == keep }) {
                selectNode(node, updateGraph: false)
            } else if let first = modelInitialNode(repository: repository) {
                selectNode(first, updateGraph: true)
            }
        } catch {
            report(error)
        }
    }

    private func recordHistory(_ nodeId: String) {
        if navigatingHistory {
            return
        }
        if historyIndex >= 0 && historyIndex < history.count && history[historyIndex] == nodeId {
            return
        }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        history.append(nodeId)
        historyIndex = history.count - 1
    }

    private func removeHistoryNode(_ nodeId: String) {
        for index in history.indices.reversed() where history[index] == nodeId {
            history.remove(at: index)
            if historyIndex >= index {
                historyIndex -= 1
            }
        }
        if historyIndex >= history.count {
            historyIndex = history.count - 1
        }
    }

    private func fallbackAfterDelete(_ nodeId: String) -> String? {
        guard let repository else { return nil }
        if let parent = repository.parents(of: nodeId).first {
            return parent.id
        }
        if let child = repository.children(of: nodeId).first {
            return child.id
        }
        if let related = repository.related(to: nodeId).first {
            return related.id
        }
        return nil
    }

    private func refreshGraphRelations() {
        guard let repository, let graphNode else {
            parents = []
            siblings = []
            children = []
            related = []
            return
        }
        parents = repository.parents(of: graphNode.id)
        siblings = repository.siblings(of: graphNode.id)
        children = repository.children(of: graphNode.id)
        related = repository.related(to: graphNode.id)
    }

    private func updateWhiteboardStatus(_ nodeId: String) {
        guard let store else {
            whiteboardStatus = ""
            return
        }
        do {
            let whiteboards = try WhiteboardRepository(store: store)
            let info = whiteboards.usageInfo(for: nodeId)
            whiteboardStatus = info.isEmpty ? "" : "白板: \(info)"
        } catch {
            whiteboardStatus = ""
        }
    }

    private func searchWhiteboardTexts(_ query: String, limit: Int) -> [CBrainSearchResult] {
        guard limit > 0,
              let store,
              let repository else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let compactQuery = q.components(separatedBy: .whitespacesAndNewlines).joined()
        var output: [CBrainSearchResult] = []
        guard let whiteboards = try? WhiteboardRepository(store: store) else { return [] }
        for drawing in whiteboards.allDrawings() {
            guard output.count < limit,
                  let canvas = try? whiteboards.readCanvas(drawing),
                  let elements = canvas["elements"] as? [[String: Any]] else { continue }
            for (index, element) in elements.enumerated() {
                guard output.count < limit,
                      string(element["type"]) == "text" else { continue }
                let text = string(element["text"])
                let raw = string(element["cbrainWhiteboardRawText"])
                let compactText = text.replacingOccurrences(of: "\r\n", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\r", with: "")
                    .lowercased()
                let compactRaw = raw.replacingOccurrences(of: "\r\n", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\r", with: "")
                    .lowercased()
                guard text.lowercased().contains(q)
                        || raw.lowercased().contains(q)
                        || compactText.contains(compactQuery)
                        || compactRaw.contains(compactQuery) else { continue }
                let node = repository.node(drawing.nodeId)
                output.append(CBrainSearchResult(
                    nodeId: drawing.nodeId,
                    title: node?.topic ?? drawing.topic,
                    reason: "白板: \(preview(text.isEmpty ? raw : text))",
                    kind: "whiteboard",
                    drawingId: drawing.id,
                    elementId: string(element["elementId"]),
                    elementIndex: index
                ))
            }
        }
        return output
    }

    private func preview(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= 32 ? clean : String(clean.prefix(32))
    }

    private func modelInitialNode(repository: CBrainRepository) -> CBrainNode? {
        let active = repository.activeNodes()
        if active.isEmpty { return nil }
        if let journal = repository.nodeByMarkdownFile("日记库.md"), journal.isActive {
            return journal
        }
        return active.first(where: { $0.topic == "日记库" || $0.fileName == "日记库" })
            ?? active.first(where: { $0.topic == "Diary" || $0.fileName == "Diary" })
            ?? active[0]
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        status = error.localizedDescription
    }
}

struct WhiteboardStart: Identifiable {
    var id: String { drawing.id + focusElementId + String(focusElementIndex) }
    var store: LibraryStore
    var repository: CBrainRepository
    var whiteboards: WhiteboardRepository
    var drawing: WhiteboardDrawing
    var focusElementId: String
    var focusElementIndex: Int
}

private func string(_ value: Any?, defaultValue: String = "") -> String {
    if let text = value as? String {
        return text
    }
    if let number = value as? NSNumber {
        return number.stringValue
    }
    return defaultValue
}

enum ExistingLinkAction {
    case parent
    case child
    case related
}

enum RelationKind: Equatable {
    case parent
    case sibling
    case child
    case related
}
