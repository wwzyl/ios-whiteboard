import SwiftUI
import UIKit

struct WhiteboardView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: CBrainViewModel
    let start: WhiteboardStart

    @StateObject private var board: WhiteboardDocument
    @State private var drawing: WhiteboardDrawing
    @State private var notePreview = true
    @State private var canvasOnly = false
    @State private var editRequest: WhiteboardEditRequest?
    @State private var searchPresented = false
    @State private var deleteConfirm = false
    @State private var lastSavedModifiedTime: Int64 = 0

    init(start: WhiteboardStart) {
        self.start = start
        let canvas = (try? start.whiteboards.readCanvas(start.drawing)) ?? WhiteboardRepository.defaultCanvas()
        _board = StateObject(wrappedValue: WhiteboardDocument(document: canvas))
        _drawing = State(initialValue: start.drawing)
        _lastSavedModifiedTime = State(initialValue: start.whiteboards.canvasModifiedTime(start.drawing))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            WhiteboardCanvasView(
                board: board,
                onEditText: { request in
                    editRequest = request
                },
                onSelectNode: { nodeId in
                    if let node = start.repository.node(nodeId) {
                        model.selectNode(node, updateGraph: true)
                    }
                }
            )
            .background(Color(UIColor.systemBackground))

            if !canvasOnly {
                Divider()
                bottomPanel
                    .frame(height: 260)
            }

            Text(board.status.isEmpty ? model.whiteboardStatus : board.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(UIColor.secondarySystemBackground))
        }
        .navigationTitle(drawing.topic)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            board.fitToContent()
            if !start.focusElementId.isEmpty || start.focusElementIndex >= 0 {
                board.focusElement(elementId: start.focusElementId, fallbackIndex: start.focusElementIndex)
            }
        }
        .onDisappear {
            save(showStatus: false)
        }
        .sheet(item: $editRequest) { request in
            WhiteboardTextEditSheet(request: request) { value in
                switch request.kind {
                case .text:
                    board.commitText(id: request.elementId, at: request.worldPoint, text: value)
                case .connectorLabel:
                    board.commitConnectorLabel(connectorId: request.elementId ?? "", text: value)
                }
                save(showStatus: false)
            }
        }
        .sheet(isPresented: $searchPresented) {
            NavigationStack {
                WhiteboardSearchView(board: board, repository: start.repository, whiteboards: start.whiteboards) { choice in
                    switch choice {
                    case .node(let node):
                        board.addNoteNode(node)
                        save(showStatus: false)
                    case .canvasText(let drawing, let elementId, let index):
                        if drawing.id == self.drawing.id {
                            board.focusElement(elementId: elementId, fallbackIndex: index)
                        } else {
                            open(drawing: drawing, focusElementId: elementId, focusElementIndex: index)
                        }
                    }
                    searchPresented = false
                }
            }
        }
        .alert("删除白板", isPresented: $deleteConfirm) {
            Button("删除", role: .destructive) {
                deleteDrawing()
            }
            Button("取消", role: .cancel) {
            }
        } message: {
            Text("删除当前白板及其 canvas 文件？")
        }
    }

    private var toolbar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                toolbarButton("返回", "chevron.left") {
                    save(showStatus: false)
                    dismiss()
                }
                toolbarButton("保存", "checkmark.circle") { save(showStatus: true) }
                toolbarButton("撤销", "arrow.uturn.backward") { board.undo() }
                toolbarButton("前进", "arrow.uturn.forward") { board.redo() }
                toolbarButton("搜索", "magnifyingglass") { searchPresented = true }
                toolbarButton("删板", "trash") { deleteConfirm = true }
            }
            HStack(spacing: 4) {
                toolButton("字", "textformat", mode: "text")
                toolButton("矩", "rectangle", mode: "rectangle")
                toolButton("圆", "circle", mode: "circle")
                toolButton("箭", "arrow.up.right", mode: "arrow")
                toolButton("线", "line.diagonal", mode: "line")
                toolbarButton("删素", "xmark.square") {
                    board.deleteSelection()
                    save(showStatus: false)
                }
                Menu {
                    Button("复制") { board.copySelection() }
                    Button("粘贴") { board.pasteAtCenter(); save(showStatus: false) }
                    Button("绑定") { board.groupSelection(); save(showStatus: false) }
                    Button("取消编组") { board.ungroupSelection(); save(showStatus: false) }
                    Divider()
                    ForEach(colorChoices) { color in
                        Button(color.label) {
                            board.changeSelectedTextColor(color.value)
                            save(showStatus: false)
                        }
                    }
                } label: {
                    Label("元素", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                toolbarButton(canvasOnly ? "还原" : "全屏", canvasOnly ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    canvasOnly.toggle()
                }
            }
        }
        .padding(6)
        .background(Color(UIColor.secondarySystemBackground))
    }

    private var bottomPanel: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    WhiteboardRelationStrip(title: "父节点", nodes: model.parents, previewedNodeId: model.selectedNode?.id, onTap: model.graphNodeTapped)
                    WhiteboardRelationStrip(title: "兄弟", nodes: model.siblings, previewedNodeId: model.selectedNode?.id, onTap: model.graphNodeTapped)
                    WhiteboardRelationStrip(title: "当前", nodes: model.graphNode.map { [$0] } ?? [], previewedNodeId: model.selectedNode?.id) { node in
                        model.selectNode(node, updateGraph: false)
                    }
                    WhiteboardRelationStrip(title: "子节点", nodes: model.children, previewedNodeId: model.selectedNode?.id, onTap: model.graphNodeTapped)
                    WhiteboardRelationStrip(title: "相关", nodes: model.related, previewedNodeId: model.selectedNode?.id, onTap: model.graphNodeTapped)
                }
                .padding(8)
            }
            .frame(maxWidth: 210)
            Divider()
            VStack(spacing: 6) {
                Text(model.selectedNode?.topic ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Button("B") { wrapNote("**", "**") }
                        .font(.body.weight(.bold))
                    Button("高亮") { wrapNote("==", "==") }
                    Button("保存") { model.saveCurrentNote() }
                        .disabled(!model.noteDirty)
                    Picker("模式", selection: $notePreview) {
                        Text("编辑").tag(false)
                        Text("预览").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 150)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if notePreview {
                    ScrollView {
                        Text(tryAttributedMarkdown(model.noteText))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .background(Color(UIColor.systemBackground))
                } else {
                    TextEditor(text: $model.noteText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .background(Color(UIColor.systemBackground))
                }
            }
            .padding(8)
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    private func toolbarButton(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func toolButton(_ title: String, _ systemImage: String, mode: String) -> some View {
        Button {
            board.mode = mode
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.caption)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(board.mode == mode ? .accentColor : .gray)
    }

    private func save(showStatus: Bool) {
        do {
            board.normalizeElementsBeforeSave()
            try start.whiteboards.saveCanvas(drawing, canvas: board.document)
            lastSavedModifiedTime = start.whiteboards.canvasModifiedTime(drawing)
            if showStatus {
                board.status = "已保存"
            }
        } catch {
            board.status = error.localizedDescription
        }
    }

    private func open(drawing: WhiteboardDrawing, focusElementId: String, focusElementIndex: Int) {
        save(showStatus: false)
        do {
            self.drawing = drawing
            board.document = try start.whiteboards.readCanvas(drawing)
            board.selectedIds.removeAll()
            board.fitToContent()
            board.focusElement(elementId: focusElementId, fallbackIndex: focusElementIndex)
        } catch {
            board.status = error.localizedDescription
        }
    }

    private func deleteDrawing() {
        do {
            try start.whiteboards.deleteDrawing(drawing)
            dismiss()
        } catch {
            board.status = error.localizedDescription
        }
    }

    private func wrapNote(_ before: String, _ after: String) {
        model.noteText = before + model.noteText + after
    }

    private func tryAttributedMarkdown(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(markdown: text) {
            return attributed
        }
        return AttributedString(text)
    }

    private var colorChoices: [WhiteboardColorChoice] {
        [
            WhiteboardColorChoice(label: "黑色", value: "#000000"),
            WhiteboardColorChoice(label: "红色", value: "#DC2626"),
            WhiteboardColorChoice(label: "蓝色", value: "#2563EB"),
            WhiteboardColorChoice(label: "绿色", value: "#16A34A"),
            WhiteboardColorChoice(label: "橙色", value: "#F97316"),
            WhiteboardColorChoice(label: "紫色", value: "#7C3AED")
        ]
    }
}

private struct WhiteboardColorChoice: Identifiable {
    var label: String
    var value: String
    var id: String { value }
}

private struct WhiteboardCanvasView: UIViewRepresentable {
    @ObservedObject var board: WhiteboardDocument
    var onEditText: (WhiteboardEditRequest) -> Void
    var onSelectNode: (String) -> Void

    func makeUIView(context: Context) -> WhiteboardCanvasUIView {
        let view = WhiteboardCanvasUIView()
        view.board = board
        view.onEditText = onEditText
        view.onSelectNode = onSelectNode
        return view
    }

    func updateUIView(_ uiView: WhiteboardCanvasUIView, context: Context) {
        uiView.board = board
        uiView.onEditText = onEditText
        uiView.onSelectNode = onSelectNode
        uiView.setNeedsDisplay()
    }
}

private final class WhiteboardCanvasUIView: UIView {
    weak var board: WhiteboardDocument?
    var onEditText: ((WhiteboardEditRequest) -> Void)?
    var onSelectNode: ((String) -> Void)?

    private var downWorld = CGPoint.zero
    private var lastScreen = CGPoint.zero
    private var activeId = ""
    private var drawingId = ""
    private var dragging = false
    private var resizing = false
    private var endpointDrag = false
    private var endpointIndex = 0
    private var marquee = false
    private var marqueeRect = CGRect.zero
    private var lastTap = Date.distantPast
    private var lastTapPoint = CGPoint.zero
    private var pinchStartScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        isMultipleTouchEnabled = true
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        long.minimumPressDuration = 0.85
        addGestureRecognizer(long)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let board, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.translateBy(x: board.pan.x, y: board.pan.y)
        context.scaleBy(x: board.scale, y: board.scale)
        drawGrid(context: context, board: board)
        for element in board.elements() {
            drawElement(element, context: context, board: board)
        }
        drawSelection(context: context, board: board)
        if marquee {
            UIColor.systemBlue.withAlphaComponent(0.12).setFill()
            UIColor.systemBlue.setStroke()
            context.fill(marqueeRect)
            context.stroke(marqueeRect)
        }
        context.restoreGState()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let board else { return }
        let screen = touch.location(in: self)
        let world = board.screenToWorld(screen)
        downWorld = world
        lastScreen = screen
        activeId = ""
        drawingId = ""
        dragging = false
        resizing = false
        endpointDrag = false
        marquee = false

        let now = Date()
        let doubleTap = now.timeIntervalSince(lastTap) < 0.36 && hypot(screen.x - lastTapPoint.x, screen.y - lastTapPoint.y) < 24
        lastTap = now
        lastTapPoint = screen

        if doubleTap {
            if let hit = board.hit(world) {
                startInlineEdit(id: hit, point: world)
            } else {
                onEditText?(WhiteboardEditRequest(kind: .text, elementId: nil, worldPoint: world, text: ""))
            }
            return
        }

        if board.mode == "text" {
            onEditText?(WhiteboardEditRequest(kind: .text, elementId: nil, worldPoint: world, text: ""))
            board.mode = "select"
            return
        }

        if ["rectangle", "circle", "arrow", "line"].contains(board.mode) {
            board.pushUndo()
            var element: [String: Any]
            if board.mode == "arrow" || board.mode == "line" {
                element = board.connectorElement(type: board.mode, x1: world.x, y1: world.y, x2: world.x + 1, y2: world.y + 1)
            } else {
                element = board.shapeElement(type: board.mode, x: world.x, y: world.y, width: 1, height: 1)
            }
            drawingId = wbString(element["elementId"])
            board.appendElement(element)
            board.selectedIds = [drawingId]
            setNeedsDisplay()
            return
        }

        if let hit = board.hit(world) {
            activeId = hit
            if !board.selectedIds.contains(hit) {
                board.selectElementWithGroup(id: hit)
            }
            board.pushUndo()
            if let element = board.element(id: hit), board.isConnector(element) {
                let start = board.connectorPoint(element, index: 0)
                let end = board.connectorPoint(element, index: 1)
                if hypot(world.x - start.x, world.y - start.y) <= 14 {
                    endpointDrag = true
                    endpointIndex = 0
                } else if hypot(world.x - end.x, world.y - end.y) <= 14 {
                    endpointDrag = true
                    endpointIndex = 1
                } else {
                    dragging = true
                }
            } else if let element = board.element(id: hit) {
                let rect = board.bounds(element)
                let handle = CGRect(x: rect.maxX - 18, y: rect.maxY - 18, width: 24, height: 24)
                resizing = handle.contains(world)
                if !resizing {
                    dragging = true
                }
            }
            if let nodeId = board.element(id: hit).map({ wbString($0["nodeId"]) }), !nodeId.isEmpty {
                onSelectNode?(nodeId)
            }
            setNeedsDisplay()
        } else {
            board.selectedIds.removeAll()
            marquee = true
            marqueeRect = CGRect(origin: world, size: .zero)
            setNeedsDisplay()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let board else { return }
        let screen = touch.location(in: self)
        let world = board.screenToWorld(screen)
        if !drawingId.isEmpty {
            board.updateElement(id: drawingId) { element in
                if board.isConnector(element) {
                    board.setPoint(&element, index: 1, point: world)
                    board.snapConnectorEndpoint(&element, endpoint: 1)
                    board.updateConnectorBounds(&element)
                } else {
                    element["x"] = min(downWorld.x, world.x)
                    element["y"] = min(downWorld.y, world.y)
                    element["width"] = max(8, abs(world.x - downWorld.x))
                    element["height"] = max(8, abs(world.y - downWorld.y))
                }
            }
        } else if endpointDrag, !activeId.isEmpty {
            board.updateElement(id: activeId) { element in
                board.setPoint(&element, index: endpointIndex, point: world)
                board.snapConnectorEndpoint(&element, endpoint: endpointIndex)
                board.updateConnectorBounds(&element)
            }
            board.updateBoundConnectors()
        } else if resizing, !activeId.isEmpty {
            board.resizeElement(id: activeId, to: world)
        } else if dragging {
            let dx = (screen.x - lastScreen.x) / board.scale
            let dy = (screen.y - lastScreen.y) / board.scale
            board.moveSelection(dx: dx, dy: dy)
        } else if marquee {
            marqueeRect = CGRect(x: min(downWorld.x, world.x), y: min(downWorld.y, world.y), width: abs(world.x - downWorld.x), height: abs(world.y - downWorld.y))
            board.selectedIds = Set(board.elements().filter { marqueeRect.intersects(board.bounds($0)) }.map { wbString($0["elementId"]) })
        } else if board.mode == "select" {
            board.pan.x += screen.x - lastScreen.x
            board.pan.y += screen.y - lastScreen.y
        }
        lastScreen = screen
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let board else { return }
        if !drawingId.isEmpty {
            if let element = board.element(id: drawingId), !board.isConnector(element), board.bounds(element).width < 10, board.bounds(element).height < 10 {
                board.removeElement(id: drawingId)
            }
            drawingId = ""
            board.mode = "select"
        }
        dragging = false
        resizing = false
        endpointDrag = false
        marquee = false
        activeId = ""
        setNeedsDisplay()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let board else { return }
        if gesture.state == .began {
            pinchStartScale = board.scale
        }
        let location = gesture.location(in: self)
        let before = board.screenToWorld(location)
        board.scale = min(3, max(0.25, pinchStartScale * gesture.scale))
        let after = board.worldToScreen(before)
        board.pan.x += location.x - after.x
        board.pan.y += location.y - after.y
        setNeedsDisplay()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let board else { return }
        let world = board.screenToWorld(gesture.location(in: self))
        guard let hit = board.hit(world) else { return }
        board.selectElementWithGroup(id: hit)
        becomeFirstResponder()
        let menu = UIMenuController.shared
        menu.menuItems = [
            UIMenuItem(title: "复制", action: #selector(copyElement)),
            UIMenuItem(title: "粘贴", action: #selector(pasteElement)),
            UIMenuItem(title: "绑定", action: #selector(groupElement)),
            UIMenuItem(title: "取消编组", action: #selector(ungroupElement))
        ]
        menu.showMenu(from: self, rect: CGRect(origin: gesture.location(in: self), size: CGSize(width: 1, height: 1)))
        setNeedsDisplay()
    }

    override var canBecomeFirstResponder: Bool { true }

    @objc private func copyElement() { board?.copySelection() }
    @objc private func pasteElement() { board?.pasteAtCenter(); setNeedsDisplay() }
    @objc private func groupElement() { board?.groupSelection(); setNeedsDisplay() }
    @objc private func ungroupElement() { board?.ungroupSelection(); setNeedsDisplay() }

    private func startInlineEdit(id: String, point: CGPoint) {
        guard let board, let element = board.element(id: id) else { return }
        let type = wbString(element["type"])
        if type == "text" {
            onEditText?(WhiteboardEditRequest(kind: .text, elementId: id, worldPoint: board.bounds(element).origin, text: board.rawTextForLayout(element)))
        } else if board.isConnector(element) {
            onEditText?(WhiteboardEditRequest(kind: .connectorLabel, elementId: id, worldPoint: point, text: board.connectorLabelText(connectorId: id)))
        } else if type == "rectangle" || type == "circle" || type == "ellipse" {
            if let textId = board.ensureCenteredTextForShape(id: id), let text = board.element(id: textId) {
                onEditText?(WhiteboardEditRequest(kind: .text, elementId: textId, worldPoint: board.bounds(text).origin, text: board.rawTextForLayout(text)))
            }
        }
    }

    private func drawGrid(context: CGContext, board: WhiteboardDocument) {
        guard let state = board.document["state"] as? [String: Any],
              (state["showGrid"] as? Bool) == true else { return }
        let config = wbDict(state["gridConfig"])
        let size = max(5, wbCGFloat(config["size"], defaultValue: 20))
        UIColor(hex: wbString(config["strokeStyle"], defaultValue: "#dfe0e1")).setStroke()
        context.setLineWidth(max(0.5, wbCGFloat(config["lineWidth"], defaultValue: 1)))
        for x in stride(from: CGFloat(-4000), through: CGFloat(4000), by: size) {
            context.move(to: CGPoint(x: x, y: -4000))
            context.addLine(to: CGPoint(x: x, y: 4000))
        }
        for y in stride(from: CGFloat(-4000), through: CGFloat(4000), by: size) {
            context.move(to: CGPoint(x: -4000, y: y))
            context.addLine(to: CGPoint(x: 4000, y: y))
        }
        context.strokePath()
    }

    private func drawElement(_ element: [String: Any], context: CGContext, board: WhiteboardDocument) {
        let type = wbString(element["type"])
        if type == "rectangle" {
            drawRectangle(element, context: context, board: board)
        } else if type == "circle" || type == "ellipse" {
            drawCircle(element, context: context, board: board)
        } else if type == "arrow" || type == "line" {
            drawConnector(element, context: context, board: board, arrow: type == "arrow")
        } else if type == "text" {
            drawText(element, context: context, board: board)
        }
    }

    private func drawRectangle(_ element: [String: Any], context: CGContext, board: WhiteboardDocument) {
        let style = wbDict(element["style"])
        let rect = board.bounds(element)
        context.setLineWidth(board.lineWidth(style))
        UIColor(hex: wbString(style["strokeStyle"], defaultValue: "#000000")).setStroke()
        let fill = wbString(style["fillStyle"], defaultValue: "transparent")
        if fill != "transparent" {
            UIColor(hex: fill).setFill()
            context.fill(rect)
        }
        context.stroke(rect)
    }

    private func drawCircle(_ element: [String: Any], context: CGContext, board: WhiteboardDocument) {
        let style = wbDict(element["style"])
        let rect = board.bounds(element)
        context.setLineWidth(board.lineWidth(style))
        UIColor(hex: wbString(style["strokeStyle"], defaultValue: "#000000")).setStroke()
        let fill = wbString(style["fillStyle"], defaultValue: "transparent")
        if fill != "transparent" {
            UIColor(hex: fill).setFill()
            context.fillEllipse(in: rect)
        }
        context.strokeEllipse(in: rect)
    }

    private func drawConnector(_ element: [String: Any], context: CGContext, board: WhiteboardDocument, arrow: Bool) {
        let style = wbDict(element["style"])
        let a = board.connectorPoint(element, index: 0)
        let b = board.connectorPoint(element, index: 1)
        context.setLineWidth(board.lineWidth(style))
        UIColor(hex: wbString(style["strokeStyle"], defaultValue: "#000000")).setStroke()
        context.move(to: a)
        context.addLine(to: b)
        context.strokePath()
        if arrow {
            drawArrowHead(context: context, from: a, to: b)
        }
    }

    private func drawArrowHead(context: CGContext, from: CGPoint, to: CGPoint) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let len: CGFloat = 12
        let p1 = CGPoint(x: to.x - cos(angle - .pi / 7) * len, y: to.y - sin(angle - .pi / 7) * len)
        let p2 = CGPoint(x: to.x - cos(angle + .pi / 7) * len, y: to.y - sin(angle + .pi / 7) * len)
        context.move(to: to)
        context.addLine(to: p1)
        context.move(to: to)
        context.addLine(to: p2)
        context.strokePath()
    }

    private func drawText(_ element: [String: Any], context: CGContext, board: WhiteboardDocument) {
        let style = wbDict(element["style"])
        let rect = board.bounds(element)
        let text = wbString(element["text"])
        let fontSize = board.textFontSize(element)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = wbString(style["textAlign"]) == "center" ? .center : .left
        let color = UIColor(hex: wbString(style["fillStyle"], defaultValue: "#000000"))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        context.saveGState()
        let angle = wbCGFloat(element["rotate"]) * .pi / 180
        if angle != 0 {
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: angle)
            (text as NSString).draw(with: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height), options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        } else {
            (text as NSString).draw(with: rect.insetBy(dx: 4, dy: 4), options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        }
        context.restoreGState()
    }

    private func drawSelection(context: CGContext, board: WhiteboardDocument) {
        UIColor.systemBlue.setStroke()
        context.setLineWidth(1 / max(0.35, board.scale))
        for element in board.elements() where board.selectedIds.contains(wbString(element["elementId"])) {
            let rect = board.isConnector(element)
                ? board.bounds(element).insetBy(dx: -8, dy: -8)
                : board.bounds(element)
            context.stroke(rect)
            let handle = CGRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 14, height: 14)
            UIColor.systemBlue.setFill()
            context.fill(handle)
        }
    }
}

private struct WhiteboardTextEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: WhiteboardEditRequest
    var onCommit: (String) -> Void
    @State private var text: String

    init(request: WhiteboardEditRequest, onCommit: @escaping (String) -> Void) {
        self.request = request
        self.onCommit = onCommit
        _text = State(initialValue: request.text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle(request.kind == .connectorLabel ? "连线文字" : "文字")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确定") {
                            onCommit(text)
                            dismiss()
                        }
                    }
                }
        }
    }
}

private struct WhiteboardSearchView: View {
    let board: WhiteboardDocument
    let repository: CBrainRepository
    let whiteboards: WhiteboardRepository
    var onSelect: (WhiteboardSearchChoice) -> Void
    @State private var query = ""

    var body: some View {
        List {
            Section("笔记") {
                ForEach(noteMatches) { node in
                    Button {
                        onSelect(.node(node))
                    } label: {
                        Text(node.topic)
                            .lineLimit(1)
                    }
                }
            }
            Section("白板文字") {
                ForEach(canvasMatches, id: \.id) { item in
                    Button {
                        onSelect(.canvasText(item.drawing, item.elementId, item.index))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .lineLimit(1)
                            Text(item.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "搜索标题或白板文字")
        .navigationTitle("搜索")
    }

    private var noteMatches: [CBrainNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return repository.activeNodes().filter { $0.topic.localizedCaseInsensitiveContains(q) }.prefix(80).map { $0 }
    }

    private var canvasMatches: [CanvasTextMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var output: [CanvasTextMatch] = []
        for drawing in whiteboards.allDrawings() {
            guard let canvas = try? whiteboards.readCanvas(drawing),
                  let elements = canvas["elements"] as? [[String: Any]] else { continue }
            for (index, element) in elements.enumerated() where wbString(element["type"]) == "text" {
                let text = wbString(element["text"])
                let raw = wbString(element[textRawField])
                guard text.lowercased().contains(q) || raw.lowercased().contains(q) else { continue }
                output.append(CanvasTextMatch(id: "\(drawing.id)-\(index)", drawing: drawing, elementId: wbString(element["elementId"]), index: index, title: drawing.topic, preview: text.isEmpty ? raw : text))
                if output.count >= 80 { return output }
            }
        }
        return output
    }
}

private struct WhiteboardRelationStrip: View {
    var title: String
    var nodes: [CBrainNode]
    var previewedNodeId: String?
    var onTap: (CBrainNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if nodes.isEmpty {
                        Text("-")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(nodes) { node in
                            Button {
                                onTap(node)
                            } label: {
                                Text(node.topic)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .overlay {
                                if node.id == previewedNodeId {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct WhiteboardEditRequest: Identifiable {
    enum Kind {
        case text
        case connectorLabel
    }

    var id = UUID()
    var kind: Kind
    var elementId: String?
    var worldPoint: CGPoint
    var text: String
}

private enum WhiteboardSearchChoice {
    case node(CBrainNode)
    case canvasText(WhiteboardDrawing, String, Int)
}

private struct CanvasTextMatch {
    var id: String
    var drawing: WhiteboardDrawing
    var elementId: String
    var index: Int
    var title: String
    var preview: String
}

private extension UIColor {
    convenience init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
