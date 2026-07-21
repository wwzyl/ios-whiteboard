import Foundation

struct WhiteboardDrawing: Identifiable, Hashable {
    var id: String
    var topic: String
    var nodeId: String
    var raw: [String: Any]

    static func == (lhs: WhiteboardDrawing, rhs: WhiteboardDrawing) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

final class WhiteboardRepository {
    private let store: LibraryStore
    private var index: [String: Any] = [:]
    private var drawings: [[String: Any]] = []
    private var arrayIndexFormat = true

    init(store: LibraryStore) throws {
        self.store = store
        try loadIndex()
    }

    func openOrCreate(for node: CBrainNode) throws -> WhiteboardDrawing {
        if let existing = drawingByNodeId(node.id) {
            try ensureCanvasFile(existing)
            return existing
        }

        let id = UUID().uuidString
        let now = Self.nowIso()
        let raw: [String: Any] = [
            "id": id,
            "topic": node.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled whiteboard" : node.topic,
            "createTime": now,
            "updateTime": now,
            "nodeid": node.id,
            "description": "",
            "musicUrl": "",
            "musicTitle": ""
        ]
        drawings.append(raw)
        try saveIndex()
        try saveCanvas(id: id, canvas: Self.defaultCanvas())
        return drawing(raw)
    }

    func drawingById(_ id: String) -> WhiteboardDrawing? {
        drawings.first { wbString($0["id"]) == id }.map(drawing)
    }

    func allDrawings() -> [WhiteboardDrawing] {
        drawings.map(drawing)
    }

    func readCanvas(_ drawing: WhiteboardDrawing) throws -> [String: Any] {
        try ensureCanvasFile(drawing)
        let data = try store.readData(canvasPath(drawing.id))
        guard let object = try JSONSerialization.jsonObject(with: Self.cleanJsonData(data)) as? [String: Any] else {
            throw CBrainError.message("Canvas file is not a JSON object: \(canvasPath(drawing.id))")
        }
        return object
    }

    func canvasModifiedTime(_ drawing: WhiteboardDrawing) -> Int64 {
        let url = store.url(canvasPath(drawing.id))
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    func saveCanvas(_ drawing: WhiteboardDrawing, canvas: [String: Any]) throws {
        if let index = drawings.firstIndex(where: { wbString($0["id"]) == drawing.id }) {
            drawings[index]["updateTime"] = Self.nowIso()
        }
        try saveCanvas(id: drawing.id, canvas: canvas)
        try saveIndex()
    }

    func deleteDrawing(_ drawing: WhiteboardDrawing) throws {
        let path = canvasPath(drawing.id)
        try store.recordTombstone(path, deletedTime: Int64(Date().timeIntervalSince1970 * 1000))
        drawings.removeAll { wbString($0["id"]) == drawing.id }
        try saveIndex()
        store.delete(path)
    }

    func usageInfo(for nodeId: String, excluding drawingId: String? = nil) -> String {
        guard !nodeId.isEmpty else { return "" }
        var parts: [String] = []
        var seen = Set<String>()

        for drawing in allDrawings() where drawing.nodeId == nodeId {
            appendUnique("本身为白板", to: &parts, seen: &seen)
        }

        for drawing in allDrawings() {
            guard drawing.id != drawingId, drawing.nodeId != nodeId else { continue }
            guard let canvas = try? readCanvas(drawing),
                  let elements = canvas["elements"] as? [[String: Any]] else { continue }
            if elements.contains(where: { wbString($0["nodeId"]) == nodeId }) {
                appendUnique("\(drawing.topic)(白板)", to: &parts, seen: &seen)
            }
        }
        return parts.joined(separator: ", ")
    }

    private func loadIndex() throws {
        guard store.exists("drawings.json") else {
            arrayIndexFormat = true
            drawings = []
            index = ["value": drawings, "Count": 0]
            try saveIndex()
            return
        }

        let data = try store.readData("drawings.json")
        let parsed = try JSONSerialization.jsonObject(with: Self.cleanJsonData(data))
        if let array = parsed as? [[String: Any]] {
            arrayIndexFormat = true
            drawings = array
            index = ["value": array, "Count": array.count]
        } else if var object = parsed as? [String: Any] {
            arrayIndexFormat = false
            drawings = object["value"] as? [[String: Any]] ?? []
            object["value"] = drawings
            index = object
        } else {
            throw CBrainError.message("drawings.json must be a JSON array or object")
        }
    }

    private func drawingByNodeId(_ nodeId: String) -> WhiteboardDrawing? {
        drawings.first { wbString($0["nodeid"]) == nodeId }.map(drawing)
    }

    private func drawing(_ raw: [String: Any]) -> WhiteboardDrawing {
        WhiteboardDrawing(
            id: wbString(raw["id"]),
            topic: wbString(raw["topic"], defaultValue: "Untitled whiteboard"),
            nodeId: wbString(raw["nodeid"]),
            raw: raw
        )
    }

    private func ensureCanvasFile(_ drawing: WhiteboardDrawing) throws {
        guard !drawing.id.isEmpty, !store.exists(canvasPath(drawing.id)) else { return }
        try saveCanvas(id: drawing.id, canvas: Self.defaultCanvas())
    }

    private func saveCanvas(id: String, canvas: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: canvas, options: [.prettyPrinted, .sortedKeys])
        try store.writeData(canvasPath(id), data)
    }

    private func saveIndex() throws {
        index["value"] = drawings
        index["Count"] = drawings.count
        let payload: Any = arrayIndexFormat ? drawings : index
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try store.writeData("drawings.json", data)
    }

    private func canvasPath(_ id: String) -> String {
        "canvas/\(id).json"
    }

    private func appendUnique(_ value: String, to parts: inout [String], seen: inout Set<String>) {
        guard !seen.contains(value) else { return }
        seen.insert(value)
        parts.append(value)
    }

    static func defaultCanvas() -> [String: Any] {
        [
            "state": [
                "scale": 1,
                "scrollX": 0,
                "scrollY": 100,
                "scrollStep": 50,
                "backgroundColor": "",
                "strokeStyle": "#000000",
                "fillStyle": "transparent",
                "fontFamily": "Microsoft YaHei",
                "fontSize": 18,
                "dragStrokeStyle": "#666",
                "showGrid": false,
                "readonly": false,
                "gridConfig": [
                    "size": 20,
                    "strokeStyle": "#dfe0e1",
                    "lineWidth": 1
                ]
            ],
            "elements": []
        ]
    }

    private static func nowIso() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func cleanJsonData(_ data: Data) -> Data {
        guard Data(data.prefix(3)) == Data([0xEF, 0xBB, 0xBF]) else { return data }
        return Data(data.dropFirst(3))
    }
}
