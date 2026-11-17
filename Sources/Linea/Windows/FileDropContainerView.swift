import AppKit
import LineaTextUI

/// 窗口内容容器：接收拖入的纯文本文件并交给窗口打开为新标签。
///
/// 编辑区由 `LineaTextView` 自己接收文件；本容器覆盖标签栏、查找栏和
/// 窗口空白区域，拖到这些位置同样能打开，而不必精确拖进正文。
final class FileDropContainerView: NSView {
    /// 打开拖入的文件；由窗口控制器注入。
    var onOpenFileURLs: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 只接收文件 URL；正文拖拽仍由 LineaTextView 处理。
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingUpdated(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func prepareForDragOperation(
        _ sender: NSDraggingInfo
    ) -> Bool {
        !droppedFileURLs(from: sender).isEmpty
    }

    override func performDragOperation(
        _ sender: NSDraggingInfo
    ) -> Bool {
        let urls = droppedFileURLs(from: sender)
        guard !urls.isEmpty, let onOpenFileURLs else { return false }
        onOpenFileURLs(urls)
        return true
    }

    private func dropOperation(
        for sender: NSDraggingInfo
    ) -> NSDragOperation {
        droppedFileURLs(from: sender).isEmpty ? [] : .copy
    }

    /// 未注入打开回调时视为不可接收，避免显示可放置却什么都不做。
    private func droppedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        guard onOpenFileURLs != nil else { return [] }
        return TextFileDrop.fileURLs(from: sender.draggingPasteboard)
    }
}
