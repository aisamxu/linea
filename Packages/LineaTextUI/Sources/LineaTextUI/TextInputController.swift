import Foundation
import LineaCore

/// 键盘移动的文本单位。
///
/// 只描述“往哪走”，不包含垂直/翻页这类需要布局几何的移动；
/// 后者由 `LineaTextView` 借助 `TextLayoutEngine` 处理。
public enum TextMovement: Equatable, Sendable {
    case characterBackward
    case characterForward
    case wordBackward
    case wordForward
    case lineStart
    case lineEnd
    case documentStart
    case documentEnd

    /// 是否朝文档开头方向移动。扩展选区时决定哪一端是锚点。
    public var isBackward: Bool {
        switch self {
        case .characterBackward, .wordBackward, .lineStart, .documentStart:
            return true
        case .characterForward, .wordForward, .lineEnd, .documentEnd:
            return false
        }
    }
}

/// 与 UI 无关的选区移动逻辑，便于直接单元测试。
///
/// 规则与 AppKit 文本编辑保持一致：
/// - 光标移动：按 grapheme/词/行/文档边界移动一步。
/// - 有选区且不扩展：折叠到移动方向对应的一端，不额外移动。
/// - 按住 Shift：保留另一端作为锚点，把活动端移动到新边界。
public enum TextInputController {
    /// 对所有选区应用同一个移动命令，保持选区数量与主选区顺序。
    ///
    /// `anchors` 是 Shift 扩展时的固定锚点，由视图在连续 Shift 移动中保存。
    /// 没有锚点信息时按当前选区的方向推断，方向反转时可能多选一个字符。
    public static func moveSelections(
        _ selections: [TextSelection],
        movement: TextMovement,
        extendSelection: Bool,
        engine: EditorEngine,
        anchors: [Int]? = nil
    ) -> [TextSelection] {
        let source = selections.isEmpty ? [TextSelection.caret(at: 0)] : selections
        return source.enumerated().map { index, selection in
            moveSelection(
                selection,
                movement: movement,
                extendSelection: extendSelection,
                engine: engine,
                anchor: anchors.flatMap {
                    index < $0.count ? $0[index] : nil
                }
            )
        }
    }

    public static func moveSelection(
        _ selection: TextSelection,
        movement: TextMovement,
        extendSelection: Bool,
        engine: EditorEngine,
        anchor explicitAnchor: Int? = nil
    ) -> TextSelection {
        if extendSelection {
            // 有锚点时，活动端是选区的另一端：锚点在左则向右/左移动末尾，
            // 锚点在右则移动开头。这样 Shift+方向键反复换向也不会漂移。
            let anchor = explicitAnchor ?? inferredAnchor(
                for: selection,
                movement: movement
            )
            let active: Int
            if selection.isCaret {
                active = selection.range.location
            } else if anchor <= selection.range.location {
                active = selection.insertionOffset
            } else {
                active = selection.range.location
            }
            let target = boundary(
                from: active,
                movement: movement,
                engine: engine
            )
            return TextSelection(
                range: TextInputController.union(anchor, target),
                affinity: selection.affinity
            )
        }

        // 有选区时只折叠，不再多移动一步。
        if !selection.isCaret {
            switch movement {
            case .characterBackward, .wordBackward:
                return TextSelection.caret(
                    at: selection.range.location,
                    affinity: selection.affinity
                )
            case .characterForward, .wordForward:
                return TextSelection.caret(
                    at: selection.insertionOffset,
                    affinity: selection.affinity
                )
            case .lineStart:
                return TextSelection.caret(
                    at: engine.lineStart(at: selection.range.location),
                    affinity: selection.affinity
                )
            case .lineEnd:
                return TextSelection.caret(
                    at: engine.contentEnd(at: selection.insertionOffset),
                    affinity: selection.affinity
                )
            case .documentStart:
                return TextSelection.caret(at: 0, affinity: selection.affinity)
            case .documentEnd:
                return TextSelection.caret(
                    at: engine.length,
                    affinity: selection.affinity
                )
            }
        }

        let target = boundary(
            from: selection.range.location,
            movement: movement,
            engine: engine
        )
        return TextSelection.caret(at: target, affinity: selection.affinity)
    }

    /// 计算从 offset 出发一步移动的边界。
    public static func boundary(
        from offset: Int,
        movement: TextMovement,
        engine: EditorEngine
    ) -> Int {
        switch movement {
        case .characterBackward:
            return engine.previousCharacterBoundary(before: offset)
        case .characterForward:
            return engine.nextCharacterBoundary(after: offset)
        case .wordBackward:
            return engine.previousWordBoundary(before: offset, mode: .word)
        case .wordForward:
            return engine.nextWordBoundary(after: offset, mode: .word)
        case .lineStart:
            return engine.lineStart(at: offset)
        case .lineEnd:
            return engine.contentEnd(at: offset)
        case .documentStart:
            return 0
        case .documentEnd:
            return engine.length
        }
    }

    /// 没有保存锚点时的推断：光标就是锚点；已有选区时后退移动锚在末尾、
    /// 前进移动锚在开头。
    public static func inferredAnchor(
        for selection: TextSelection,
        movement: TextMovement
    ) -> Int {
        if selection.isCaret {
            return selection.range.location
        }
        return movement.isBackward
            ? selection.insertionOffset
            : selection.range.location
    }

    private static func union(_ lhs: Int, _ rhs: Int) -> NSRange {
        let start = min(lhs, rhs)
        let end = max(lhs, rhs)
        return NSRange(location: start, length: end - start)
    }
}
