import Foundation

@MainActor
final class CBrainViewModel: ObservableObject {
    @Published private(set) var libraryName = "未导入"
    @Published private(set) var nodes: [CBrainNode] = []
    @Published private(set) var parents: [CBrainNode] = []
    @Published private(set) var children: [CBrainNode] = []
    @Published private(set) var related: [CBrainNode] = []
    @Published private(set) var searchResults: [CBrainSearchResult] = []
    @Published private(set) var selectedNode: CBrainNode?
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
    @Published var errorMessage: String?
    @Published var isSyncing = false
    @Published private(set) var noteDirty = false

    private var store: LibraryStore?
    private var repository: CBrainRepository?
    private var history: [String] = []
    private var historyIndex = -1
    private var navigatingHistory = false
    private var loadingNote = false

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

    func selectNode(_ node: CBrainNode) {
        guard let repository else { return }
        do {
            selectedNode = node
            recordHistory(node.id)
            loadingNote = true
            defer { loadingNote = false }
            noteText = try repository.readNote(node)
            noteDirty = false
            parents = repository.parents(of: node.id)
            children = repository.children(of: node.id)
            related = repository.related(to: node.id)
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
            refresh(keeping: node.id)
            status = "已保存"
        } catch {
            report(error)
        }
    }

    func addChild(title: String) {
        guard let node = selectedNode, let repository else { return }
        do {
            let child = try repository.addChild(parentId: node.id, title: title)
            refresh(keeping: child.id)
            selectNode(child)
        } catch {
            report(error)
        }
    }

    func addParent(title: String) {
        guard let node = selectedNode, let repository else { return }
        do {
            let parent = try repository.addParent(childId: node.id, title: title)
            refresh(keeping: parent.id)
            selectNode(parent)
        } catch {
            report(error)
        }
    }

    func addRelated(title: String) {
        guard let node = selectedNode, let repository else { return }
        do {
            let next = try repository.addRelated(sourceId: node.id, title: title)
            refresh(keeping: next.id)
            selectNode(next)
        } catch {
            report(error)
        }
    }

    func renameSelected(to title: String) {
        guard let node = selectedNode, let repository else { return }
        do {
            let renamed = try repository.renameNode(nodeId: node.id, title: title)
            refresh(keeping: renamed.id)
            selectNode(renamed)
        } catch {
            report(error)
        }
    }

    func deleteSelected() {
        guard let node = selectedNode, let repository else { return }
        do {
            try repository.softDeleteNode(node.id)
            selectedNode = nil
            loadingNote = true
            noteText = ""
            noteDirty = false
            loadingNote = false
            parents = []
            children = []
            related = []
            refresh()
            status = "已删除"
        } catch {
            report(error)
        }
    }

    func openRandomNote() {
        guard let repository else { return }
        if let node = repository.randomNoteNode(excluding: selectedNode?.id) {
            selectNode(node)
        }
    }

    func refreshSearch() {
        runSearch()
    }

    func openHistory(_ direction: Int) {
        guard !history.isEmpty else { return }
        let next = historyIndex + direction
        guard next >= 0 && next < history.count else { return }
        guard let repository, let node = repository.node(history[next]) else { return }
        navigatingHistory = true
        historyIndex = next
        selectNode(node)
        navigatingHistory = false
    }

    func homeNode() {
        guard let repository else { return }
        if let home = modelHomeNode(repository: repository) {
            selectNode(home)
        }
    }

    func linkExisting(_ target: CBrainNode, as action: ExistingLinkAction) {
        guard let current = selectedNode, let repository else { return }
        do {
            switch action {
            case .parent:
                _ = try repository.addExistingParent(childId: current.id, parentId: target.id)
            case .child:
                _ = try repository.addExistingChild(parentId: current.id, childId: target.id)
            case .related:
                _ = try repository.addExistingRelated(sourceId: current.id, targetId: target.id)
            }
            refresh(keeping: current.id)
            if let node = nodes.first(where: { $0.id == current.id }) {
                selectNode(node)
            }
        } catch {
            report(error)
        }
    }

    func removeRelation(_ node: CBrainNode, relation: RelationKind) {
        guard let current = selectedNode, let repository else { return }
        do {
            switch relation {
            case .parent:
                try repository.deleteLink(a: node.id, b: current.id, linkType: "1")
            case .child:
                try repository.deleteLink(a: current.id, b: node.id, linkType: "1")
            case .related:
                try repository.deleteLink(a: current.id, b: node.id, linkType: "0")
            }
            refresh(keeping: current.id)
            if let refreshed = nodes.first(where: { $0.id == current.id }) {
                selectNode(refreshed)
            }
        } catch {
            report(error)
        }
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
            loadingNote = true
            noteText = ""
            noteDirty = false
            loadingNote = false
            parents = []
            children = []
            related = []
            refresh()
            if selectedNode == nil, let first = nodes.first {
                selectNode(first)
            }
            status = imported > 0 ? "已导入 \(imported) 个孤立笔记" : "已打开"
        } catch {
            report(error)
        }
    }

    private func refresh(keeping nodeId: String? = nil) {
        guard let repository else { return }
        nodes = repository.activeNodes()
        runSearch()
        if let nodeId, let current = nodes.first(where: { $0.id == nodeId }) {
            selectedNode = current
            parents = repository.parents(of: current.id)
            children = repository.children(of: current.id)
            related = repository.related(to: current.id)
        }
    }

    private func runSearch() {
        guard let repository else {
            searchResults = []
            return
        }
        searchResults = repository.search(searchQuery)
    }

    private func reloadAfterSync() {
        guard let store else { return }
        do {
            let repository = CBrainRepository(store: store)
            try repository.load()
            self.repository = repository
            let keep = selectedNode?.id
            refresh(keeping: keep)
            if let keep, let node = nodes.first(where: { $0.id == keep }) {
                selectNode(node)
            } else if let first = nodes.first {
                selectNode(first)
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

    private func modelHomeNode(repository: CBrainRepository) -> CBrainNode? {
        if let first = repository.activeNodes().first(where: { $0.topic == "主页" || $0.topic.lowercased() == "home" }) {
            return first
        }
        return repository.activeNodes().first
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        status = error.localizedDescription
    }
}

enum ExistingLinkAction {
    case parent
    case child
    case related
}

enum RelationKind {
    case parent
    case child
    case related
}
