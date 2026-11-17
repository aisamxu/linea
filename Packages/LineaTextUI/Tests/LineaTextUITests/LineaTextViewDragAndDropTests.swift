import AppKit
import Foundation
import LineaCore
import Testing
@testable import LineaTextUI

/// Phase 4：拖放与右键菜单（C5）契约。
@Suite("LineaTextViewDragAndDrop", .serialized)
@MainActor
struct LineaTextViewDragAndDropTests {
    private func makeView(
        _ text: String,
        selections: [TextSelection] = [.caret(at: 0)]
    ) -> LineaTextView {
        let view = LineaTextView(
            engine: EditorEngine(text: text, selections: selections)
        )
        view.setViewportWidth(900)
        view.updateDocumentFrame()
        return view
    }

    /// 光标矩形的中心点，保证命中测试落回该偏移。
    private func point(for offset: Int, in view: LineaTextView) -> CGPoint {
        let rect = view.layoutEngine.caretRect(for: offset)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func makeDraggingInfo(
        _ text: String,
        at location: CGPoint,
        types: [NSPasteboard.PasteboardType] = [.string]
    ) -> DraggingInfoStub {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("linea-test-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        if types.contains(.string) {
            pasteboard.setString(text, forType: .string)
        }
        if types.contains(.fileURL) {
            pasteboard.setString(
                "file:///tmp/linea-drop.txt",
                forType: .fileURL
            )
        }
        return DraggingInfoStub(pasteboard: pasteboard, location: location)
    }

    // MARK: - 拖入

    // 注意：视图未挂窗口时 `convert(_:from: nil)` 会做一次 y 翻转，
    // 多行落点由 `insertDroppedText` 直接覆盖，拖入路径用单行文本验证。
    @Test func externalDropInsertsAtPointInOneUndoStep() {
        let view = makeView("abcdef")
        let info = makeDraggingInfo("X", at: point(for: 2, in: view))

        #expect(view.draggingEntered(info) == .copy)
        #expect(view.dropInsertionOffset == 2)
        #expect(view.performDragOperation(info))

        #expect(view.engine.text == "abXcdef")
        #expect(view.engine.selections == [.caret(at: 3)])
        #expect(view.engine.history.undoCount == 1)
        #expect(view.dropInsertionOffset == nil)

        #expect(view.engine.undo())
        #expect(view.engine.text == "abcdef")
    }

    @Test func draggingExitedClearsIndicator() {
        let view = makeView("abc")
        let info = makeDraggingInfo("X", at: point(for: 1, in: view))

        _ = view.draggingEntered(info)
        #expect(view.dropInsertionOffset == 1)

        view.draggingExited(info)
        #expect(view.dropInsertionOffset == nil)
    }

    @Test func fileURLDropIsRejected() {
        let view = makeView("abc")
        let info = makeDraggingInfo(
            "",
            at: point(for: 1, in: view),
            types: [.fileURL]
        )

        #expect(view.draggingEntered(info) == [])
        #expect(!view.prepareForDragOperation(info))
        #expect(!view.performDragOperation(info))
        #expect(view.engine.text == "abc")
    }

    @Test func dropIsRejectedWhenNotEditable() {
        let view = makeView("abc")
        view.isEditable = false
        let info = makeDraggingInfo("X", at: point(for: 1, in: view))

        #expect(view.draggingEntered(info) == [])
        #expect(!view.performDragOperation(info))
        #expect(view.engine.text == "abc")
    }

    // MARK: - 内部移动

    @Test func internalMoveDeletesSourceAndInsertsAtDrop() {
        let view = makeView("abcdef")

        // 把 "cd"（2..<4）拖到文档末尾。
        #expect(view.insertDroppedText(
            "cd",
            at: 6,
            moving: NSRange(location: 2, length: 2)
        ))

        #expect(view.engine.text == "abefcd")
        #expect(view.engine.selections == [.caret(at: 6)])
        #expect(view.engine.history.undoCount == 1)

        #expect(view.engine.undo())
        #expect(view.engine.text == "abcdef")
    }

    @Test func internalMoveBackwardsAdjustsCaret() {
        let view = makeView("abcdef")

        // 把 "ef"（4..<6）拖到位置 1。
        #expect(view.insertDroppedText(
            "ef",
            at: 1,
            moving: NSRange(location: 4, length: 2)
        ))

        #expect(view.engine.text == "aefbcd")
        #expect(view.engine.selections == [.caret(at: 3)])
        #expect(view.engine.history.undoCount == 1)
    }

    @Test func internalMoveOntoItselfIsNoOp() {
        let view = makeView("abcdef")

        // 落点在源选区内或紧邻边界时不产生编辑与历史。
        #expect(view.insertDroppedText(
            "cd",
            at: 3,
            moving: NSRange(location: 2, length: 2)
        ))
        #expect(view.insertDroppedText(
            "cd",
            at: 4,
            moving: NSRange(location: 2, length: 2)
        ))

        #expect(view.engine.text == "abcdef")
        #expect(view.engine.history.canUndo == false)
    }

    // MARK: - 右键菜单

    @Test func rightClickOnEmptyAreaSelectsWord() {
        let view = makeView("alpha beta")
        let event = makeRightClickEvent(at: point(for: 8, in: view))

        let menu = view.menu(for: event)
        #expect(menu != nil)
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 6, length: 4))
        ])
    }

    @Test func rightClickKeepsExistingSelection() {
        let view = makeView(
            "alpha beta",
            selections: [TextSelection(range: NSRange(location: 0, length: 5))]
        )
        let event = makeRightClickEvent(at: point(for: 8, in: view))

        _ = view.menu(for: event)

        // 已有非空选区时，右键不改变选择。
        #expect(view.engine.selections == [
            TextSelection(range: NSRange(location: 0, length: 5))
        ])
    }

    private func makeRightClickEvent(at location: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}

/// 最小 `NSDraggingInfo` stub：只提供 pasteboard 与拖拽位置。
private final class DraggingInfoStub: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint

    var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0

    init(pasteboard: NSPasteboard, location: NSPoint) {
        self.draggingPasteboard = pasteboard
        self.draggingLocation = location
        super.init()
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (
            NSDraggingItem,
            Int,
            UnsafeMutablePointer<ObjCBool>
        ) -> Void
    ) {
        // 测试不依赖逐项枚举。
    }
}
