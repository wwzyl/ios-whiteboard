import Foundation

final class CBrainRepository {
    private let store: LibraryStore
    private var graph: [String: Any] = [:]
    private var nodes: [String: [String: Any]] = [:]
    private var links: [String: [String: Any]] = [:]
    private var noteSearchCache: [String: String] = [:]

    init(store: LibraryStore) {
        self.store = store
    }

    func load() throws {
        let data = try store.readData("graph.json")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CBrainError.invalidLibrary
        }
        graph = root
        nodes = dictionaryOfDictionaries(root["nodes"])
        links = dictionaryOfDictionaries(root["links"])
    }

    func importOrphanMarkdownNotes() throws -> Int {
        var imported = 0
        for fileName in store.listMarkdownFiles("notes") {
            let base = Self.stripMarkdownExtension(fileName)
            if base.isEmpty || Self.isConflictFile(base) || nodeByFileName(base) != nil {
                continue
            }
            _ = createNodeForExistingNote(fileName: base)
            imported += 1
        }
        if imported > 0 {
            try saveGraph()
        }
        return imported
    }

    func activeNodes() -> [CBrainNode] {
        nodes.keys.compactMap { self.node($0) }.filter(\.isActive).sorted {
            $0.topic.localizedStandardCompare($1.topic) == .orderedAscending
        }
    }

    func node(_ id: String) -> CBrainNode? {
        guard let raw = nodes[id] else { return nil }
        return CBrainNode(
            id: id,
            topic: string(raw["topic"], defaultValue: "Untitled"),
            fileName: string(raw["fileName"], defaultValue: string(raw["topic"], defaultValue: "Untitled")),
            status: string(raw["status"], defaultValue: "1")
        )
    }

    func parents(of id: String) -> [CBrainNode] {
        let ids = orderedLinkIds { link in
            link.isActive && link.linkType == "1" && link.nodeId2 == id ? link.nodeId1 : nil
        }
        return nodesByIds(ids)
    }

    func children(of id: String) -> [CBrainNode] {
        let ids = orderedLinkIds { link in
            link.isActive && link.linkType == "1" && link.nodeId1 == id ? link.nodeId2 : nil
        }
        return nodesByIds(ids)
    }

    func related(to id: String) -> [CBrainNode] {
        let ids = orderedLinkIds { link in
            guard link.isActive && link.linkType == "0" else { return nil }
            if link.nodeId1 == id { return link.nodeId2 }
            if link.nodeId2 == id { return link.nodeId1 }
            return nil
        }
        return nodesByIds(ids)
    }

    func readNote(_ node: CBrainNode) throws -> String {
        try store.readMarkdownText(notePath(node))
    }

    func saveNote(_ node: CBrainNode, note: String) throws {
        try store.writeMarkdownText(notePath(node), note)
        noteSearchCache[Self.safeFileName(node.fileName)] = note
        var raw = try rawNode(node.id)
        let now = Self.nowDateTime()
        raw["updateTime"] = now
        nodes[node.id] = raw
        try appendModify(nodeId: node.id, nodeName: node.topic, type: "1", table: "cbNode", key: "note", value: note, comment: "修改节点笔记", time: now)
        try saveGraph()
    }

    func addChild(parentId: String, title: String) throws -> CBrainNode {
        let child = createNode(title: title)
        try addLink(nodeId1: parentId, nodeId2: child.id, type: "1")
        try updateChildCount(parentId)
        try saveGraph()
        try appendModify(nodeId: child.id, nodeName: child.topic, type: "0", table: "cbNode", key: "", value: "", comment: "新增节点-类型1", time: Self.nowDateTime())
        return child
    }

    func addParent(childId: String, title: String) throws -> CBrainNode {
        let parent = createNode(title: title)
        try addLink(nodeId1: parent.id, nodeId2: childId, type: "1")
        try updateChildCount(parent.id)
        try saveGraph()
        try appendModify(nodeId: parent.id, nodeName: parent.topic, type: "0", table: "cbNode", key: "", value: "", comment: "新增节点-类型1", time: Self.nowDateTime())
        return parent
    }

    func addRelated(sourceId: String, title: String) throws -> CBrainNode {
        let related = createNode(title: title)
        try addLink(nodeId1: sourceId, nodeId2: related.id, type: "0")
        try saveGraph()
        try appendModify(nodeId: related.id, nodeName: related.topic, type: "0", table: "cbNode", key: "", value: "", comment: "新增节点-类型1", time: Self.nowDateTime())
        return related
    }

    func addExistingParent(childId: String, parentId: String) throws -> CBrainNode {
        if childId == parentId {
            throw CBrainError.message("Cannot link a node to itself")
        }
        guard let parent = node(parentId), parent.isActive else {
            throw CBrainError.message("Parent node not found")
        }
        if try addLinkIfMissing(nodeId1: parentId, nodeId2: childId, type: "1") {
            try updateChildCount(parentId)
            try saveGraph()
        }
        return parent
    }

    func addExistingChild(parentId: String, childId: String) throws -> CBrainNode {
        if parentId == childId {
            throw CBrainError.message("Cannot link a node to itself")
        }
        guard let child = node(childId), child.isActive else {
            throw CBrainError.message("Child node not found")
        }
        if try addLinkIfMissing(nodeId1: parentId, nodeId2: childId, type: "1") {
            try updateChildCount(parentId)
            try saveGraph()
        }
        return child
    }

    func addExistingRelated(sourceId: String, targetId: String) throws -> CBrainNode {
        if sourceId == targetId {
            throw CBrainError.message("Cannot link a node to itself")
        }
        guard let target = node(targetId), target.isActive else {
            throw CBrainError.message("Related node not found")
        }
        if try addLinkIfMissing(nodeId1: sourceId, nodeId2: targetId, type: "0") {
            try saveGraph()
        }
        return target
    }

    func renameNode(nodeId: String, title: String) throws -> CBrainNode {
        guard let oldNode = node(nodeId) else { throw CBrainError.nodeNotFound }
        let clean = cleanTitle(title)
        let oldPath = notePath(oldNode)
        let oldContent = try store.readMarkdownText(oldPath)
        var raw = try rawNode(nodeId)
        let now = Self.nowDateTime()
        raw["topic"] = clean
        raw["fileName"] = uniqueFileName(clean, ownId: nodeId)
        raw["updateTime"] = now
        nodes[nodeId] = raw

        guard let newNode = node(nodeId) else { throw CBrainError.nodeNotFound }
        let newPath = notePath(newNode)
        try store.writeMarkdownText(newPath, oldContent)
        if oldPath != newPath {
            store.delete(oldPath)
        }
        try appendModify(nodeId: nodeId, nodeName: clean, type: "1", table: "cbNode", key: "topic", value: clean, comment: "修改节点topic", time: now)
        try appendModify(nodeId: nodeId, nodeName: clean, type: "1", table: "cbNode", key: "fileName", value: clean, comment: "修改节点fileName", time: now)
        try saveGraph()
        return newNode
    }

    func softDeleteNode(_ nodeId: String) throws {
        guard let current = node(nodeId) else { return }
        let now = Self.nowDateTime()
        var raw = try rawNode(nodeId)
        raw["status"] = "0"
        raw["updateTime"] = now
        nodes[nodeId] = raw

        for key in links.keys {
            guard var linkRaw = links[key] else { continue }
            let nodeId1 = string(linkRaw["nodeId1"])
            let nodeId2 = string(linkRaw["nodeId2"])
            if nodeId == nodeId1 || nodeId == nodeId2 {
                linkRaw["status"] = "0"
                linkRaw["updateTime"] = now
                links[key] = linkRaw
            }
        }
        try appendModify(nodeId: current.id, nodeName: current.topic, type: "2", table: "cbNode", key: "", value: "", comment: "删除节点(及相关链接)", time: now)
        try saveGraph()
    }

    func deleteLink(a: String, b: String, linkType: String) throws {
        var count = 0
        let now = Self.nowDateTime()
        for key in links.keys {
            guard var raw = links[key] else { continue }
            let link = linkFromRaw(id: key, raw: raw)
            guard link.isActive && link.linkType == linkType else { continue }
            let directed = link.nodeId1 == a && link.nodeId2 == b
            let undirected = directed || (link.nodeId1 == b && link.nodeId2 == a)
            let matches = linkType == "1" ? directed : undirected
            if matches {
                raw["status"] = "0"
                raw["updateTime"] = now
                links[key] = raw
                count += 1
            }
        }
        if count > 0 {
            try updateChildCount(a)
            try appendModify(nodeId: a, nodeName: "", type: "2", table: "cbLink", key: "", value: "", comment: "根据节点ID删除连接线: \(a) <-> \(b), 删除数量: \(count)", time: now)
            try saveGraph()
        }
    }

    func search(_ query: String) -> [CBrainSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        var results: [CBrainSearchResult] = []
        var added = Set<String>()

        for item in activeNodes() {
            guard results.count < 80 else { return results }
            if item.topic.lowercased().contains(q) {
                results.append(CBrainSearchResult(nodeId: item.id, title: item.topic, reason: "标题"))
                added.insert(item.id)
            }
        }

        for fileName in store.listMarkdownFiles("notes") {
            guard results.count < 80 else { break }
            let base = Self.stripMarkdownExtension(fileName)
            do {
                let content: String
                if let cached = noteSearchCache[base] {
                    content = cached
                } else {
                    content = try store.readText("notes/\(fileName)")
                    noteSearchCache[base] = content
                }
                guard content.lowercased().contains(q) else { continue }
                var found = nodeByFileName(base)
                if found == nil {
                    found = createNodeForExistingNote(fileName: base)
                    try saveGraph()
                }
                guard let node = found, node.isActive, !added.contains(node.id) else { continue }
                results.append(CBrainSearchResult(nodeId: node.id, title: node.topic, reason: "正文"))
                added.insert(node.id)
            } catch {
                continue
            }
        }
        return results
    }

    func randomNoteNode(excluding currentNodeId: String?) -> CBrainNode? {
        let nodesWithNotes = store.listMarkdownFiles("notes")
            .compactMap { nodeByFileName(Self.stripMarkdownExtension($0)) }
            .filter { $0.isActive && $0.id != currentNodeId }
        return nodesWithNotes.randomElement()
    }

    private func rawNode(_ id: String) throws -> [String: Any] {
        guard let raw = nodes[id] else { throw CBrainError.nodeNotFound }
        return raw
    }

    private func link(_ id: String) -> CBrainLink? {
        guard let raw = links[id] else { return nil }
        return linkFromRaw(id: id, raw: raw)
    }

    private func linkFromRaw(id: String, raw: [String: Any]) -> CBrainLink {
        CBrainLink(
            id: id,
            nodeId1: string(raw["nodeId1"]),
            nodeId2: string(raw["nodeId2"]),
            linkType: string(raw["linkType"], defaultValue: "1"),
            status: string(raw["status"], defaultValue: "1")
        )
    }

    private func orderedLinkIds(_ transform: (CBrainLink) -> String?) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for key in links.keys.sorted() {
            guard let link = link(key), let id = transform(link), !seen.contains(id) else { continue }
            output.append(id)
            seen.insert(id)
        }
        return output
    }

    private func nodesByIds(_ ids: [String]) -> [CBrainNode] {
        ids.compactMap(node).filter(\.isActive)
    }

    private func createNode(title: String) -> CBrainNode {
        let id = newId()
        let now = Self.nowDateTime()
        let clean = cleanTitle(title)
        let fileName = uniqueFileName(clean, ownId: id)
        nodes[id] = [
            "id": id,
            "topic": clean,
            "fileName": fileName,
            "nodeType": "0",
            "othername": "",
            "status": "1",
            "createTime": now,
            "updateTime": now,
            "kq": 0,
            "linkInfo": "{\"childCount\": 0}"
        ]
        return node(id)!
    }

    private func createNodeForExistingNote(fileName: String) -> CBrainNode {
        let id = newId()
        let now = Self.nowDateTime()
        nodes[id] = [
            "id": id,
            "topic": fileName,
            "fileName": fileName,
            "nodeType": "0",
            "othername": "",
            "status": "1",
            "createTime": now,
            "updateTime": now,
            "kq": 0,
            "linkInfo": "{\"childCount\": 0}"
        ]
        return node(id)!
    }

    private func addLink(nodeId1: String, nodeId2: String, type: String) throws {
        let id = newId()
        let now = Self.nowDateTime()
        let interaction = (countExistingLinks(nodeId1: nodeId1, type: type) + 1) * 10000
        links[id] = [
            "columnId": id,
            "nodeId1": nodeId1,
            "nodeId2": nodeId2,
            "linkType": type,
            "status": "1",
            "interaction": interaction,
            "createTime": now,
            "updateTime": now
        ]
        try appendModify(nodeId: nodeId1, nodeName: node(nodeId1)?.topic ?? "", type: "0", table: "cbLink", key: "", value: nodeId2, comment: "Add link", time: now)
    }

    private func addLinkIfMissing(nodeId1: String, nodeId2: String, type: String) throws -> Bool {
        for key in links.keys {
            guard let link = link(key), link.isActive, link.linkType == type else { continue }
            let exists = type == "1"
                ? (link.nodeId1 == nodeId1 && link.nodeId2 == nodeId2)
                : ((link.nodeId1 == nodeId1 && link.nodeId2 == nodeId2) || (link.nodeId1 == nodeId2 && link.nodeId2 == nodeId1))
            if exists {
                return false
            }
        }
        try addLink(nodeId1: nodeId1, nodeId2: nodeId2, type: type)
        return true
    }

    private func countExistingLinks(nodeId1: String, type: String) -> Int {
        links.keys.compactMap { self.link($0) }.filter {
            $0.isActive && $0.linkType == type && $0.nodeId1 == nodeId1
        }.count
    }

    private func updateChildCount(_ nodeId: String) throws {
        guard var raw = nodes[nodeId] else { return }
        raw["linkInfo"] = "{\"childCount\":\(children(of: nodeId).count)}"
        nodes[nodeId] = raw
    }

    private func notePath(_ node: CBrainNode) -> String {
        "notes/\(Self.safeFileName(node.fileName)).md"
    }

    private func uniqueFileName(_ title: String, ownId: String) -> String {
        let base = Self.safeFileName(title)
        var candidate = base
        var index = 2
        while store.exists("notes/\(candidate).md") {
            if let existing = nodeByFileName(candidate), existing.id == ownId {
                break
            }
            candidate = "\(base) \(index)"
            index += 1
        }
        return candidate
    }

    private func nodeByFileName(_ fileName: String) -> CBrainNode? {
        for key in nodes.keys {
            guard let node = node(key), node.fileName == fileName else { continue }
            return node
        }
        return nil
    }

    private func cleanTitle(_ title: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Untitled" : clean
    }

    private func saveGraph() throws {
        graph["nodes"] = nodes
        graph["links"] = links
        let data = try JSONSerialization.data(withJSONObject: graph, options: [.prettyPrinted, .sortedKeys])
        try store.writeData("graph.json", data)
    }

    private func appendModify(nodeId: String, nodeName: String, type: String, table: String, key: String, value: String, comment: String, time: String) throws {
        let item: [String: Any] = [
            "id": "\(Int(Date().timeIntervalSince1970 * 1000))\(Int.random(in: 0...999))",
            "node_id": nodeId,
            "node_name": nodeName,
            "modify_type": type,
            "table_name": table,
            "key_name": key,
            "key_value": value,
            "modify_comment": comment,
            "modify_time": time
        ]

        let date = Self.dateOnly()
        let dailyPath = "modifys/modify_\(date).json"
        var daily = (try? jsonArray(path: dailyPath)) ?? []
        daily.append(item)
        try writeJSONArray(daily, path: dailyPath)

        guard store.exists("modifys.json"),
              var summary = try? jsonObject(path: "modifys.json") else {
            return
        }

        var counts = dictionary(summary["summary"])
        if type == "1" {
            counts["total_modify_count"] = int(counts["total_modify_count"]) + 1
        } else if type == "0" {
            counts["total_add_count"] = int(counts["total_add_count"]) + 1
        } else if type == "2" {
            counts["total_delete_count"] = int(counts["total_delete_count"]) + 1
        }
        summary["summary"] = counts

        var records = (summary["nodes"] as? [[String: Any]]) ?? []
        records.append([
            "id": nodeId,
            "node_name": nodeName,
            "modify_count": 1,
            "modify_time": time
        ])
        summary["nodes"] = records
        try writeJSONObject(summary, path: "modifys.json")
    }

    private func jsonObject(path: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: store.readData(path)) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func jsonArray(path: String) throws -> [[String: Any]] {
        guard let array = try JSONSerialization.jsonObject(with: store.readData(path)) as? [[String: Any]] else {
            return []
        }
        return array
    }

    private func writeJSONObject(_ object: [String: Any], path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try store.writeData(path, data)
    }

    private func writeJSONArray(_ array: [[String: Any]], path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys])
        try store.writeData(path, data)
    }

    private func newId() -> String {
        var id: String
        repeat {
            id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        } while nodes[id] != nil || links[id] != nil
        return id
    }

    private static func stripMarkdownExtension(_ fileName: String) -> String {
        fileName.lowercased().hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
    }

    private static func isConflictFile(_ fileName: String) -> Bool {
        fileName.contains(".remote-conflict-")
    }

    private static func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let parts = name.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: invalid)
        let clean = parts.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Untitled" : clean
    }

    private static func nowDateTime() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    private static func dateOnly() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

private func dictionaryOfDictionaries(_ value: Any?) -> [String: [String: Any]] {
    guard let input = value as? [String: Any] else { return [:] }
    var output: [String: [String: Any]] = [:]
    for (key, value) in input {
        if let dict = value as? [String: Any] {
            output[key] = dict
        }
    }
    return output
}

private func dictionary(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
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

private func int(_ value: Any?) -> Int {
    if let intValue = value as? Int {
        return intValue
    }
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let text = value as? String {
        return Int(text) ?? 0
    }
    return 0
}
