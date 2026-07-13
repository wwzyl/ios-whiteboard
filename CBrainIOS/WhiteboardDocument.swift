import SwiftUI
import UIKit

let defaultTextWidth: CGFloat = 220
let freeTextFontSize: CGFloat = 16
let nodeTextFontSize: CGFloat = 18
let nodeTextPaddingX: CGFloat = 10
let textRawField = "cbrainWhiteboardRawText"
let lineLabelField = "cbrainLineLabelFor"

final class WhiteboardDocument: ObservableObject {
    @Published var document: [String: Any]
    @Published var selectedIds = Set<String>()
    @Published var mode = "select"
    @Published var scale: CGFloat = 1
    @Published var pan = CGPoint.zero
    @Published var status = ""

    private(set) var undoStack: [Data] = []
    private(set) var redoStack: [Data] = []
    private var internalClipboard: [[String: Any]] = []

    init(document: [String: Any]) {
        self.document = document
        ensureElementIds()
    }

    func elements() -> [[String: Any]] {
        document["elements"] as? [[String: Any]] ?? []
    }

    func setElements(_ elements: [[String: Any]]) {
        document["elements"] = elements
        objectWillChange.send()
    }

    func element(id: String) -> [String: Any]? {
        elements().first { wbString($0["elementId"]) == id }
    }

    func updateElement(id: String, _ transform: (inout [String: Any]) -> Void) {
        var list = elements()
        guard let index = list.firstIndex(where: { wbString($0["elementId"]) == id }) else { return }
        transform(&list[index])
        setElements(list)
    }

    func appendElement(_ element: [String: Any]) {
        var list = elements()
        list.append(element)
        setElements(list)
    }

    func removeElement(id: String) {
        setElements(elements().filter { wbString($0["elementId"]) != id })
        selectedIds.remove(id)
    }

    func pushUndo() {
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) else { return }
        undoStack.append(data)
        if undoStack.count > 80 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let data = undoStack.popLast(),
              let current = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let previous = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            status = "没有可撤销的操作"
            return
        }
        redoStack.append(current)
        document = previous
        selectedIds.removeAll()
        objectWillChange.send()
    }

    func redo() {
        guard let data = redoStack.popLast(),
              let current = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let next = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            status = "没有可前进的操作"
            return
        }
        undoStack.append(current)
        document = next
        selectedIds.removeAll()
        objectWillChange.send()
    }

    func ensureElementIds() {
        var changed = false
        var list = elements()
        for index in list.indices where wbString(list[index]["elementId"]).isEmpty {
            list[index]["elementId"] = UUID().uuidString
            changed = true
        }
        if changed {
            document["elements"] = list
        }
    }

    func baseElement(type: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> [String: Any] {
        [
            "elementId": UUID().uuidString,
            "type": type,
            "x": x,
            "y": y,
            "width": width,
            "height": height,
            "rotate": 0,
            "isLocked": false
        ]
    }

    func baseStyle(stroke: String, fill: String, lineWidth: Any) -> [String: Any] {
        [
            "strokeStyle": stroke,
            "fillStyle": fill,
            "lineWidth": lineWidth,
            "lineDash": 0,
            "globalAlpha": 1
        ]
    }

    func textElement(x: CGFloat, y: CGFloat, text: String) -> [String: Any] {
        var style = baseStyle(stroke: "", fill: "#000000", lineWidth: "small")
        style["fontSize"] = freeTextFontSize
        style["lineHeightRatio"] = 1.15
        style["fontFamily"] = "Microsoft YaHei"
        style["textAlign"] = "left"
        var element = baseElement(type: "text", x: x, y: y, width: defaultTextWidth, height: 27)
        element["style"] = style
        element["text"] = text
        element[textRawField] = text
        fitTextElement(&element, text: text, allowGrowWidth: true)
        return element
    }

    func shapeElement(type: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> [String: Any] {
        var element = baseElement(type: type, x: x, y: y, width: width, height: height)
        element["style"] = baseStyle(stroke: "#000000", fill: "transparent", lineWidth: "small")
        return element
    }

    func connectorElement(type: String, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) -> [String: Any] {
        var element = baseElement(type: type, x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        element["style"] = baseStyle(stroke: "#000000", fill: "transparent", lineWidth: "small")
        element["pointArr"] = [[x1, y1], [x2, y2]]
        updateConnectorBounds(&element)
        return element
    }

    func centeredTextElement(for shape: inout [String: Any], text: String) -> [String: Any] {
        var groupId = wbString(shape["groupId"])
        if groupId.isEmpty {
            groupId = UUID().uuidString
            shape["groupId"] = groupId
        }
        var element = textElement(x: wbCGFloat(shape["x"]) + 10, y: wbCGFloat(shape["y"]), text: text)
        element["groupId"] = groupId
        var style = wbDict(element["style"])
        style["textAlign"] = "center"
        style["verticalAlign"] = "middle"
        element["style"] = style
        syncCenteredText(shape: shape, text: &element)
        return element
    }

    func syncCenteredText(shape: [String: Any], text: inout [String: Any]) {
        var style = wbDict(text["style"])
        guard wbString(style["textAlign"]) == "center" else { return }
        let x = wbCGFloat(shape["x"])
        let y = wbCGFloat(shape["y"])
        let width = max(30, wbCGFloat(shape["width"], defaultValue: 120))
        let height = max(22, wbCGFloat(shape["height"], defaultValue: 60))
        text["x"] = x + 10
        text["y"] = y
        text["width"] = max(10, width - 20)
        text["height"] = height
        style["fontSize"] = max(12, min(34, round(height * 0.38)))
        text["style"] = style
    }

    func syncGroupText(shapeId: String) {
        var list = elements()
        guard let shapeIndex = list.firstIndex(where: { wbString($0["elementId"]) == shapeId }) else { return }
        let groupId = wbString(list[shapeIndex]["groupId"])
        guard !groupId.isEmpty,
              let textIndex = list.firstIndex(where: { wbString($0["type"]) == "text" && wbString($0["groupId"]) == groupId }) else { return }
        var text = list[textIndex]
        syncCenteredText(shape: list[shapeIndex], text: &text)
        list[textIndex] = text
        setElements(list)
    }

    func addNoteNode(_ node: CBrainNode) {
        pushUndo()
        let textWidth = max(50, measureLongestLine(node.topic, fontSize: nodeTextFontSize))
        let nodeWidth = max(90, textWidth + nodeTextPaddingX * 2)
        let nodeHeight: CGFloat = 38
        let x = centerWorldX() - nodeWidth / 2
        let y = centerWorldY() - nodeHeight / 2
        let groupId = UUID().uuidString
        var rect = baseElement(type: "rectangle", x: x, y: y, width: nodeWidth, height: nodeHeight)
        rect["nodeId"] = node.id
        rect["groupId"] = groupId
        rect["style"] = baseStyle(stroke: "#409EFF", fill: "#FFFFFF", lineWidth: "middle")
        var text = textElement(x: x + nodeTextPaddingX, y: y + 8, text: node.topic)
        text["nodeId"] = node.id
        text["groupId"] = groupId
        var style = wbDict(text["style"])
        style["fontSize"] = nodeTextFontSize
        style["lineHeightRatio"] = 1.5
        style["fillStyle"] = "#222"
        style["textAlign"] = "left"
        style.removeValue(forKey: "verticalAlign")
        text["style"] = style
        applyNodeTextLayout(shape: rect, text: &text)
        appendElement(rect)
        appendElement(text)
        selectedIds = [wbString(rect["elementId"]), wbString(text["elementId"])]
    }

    func applyNodeTextLayout(shape: [String: Any], text: inout [String: Any]) {
        text["x"] = wbCGFloat(shape["x"]) + nodeTextPaddingX
        text["y"] = wbCGFloat(shape["y"]) + 6
        text["width"] = max(20, wbCGFloat(shape["width"]) - nodeTextPaddingX * 2)
        text["height"] = max(20, wbCGFloat(shape["height"]) - 4)
    }

    func normalizeElementsBeforeSave() {
        ensureElementIds()
        updateBoundConnectors()
        normalizeNodeTextPositions()
    }

    func normalizeNodeTextPositions() {
        var list = elements()
        for index in list.indices {
            guard wbString(list[index]["type"]) == "text",
                  !wbString(list[index]["nodeId"]).isEmpty else { continue }
            let nodeId = wbString(list[index]["nodeId"])
            let groupId = wbString(list[index]["groupId"])
            guard let shape = list.first(where: { item in
                let sameNode = !nodeId.isEmpty && wbString(item["nodeId"]) == nodeId
                let sameGroup = !groupId.isEmpty && wbString(item["groupId"]) == groupId
                let type = wbString(item["type"])
                return (sameNode || sameGroup) && (type == "rectangle" || type == "circle" || type == "ellipse")
            }) else { continue }
            applyNodeTextLayout(shape: shape, text: &list[index])
        }
        setElements(list)
    }

    func fitTextElement(_ element: inout [String: Any], text: String, allowGrowWidth: Bool) {
        let normalized = normalizeText(text)
        element["text"] = normalized
        if wbString(element[textRawField]).isEmpty {
            element[textRawField] = text
        }
        if allowGrowWidth {
            element["width"] = measuredTextWidth(element, text: normalized)
        }
        element["height"] = measuredTextHeight(element, text: normalized)
    }

    func normalizeText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    func rawTextForLayout(_ element: [String: Any]) -> String {
        let raw = wbString(element[textRawField])
        return raw.isEmpty ? wbString(element["text"]) : raw
    }

    func measuredTextWidth(_ element: [String: Any], text: String) -> CGFloat {
        let fontSize = textFontSize(element)
        let lines = normalizeText(text).split(separator: "\n", omittingEmptySubsequences: false)
        let widest = lines.map { measureText(String($0), fontSize: fontSize) }.max() ?? 0
        return min(max(defaultTextWidth, widest + 12), 800)
    }

    func measuredTextHeight(_ element: [String: Any], text: String) -> CGFloat {
        let fontSize = textFontSize(element)
        let ratio = wbCGFloat(wbDict(element["style"])["lineHeightRatio"], defaultValue: 1.15)
        let lineCount = max(1, normalizeText(text).split(separator: "\n", omittingEmptySubsequences: false).count)
        return max(fontSize + 10, CGFloat(lineCount) * fontSize * ratio + 8)
    }

    func textFontSize(_ element: [String: Any]) -> CGFloat {
        max(8, wbCGFloat(wbDict(element["style"])["fontSize"], defaultValue: freeTextFontSize))
    }

    func hit(_ point: CGPoint) -> String? {
        let list = elements()
        for element in list.reversed() where hitElement(element, point: point) {
            return wbString(element["elementId"])
        }
        return nil
    }

    func hitElement(_ element: [String: Any], point: CGPoint) -> Bool {
        if isConnector(element) {
            let a = connectorPoint(element, index: 0)
            let b = connectorPoint(element, index: 1)
            return distanceToLine(point, a, b) <= max(8, lineWidth(wbDict(element["style"])) + 6)
        }
        return bounds(element).insetBy(dx: -6, dy: -6).contains(point)
    }

    func selectElementWithGroup(id: String) {
        selectedIds.removeAll()
        guard let source = element(id: id) else { return }
        let groupId = wbString(source["groupId"])
        let nodeId = wbString(source["nodeId"])
        for element in elements() {
            let sameGroup = !groupId.isEmpty && wbString(element["groupId"]) == groupId
            let sameNode = !nodeId.isEmpty && wbString(element["nodeId"]) == nodeId
            if sameGroup || sameNode {
                selectedIds.insert(wbString(element["elementId"]))
            }
        }
        if selectedIds.isEmpty {
            selectedIds.insert(id)
        }
    }

    func moveSelection(dx: CGFloat, dy: CGFloat) {
        guard !selectedIds.isEmpty else { return }
        var list = elements()
        for index in list.indices where selectedIds.contains(wbString(list[index]["elementId"])) {
            if isConnector(list[index]) {
                movePoint(&list[index], index: 0, dx: dx, dy: dy)
                movePoint(&list[index], index: 1, dx: dx, dy: dy)
                updateConnectorBounds(&list[index])
            } else {
                list[index]["x"] = wbCGFloat(list[index]["x"]) + dx
                list[index]["y"] = wbCGFloat(list[index]["y"]) + dy
            }
        }
        setElements(list)
        updateBoundConnectors()
    }

    func resizeElement(id: String, to point: CGPoint) {
        var list = elements()
        guard let index = list.firstIndex(where: { wbString($0["elementId"]) == id }) else { return }
        if wbString(list[index]["type"]) == "text" {
            list[index]["width"] = max(40, point.x - wbCGFloat(list[index]["x"]))
            list[index]["height"] = max(24, point.y - wbCGFloat(list[index]["y"]))
        } else {
            list[index]["width"] = max(20, point.x - wbCGFloat(list[index]["x"]))
            list[index]["height"] = max(20, point.y - wbCGFloat(list[index]["y"]))
        }
        let changedId = wbString(list[index]["elementId"])
        setElements(list)
        syncGroupText(shapeId: changedId)
        updateBoundConnectors()
    }

    func deleteSelection() {
        guard !selectedIds.isEmpty else { return }
        pushUndo()
        setElements(elements().filter { !selectedIds.contains(wbString($0["elementId"])) })
        selectedIds.removeAll()
    }

    func copySelection() {
        let copy = elements().filter { selectedIds.contains(wbString($0["elementId"])) }
        internalClipboard = copy
        if let data = try? JSONSerialization.data(withJSONObject: copy, options: []),
           let text = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = text
        }
        status = "已复制 \(copy.count) 个元素"
    }

    func pasteAtCenter() {
        paste(at: CGPoint(x: centerWorldX(), y: centerWorldY()))
    }

    func paste(at point: CGPoint) {
        var source = internalClipboard
        if source.isEmpty,
           let text = UIPasteboard.general.string,
           let data = text.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            source = parsed
        }
        guard !source.isEmpty else { return }
        pushUndo()
        let bounds = unionBounds(source)
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        let groupMap = Dictionary(uniqueKeysWithValues: Set(source.map { wbString($0["groupId"]) }.filter { !$0.isEmpty }).map { ($0, UUID().uuidString) })
        var next = elements()
        selectedIds.removeAll()
        for var element in source {
            element["elementId"] = UUID().uuidString
            if let mapped = groupMap[wbString(element["groupId"])] {
                element["groupId"] = mapped
            }
            if isConnector(element) {
                movePoint(&element, index: 0, dx: dx, dy: dy)
                movePoint(&element, index: 1, dx: dx, dy: dy)
                updateConnectorBounds(&element)
            } else {
                element["x"] = wbCGFloat(element["x"]) + dx
                element["y"] = wbCGFloat(element["y"]) + dy
            }
            selectedIds.insert(wbString(element["elementId"]))
            next.append(element)
        }
        setElements(next)
    }

    func groupSelection() {
        guard selectedIds.count >= 2 else { return }
        pushUndo()
        let groupId = UUID().uuidString
        var list = elements()
        for index in list.indices where selectedIds.contains(wbString(list[index]["elementId"])) {
            list[index]["groupId"] = groupId
        }
        setElements(list)
        status = "已绑定"
    }

    func ungroupSelection() {
        guard !selectedIds.isEmpty else { return }
        pushUndo()
        var list = elements()
        for index in list.indices where selectedIds.contains(wbString(list[index]["elementId"])) {
            list[index]["groupId"] = ""
            if isConnector(list[index]) {
                list[index].removeValue(forKey: "bindings")
            }
        }
        setElements(list)
    }

    func changeSelectedTextColor(_ value: String) {
        guard !selectedIds.isEmpty else { return }
        pushUndo()
        var list = elements()
        for index in list.indices where selectedIds.contains(wbString(list[index]["elementId"])) && wbString(list[index]["type"]) == "text" {
            var style = wbDict(list[index]["style"])
            if style.isEmpty {
                style = baseStyle(stroke: "", fill: "#000000", lineWidth: "small")
            }
            style["fillStyle"] = value
            list[index]["style"] = style
        }
        setElements(list)
    }

    func focusElement(elementId: String, fallbackIndex: Int) {
        let list = elements()
        let target: [String: Any]?
        if !elementId.isEmpty {
            target = list.first { wbString($0["elementId"]) == elementId }
        } else if fallbackIndex >= 0 && fallbackIndex < list.count {
            target = list[fallbackIndex]
        } else {
            target = nil
        }
        guard let target else { return }
        selectedIds = [wbString(target["elementId"])]
        pan = CGPoint(x: 180 - wbCGFloat(target["x"]) * scale, y: 180 - wbCGFloat(target["y"]) * scale)
    }

    func fitToContent(viewSize: CGSize = .zero) {
        let list = elements()
        guard !list.isEmpty else {
            scale = 1
            pan = CGPoint(x: 20, y: 20)
            return
        }
        let r = unionBounds(list)
        let size = viewSize == .zero ? CGSize(width: 360, height: 420) : viewSize
        let sx = size.width / max(1, r.width + 80)
        let sy = size.height / max(1, r.height + 80)
        scale = min(1.3, max(0.35, min(sx, sy)))
        pan = CGPoint(x: size.width / 2 - r.midX * scale, y: size.height / 2 - r.midY * scale)
    }

    func updateBoundConnectors() {
        var list = elements()
        for index in list.indices where isConnector(list[index]) {
            for endpoint in 0...1 {
                let targetId = binding(list[index], endpoint)
                guard !targetId.isEmpty,
                      let target = list.first(where: { wbString($0["elementId"]) == targetId }) else { continue }
                let other = connectorPoint(list[index], index: endpoint == 0 ? 1 : 0)
                let snapped = edgePoint(bounds(target), from: other, to: CGPoint(x: bounds(target).midX, y: bounds(target).midY))
                setPoint(&list[index], index: endpoint, point: snapped)
            }
            updateConnectorBounds(&list[index])
            positionAttachedConnectorLabel(&list, connectorIndex: index)
        }
        setElements(list)
    }

    func snapConnectorEndpoint(_ connector: inout [String: Any], endpoint: Int) {
        let p = connectorPoint(connector, index: endpoint)
        let target = elements().reversed().first { element in
            wbString(element["elementId"]) != wbString(connector["elementId"]) && !isConnector(element) && bounds(element).contains(p)
        }
        guard let target else {
            clearBinding(&connector, endpoint)
            return
        }
        let other = connectorPoint(connector, index: endpoint == 0 ? 1 : 0)
        let snapped = edgePoint(bounds(target), from: other, to: p)
        setPoint(&connector, index: endpoint, point: snapped)
        setBinding(&connector, endpoint, targetId: wbString(target["elementId"]))
    }

    func commitText(id: String?, at point: CGPoint, text: String) {
        if let id, !id.isEmpty {
            pushUndo()
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                removeElement(id: id)
                return
            }
            updateElement(id: id) { element in
                fitTextElement(&element, text: text, allowGrowWidth: true)
            }
            if let shapeId = findGroupShapeId(forTextId: id) {
                syncGroupText(shapeId: shapeId)
            }
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pushUndo()
        let element = textElement(x: point.x, y: point.y, text: text)
        selectedIds = [wbString(element["elementId"])]
        appendElement(element)
    }

    func commitConnectorLabel(connectorId: String, text: String) {
        guard !connectorId.isEmpty else { return }
        pushUndo()
        var list = elements()
        guard let connectorIndex = list.firstIndex(where: { wbString($0["elementId"]) == connectorId }) else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelIndex = list.firstIndex(where: { wbString($0["type"]) == "text" && wbString($0[lineLabelField]) == connectorId })
        if value.isEmpty {
            if let labelIndex {
                list.remove(at: labelIndex)
            }
            setElements(list)
            return
        }
        var groupId = wbString(list[connectorIndex]["groupId"])
        if groupId.isEmpty {
            groupId = UUID().uuidString
            list[connectorIndex]["groupId"] = groupId
        }
        let connectorStyle = wbDict(list[connectorIndex]["style"])
        var label: [String: Any]
        if let labelIndex {
            label = list[labelIndex]
        } else {
            label = textElement(x: 0, y: 0, text: value)
            label["groupId"] = groupId
            label[lineLabelField] = connectorId
        }
        label["groupId"] = groupId
        label[lineLabelField] = connectorId
        fitTextElement(&label, text: value, allowGrowWidth: true)
        var style = wbDict(label["style"])
        style["fontSize"] = 14
        style["lineHeightRatio"] = 1.15
        style["fillStyle"] = wbString(connectorStyle["strokeStyle"], defaultValue: "#000000")
        label["style"] = style
        positionConnectorLabel(connector: list[connectorIndex], label: &label)
        if let labelIndex {
            list[labelIndex] = label
        } else {
            list.append(label)
        }
        setElements(list)
        selectedIds = [connectorId]
    }

    func connectorLabelText(connectorId: String) -> String {
        guard let label = elements().first(where: { wbString($0["type"]) == "text" && wbString($0[lineLabelField]) == connectorId }) else { return "" }
        return rawTextForLayout(label)
    }

    func findGroupTextId(forShapeId id: String) -> String? {
        guard let shape = element(id: id) else { return nil }
        let groupId = wbString(shape["groupId"])
        guard !groupId.isEmpty else { return nil }
        return elements().first { wbString($0["type"]) == "text" && wbString($0["groupId"]) == groupId }.map { wbString($0["elementId"]) }
    }

    func findGroupShapeId(forTextId id: String) -> String? {
        guard let text = element(id: id) else { return nil }
        let groupId = wbString(text["groupId"])
        guard !groupId.isEmpty else { return nil }
        return elements().first {
            let type = wbString($0["type"])
            return wbString($0["groupId"]) == groupId && (type == "rectangle" || type == "circle" || type == "ellipse")
        }.map { wbString($0["elementId"]) }
    }

    func ensureCenteredTextForShape(id: String) -> String? {
        if let textId = findGroupTextId(forShapeId: id) {
            return textId
        }
        var list = elements()
        guard let index = list.firstIndex(where: { wbString($0["elementId"]) == id }) else { return nil }
        var shape = list[index]
        let text = centeredTextElement(for: &shape, text: "")
        list[index] = shape
        list.append(text)
        setElements(list)
        return wbString(text["elementId"])
    }

    func isConnector(_ element: [String: Any]) -> Bool {
        let type = wbString(element["type"])
        return type == "arrow" || type == "line"
    }

    func bounds(_ element: [String: Any]) -> CGRect {
        CGRect(x: wbCGFloat(element["x"]), y: wbCGFloat(element["y"]), width: wbCGFloat(element["width"]), height: wbCGFloat(element["height"]))
    }

    func connectorPoint(_ element: [String: Any], index: Int) -> CGPoint {
        let points = element["pointArr"] as? [[Any]]
        guard let point = points?[safe: index] else {
            return CGPoint(x: wbCGFloat(element["x"]), y: wbCGFloat(element["y"]))
        }
        return CGPoint(x: wbCGFloat(point[safe: 0]), y: wbCGFloat(point[safe: 1]))
    }

    func setPoint(_ element: inout [String: Any], index: Int, point: CGPoint) {
        var points = element["pointArr"] as? [[Any]] ?? []
        while points.count <= index {
            points.append([0, 0])
        }
        points[index] = [point.x, point.y]
        element["pointArr"] = points
    }

    func movePoint(_ element: inout [String: Any], index: Int, dx: CGFloat, dy: CGFloat) {
        let p = connectorPoint(element, index: index)
        setPoint(&element, index: index, point: CGPoint(x: p.x + dx, y: p.y + dy))
    }

    func updateConnectorBounds(_ element: inout [String: Any]) {
        let a = connectorPoint(element, index: 0)
        let b = connectorPoint(element, index: 1)
        element["x"] = min(a.x, b.x)
        element["y"] = min(a.y, b.y)
        element["width"] = abs(a.x - b.x)
        element["height"] = abs(a.y - b.y)
    }

    func setBinding(_ connector: inout [String: Any], _ index: Int, targetId: String) {
        var bindings = wbDict(connector["bindings"])
        bindings[index == 0 ? "start" : "end"] = targetId
        connector["bindings"] = bindings
    }

    func clearBinding(_ connector: inout [String: Any], _ index: Int) {
        var bindings = wbDict(connector["bindings"])
        bindings.removeValue(forKey: index == 0 ? "start" : "end")
        connector["bindings"] = bindings
    }

    func binding(_ connector: [String: Any], _ index: Int) -> String {
        wbString(wbDict(connector["bindings"])[index == 0 ? "start" : "end"])
    }

    func edgePoint(_ rect: CGRect, from: CGPoint, to: CGPoint) -> CGPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        if abs(dx) < 0.001 && abs(dy) < 0.001 {
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        let tx = dx > 0 ? (rect.minX - from.x) / dx : (rect.maxX - from.x) / dx
        let ty = dy > 0 ? (rect.minY - from.y) / dy : (rect.maxY - from.y) / dy
        let t = max(tx, ty)
        if t < 0 || t > 1 {
            let distances = [
                (abs(to.x - rect.minX), CGPoint(x: rect.minX, y: min(rect.maxY, max(rect.minY, to.y)))),
                (abs(to.x - rect.maxX), CGPoint(x: rect.maxX, y: min(rect.maxY, max(rect.minY, to.y)))),
                (abs(to.y - rect.minY), CGPoint(x: min(rect.maxX, max(rect.minX, to.x)), y: rect.minY)),
                (abs(to.y - rect.maxY), CGPoint(x: min(rect.maxX, max(rect.minX, to.x)), y: rect.maxY))
            ]
            return distances.min { $0.0 < $1.0 }?.1 ?? CGPoint(x: rect.midX, y: rect.midY)
        }
        return CGPoint(x: from.x + dx * t, y: from.y + dy * t)
    }

    func positionAttachedConnectorLabel(_ list: inout [[String: Any]], connectorIndex: Int) {
        let connector = list[connectorIndex]
        guard let labelIndex = list.firstIndex(where: { wbString($0["type"]) == "text" && wbString($0[lineLabelField]) == wbString(connector["elementId"]) }) else { return }
        var label = list[labelIndex]
        positionConnectorLabel(connector: connector, label: &label)
        list[labelIndex] = label
    }

    func positionConnectorLabel(connector: [String: Any], label: inout [String: Any]) {
        let mid = connectorMidpoint(connector)
        label["rotate"] = connectorAngle(connector)
        let text = wbString(label["text"])
        let width = measuredTextWidth(label, text: text)
        let height = measuredTextHeight(label, text: text)
        label["width"] = width
        label["height"] = height
        label["x"] = mid.x - width / 2
        label["y"] = mid.y - height / 2
    }

    func connectorMidpoint(_ connector: [String: Any]) -> CGPoint {
        let a = connectorPoint(connector, index: 0)
        let b = connectorPoint(connector, index: 1)
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    func connectorAngle(_ connector: [String: Any]) -> CGFloat {
        let a = connectorPoint(connector, index: 0)
        let b = connectorPoint(connector, index: 1)
        var angle = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
        if angle > 90 { angle -= 180 }
        if angle < -90 { angle += 180 }
        return angle
    }

    func lineWidth(_ style: [String: Any]) -> CGFloat {
        let value = style["lineWidth"]
        if let number = value as? NSNumber {
            return max(1, CGFloat(truncating: number))
        }
        let text = wbString(value)
        if text == "large" { return 4 }
        if text == "middle" { return 3 }
        return 2
    }

    func worldToScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + pan.x, y: point.y * scale + pan.y)
    }

    func screenToWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.x) / scale, y: (point.y - pan.y) / scale)
    }

    func centerWorldX() -> CGFloat {
        screenToWorld(CGPoint(x: UIScreen.main.bounds.width / 2, y: 0)).x
    }

    func centerWorldY() -> CGFloat {
        screenToWorld(CGPoint(x: 0, y: UIScreen.main.bounds.height / 2)).y
    }

    private func unionBounds(_ items: [[String: Any]]) -> CGRect {
        var rect = CGRect.null
        for element in items {
            if isConnector(element) {
                rect = rect.union(CGRect(origin: connectorPoint(element, index: 0), size: .zero).insetBy(dx: -8, dy: -8))
                rect = rect.union(CGRect(origin: connectorPoint(element, index: 1), size: .zero).insetBy(dx: -8, dy: -8))
            } else {
                rect = rect.union(bounds(element))
            }
        }
        return rect.isNull ? .zero : rect
    }

    private func distanceToLine(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        if dx == 0 && dy == 0 {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
        let x = a.x + t * dx
        let y = a.y + t * dy
        return hypot(p.x - x, p.y - y)
    }
}

func wbString(_ value: Any?, defaultValue: String = "") -> String {
    if let text = value as? String {
        return text
    }
    if let number = value as? NSNumber {
        return number.stringValue
    }
    return defaultValue
}

func wbCGFloat(_ value: Any?, defaultValue: CGFloat = 0) -> CGFloat {
    if let number = value as? NSNumber {
        return CGFloat(truncating: number)
    }
    if let value = value as? CGFloat {
        return value
    }
    if let value = value as? Double {
        return CGFloat(value)
    }
    if let value = value as? Int {
        return CGFloat(value)
    }
    if let text = value as? String, let double = Double(text) {
        return CGFloat(double)
    }
    return defaultValue
}

func wbDict(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
}

func measureText(_ text: String, fontSize: CGFloat) -> CGFloat {
    let font = UIFont.systemFont(ofSize: fontSize)
    return (text as NSString).size(withAttributes: [.font: font]).width
}

func measureLongestLine(_ text: String, fontSize: CGFloat) -> CGFloat {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { measureText(String($0), fontSize: fontSize) }
        .max() ?? 0
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
