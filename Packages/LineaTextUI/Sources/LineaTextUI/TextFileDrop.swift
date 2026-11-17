import AppKit
import UniformTypeIdentifiers

/// 拖入文件时共用的纯文本筛选。
///
/// 编辑区的 `LineaTextView` 与窗口层的拖放容器都通过这里判断，
/// 避免一处能拖、另一处不能拖，或把二进制文件交给严格 UTF-8 读取层。
public enum TextFileDrop {
    /// 从拖拽粘贴板读出可作为纯文本打开的常规文件。
    public static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard pasteboard.types?.contains(.fileURL) == true else { return [] }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) ?? []

        return objects
            .compactMap { ($0 as? NSURL) as URL? }
            .filter(isTextFile)
    }

    /// 按 UTI 判断是否为文本文件。
    ///
    /// 无扩展名或系统不认识的扩展名一律放行，由读取层按严格 UTF-8 决定；
    /// 已知的二进制类型（图片、压缩包、应用程序等）直接拒绝。
    public static func isTextFile(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath else { return false }

        let ext = url.pathExtension
        guard !ext.isEmpty else { return true }
        guard let type = UTType(filenameExtension: ext) else { return true }
        // 系统动态生成的未知类型无法判断内容，交给读取层按 UTF-8 决定。
        if type.identifier.hasPrefix("dyn.") { return true }
        return type.conforms(to: .text)
    }
}
