import Foundation
import LineaCore

/// 编辑视图抽象。
///
/// 控制器只依赖这组接口驱动视图，不直接触碰布局缓存或 `NSView` 细节；
/// 将来替换渲染实现时不需要改会话/查找/保存逻辑。
@MainActor
public protocol TextSurface: AnyObject {
    /// 当前选区，最后一个为主选区。视图必须与引擎保持一致。
    var selections: [TextSelection] { get }
    /// 所有非空选区的文本，按文档顺序用换行连接。
    var selectedText: String { get }
    var isEditable: Bool { get set }

    /// 引擎完成一次编辑后的视图同步入口。
    func apply(change: EditorChange)
    func setSelections(_ selections: [TextSelection])
    func scrollRangeToVisible(_ range: NSRange)
}
