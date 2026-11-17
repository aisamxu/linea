import Foundation

/// 一次编辑的来源。用于撤销合并规则、统计和测试。
public enum EditOrigin: Equatable, Sendable {
    /// 普通键入（可参与连续输入合并）。
    case typing
    /// 删除/剪切选区。
    case deletion
    case paste
    case cut
    /// 输入法提交。一个 IME 提交算一个历史条目，不参与合并。
    case inputMethod
    /// 查找替换（含 Replace All）。
    case replaceAll
    /// 拖放：移动或插入文本，一个 drop 一个历史条目。
    case drag
    /// 程序化修改（重载、外部桥接等）。
    case programmatic
    case undo
    case redo
}

public enum DeleteDirection: Equatable, Sendable {
    case backward
    case forward
}

public enum TextGranularity: Equatable, Sendable {
    case character
    case word
    case line
}

/// 选区变化的来源，供视图区分是否需要滚动跟随、是否折叠多光标。
public enum SelectionSource: Equatable, Sendable {
    case mouse
    case keyboard
    case command
    case programmatic
    case multiCursor
}
