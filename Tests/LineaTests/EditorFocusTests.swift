import AppKit
import XCTest
@testable import Linea

/// 窗口显示后的焦点回归测试。
///
/// SwiftUI 标签栏（`NSHostingView`）会在窗口首次显示时把内部的 `KeyViewProxy`
/// 设为第一响应者；编辑器必须在窗口排序后同步夺回焦点，否则没有光标、
/// 键盘事件也不会进入编辑器。
@MainActor
final class EditorFocusTests: XCTestCase {
    func testOrderingWindowFocusesEditorSynchronously() throws {
        _ = NSApplication.shared

        let controller = EditorWindowController(tabs: [], selectedTabID: nil, frame: nil)
        defer { controller.window?.close() }

        controller.window?.makeKeyAndOrderFront(nil)
        // 与 WindowManager.makeWindow 一致：窗口排序后同步聚焦。
        controller.focusEditor()

        let window = try XCTUnwrap(controller.window)
        let editor = try XCTUnwrap(controller.areaController.currentEditor)
        XCTAssertTrue(
            window.firstResponder === editor.textView,
            "窗口显示后第一响应者应为文本视图，实际是 \(String(describing: window.firstResponder))"
        )

        // 模拟一次真实键入，确认键盘事件能落到编辑器并写入引擎。
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )
        editor.textView.keyDown(with: event)
        XCTAssertEqual(editor.currentText, "a")
    }
}
