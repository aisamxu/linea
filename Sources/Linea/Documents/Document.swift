import Combine
import Foundation

/// 一个标签页对应的文档元数据。
///
/// 文本内容本身由 EditorViewController 中的 EditorEngine 持有；这里只保存路径、
/// 显示名称、脏状态和“上次保存/载入时的磁盘签名”。
final class Document: ObservableObject, Identifiable {
    let id: UUID

    @Published private(set) var fileURL: URL?
    @Published private(set) var displayName: String
    @Published var isDirty: Bool
    @Published private(set) var savedSignature: FileSignature?

    /// 会话退出时是否需要额外写一份文本草稿。
    /// 未命名文档即使没有改动也必须保留文本；已命名的文件只有脏的情况下才需要草稿。
    var needsDraft: Bool {
        isDirty || fileURL == nil
    }

    init(
        id: UUID = UUID(),
        fileURL: URL?,
        displayName: String,
        isDirty: Bool,
        savedSignature: FileSignature?
    ) {
        self.id = id
        self.fileURL = fileURL?.standardizedFileURL
        self.displayName = displayName
        self.isDirty = isDirty
        self.savedSignature = savedSignature
    }

    /// 保存成功（含另存为）后更新文档身份和基准签名。
    func markSaved(to url: URL, signature: FileSignature?) {
        let standardizedURL = url.standardizedFileURL
        fileURL = standardizedURL
        displayName = standardizedURL.lastPathComponent
        savedSignature = signature
        isDirty = false
    }

    /// 从磁盘重新载入后更新基准签名；调用方负责替换编辑器中的文本。
    func markReloaded(from url: URL, signature: FileSignature?) {
        let standardizedURL = url.standardizedFileURL
        fileURL = standardizedURL
        displayName = standardizedURL.lastPathComponent
        savedSignature = signature
        isDirty = false
    }
}
