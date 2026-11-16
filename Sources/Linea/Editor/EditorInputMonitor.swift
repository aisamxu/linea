import AppKit
import STTextView

/// 每个标签页一个本地事件监视器，补充 STTextView 没有提供的 Sublime 风格手势：
/// - ⌘+点击添加/移除光标
/// - Esc 从多光标折叠回主选区
///
/// 不子类化 STTextView，避免影响它内部的滚动视图、gutter 和查找栏行为。
final class EditorInputMonitor {
    private weak var editor: EditorViewController?
    private var monitor: Any?

    init(editor: EditorViewController) {
        self.editor = editor
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let editor,
              let textView = editor.textViewIfViewLoaded,
              let window = textView.window,
              event.window === window
        else {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.type {
        case .keyDown:
            guard event.keyCode == 53, // Escape
                  !flags.contains(.command),
                  !flags.contains(.option),
                  !flags.contains(.control),
                  window.firstResponder === textView,
                  !textView.hasMarkedText()
            else {
                return event
            }

            return editor.collapseSelectionsIfNeeded() ? nil : event

        case .leftMouseDown:
            guard event.clickCount == 1,
                  flags.contains(.command),
                  !flags.contains(.shift),
                  !flags.contains(.option),
                  !flags.contains(.control),
                  window.firstResponder === textView
            else {
                return event
            }

            return editor.addCursor(atWindowPoint: event.locationInWindow) ? nil : event

        default:
            return event
        }
    }
}
