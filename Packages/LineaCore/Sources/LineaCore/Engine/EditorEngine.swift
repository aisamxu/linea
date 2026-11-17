import Foundation

/// 编辑引擎：文本、选区、版本的唯一事实源。
///
/// - 线程模型：所有方法和回调都在主线程调用，内部不加锁。
/// - 坐标：全部使用 UTF-16 `NSRange`；批量编辑使用同一 base 版本坐标。
/// - 一个用户动作对应一次事务、一个历史条目、一次 `onChange`。
public final class EditorEngine {
    private var buffer: PieceTreeBuffer
    private var navigation: DefaultTextNavigationProvider
    private var selectionModel: SelectionModel

    public private(set) var lineIndex: LineIndex
    public let history: EditHistory

    /// 全文缓存。未构建时保持 nil，热路径不会主动构造全文；
    /// 构建后随批量编辑增量维护，避免每次保存/查找重建。
    private var cachedText: NSMutableString?
    /// 全文缓存从 buffer 重建的次数，供测试确认编辑热路径没有重建全文。
    public private(set) var fullTextBuildCount = 0

    public private(set) var isDirty: Bool
    /// 编辑冻结期间为 false；选区移动仍然允许。
    public var isEditable = true
    public private(set) var composition: CompositionState?
    public var onChange: ((EditorChange) -> Void)?

    /// 可注入时钟，测试用它精确控制连续键入的合并窗口。
    private let now: () -> TimeInterval

    public init(
        text: String = "",
        selections: [TextSelection] = [.caret(at: 0)],
        markClean: Bool = true,
        history: EditHistory = EditHistory(),
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        let buffer = PieceTreeBuffer(text: text)
        self.buffer = buffer
        self.navigation = DefaultTextNavigationProvider(buffer: buffer)
        self.lineIndex = LineIndex(buffer: buffer)
        self.selectionModel = SelectionModel()
        self.history = history
        self.isDirty = !markClean
        self.now = now
        self.selectionModel.set(selections, textLength: buffer.length)
    }

    // MARK: - 只读状态

    /// 全文。首次访问时从 buffer 构建并缓存，之后按编辑增量维护。
    /// 视图渲染不得每帧调用，应使用 substring/lineRange。
    public var text: String {
        ensureTextCache()
        guard let cachedText else { return "" }
        return cachedText as String
    }

    public var length: Int { buffer.length }
    public var lineCount: Int { buffer.lineCount }
    public var version: UInt64 { buffer.version }
    public var pieceCount: Int { buffer.pieceCount }
    public var selections: [TextSelection] { selectionModel.selections }
    public var primarySelection: TextSelection { selectionModel.primary }
    public var isComposing: Bool { composition != nil }
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public func substring(in range: NSRange) -> String {
        buffer.substring(in: range)
    }

    public func lineRange(at line: Int) -> NSRange {
        lineIndex.lineRange(at: line)
    }

    public func lineContentRange(at line: Int) -> NSRange {
        lineIndex.lineContentRange(at: line)
    }

    public func lineNumber(at offset: Int) -> Int {
        lineIndex.lineNumber(at: offset)
    }

    public func lineStart(at offset: Int) -> Int {
        lineIndex.lineStart(at: offset)
    }

    public func contentEnd(at offset: Int) -> Int {
        lineIndex.contentEnd(at: offset)
    }

    public func nextLineStart(after offset: Int) -> Int? {
        lineIndex.nextLineStart(after: offset)
    }

    public func previousLineStart(before offset: Int) -> Int? {
        lineIndex.previousLineStart(before: offset)
    }

    // MARK: - 选区

    /// 写入选区集合；返回是否发生变化。只改变选区时不置脏、不发文本变更。
    @discardableResult
    public func setSelections(
        _ selections: [TextSelection],
        source _: SelectionSource = .programmatic
    ) -> Bool {
        selectionModel.set(selections, textLength: buffer.length)
    }

    // MARK: - 编辑命令

    /// 插入文本。组合期间提交组合，否则按普通键入替换所有选区。
    public func insertText(_ text: String) {
        if composition != nil {
            commitComposition(text)
            return
        }
        replaceSelections(with: text, origin: .typing)
    }

    /// 用文本替换所有选区（键入、粘贴、剪切后的插入）。
    public func replaceSelections(
        with text: String,
        origin: EditOrigin = .typing
    ) {
        guard isEditable, !text.isEmpty else { return }

        // 同一位置可能同时存在光标与以该位置开头的选区；
        // 零长编辑必须排在前面，buffer 降序应用时才不会错位。
        let edits = selectionModel.selections
            .map { TextEdit(range: $0.range, replacement: text) }
            .sorted {
                if $0.range.location != $1.range.location {
                    return $0.range.location < $1.range.location
                }
                return $0.range.length < $1.range.length
            }
        perform(edits: edits, origin: origin)
    }

    /// 删除所有非空选区；只有光标时不做任何事。
    public func deleteSelections(origin: EditOrigin = .deletion) {
        performDeletion(
            ranges: selectionModel.selections.map(\.range),
            origin: origin
        )
    }

    /// 按字符/词/行删除。非空选区始终整体删除，方向只影响光标。
    public func delete(_ direction: DeleteDirection, _ granularity: TextGranularity) {
        let ranges = selectionModel.selections.compactMap {
            deletionRange(for: $0, direction: direction, granularity: granularity)
        }
        performDeletion(ranges: ranges, origin: .deletion)
    }

    /// 替换单个范围，供 Finder/AX/外部桥接使用。
    @discardableResult
    public func replace(
        range: NSRange,
        with text: String,
        origin: EditOrigin = .programmatic
    ) -> EditorChange? {
        perform(
            edits: [TextEdit(range: range, replacement: text)],
            origin: origin
        )
    }

    /// 批量编辑。`edits` 必须升序、互不重叠，且使用当前 base 坐标。
    /// `selectionAfter` 为 nil 时按选区映射规则自动推导。
    @discardableResult
    public func apply(
        edits: [TextEdit],
        selectionAfter: [TextSelection]? = nil,
        origin: EditOrigin = .programmatic
    ) -> EditorChange? {
        perform(
            edits: edits,
            origin: origin,
            explicitSelectionAfter: selectionAfter
        )
    }

    // MARK: - 撤销 / 重做

    /// 撤销最近一个事务；没有历史或编辑被冻结时返回 false。
    @discardableResult
    public func undo() -> Bool {
        guard isEditable, let transaction = history.popUndo() else { return false }
        guard replay(transaction: transaction, forward: false) else {
            history.restoreAfterFailedUndo(transaction)
            return false
        }
        return true
    }

    /// 重做最近一个被撤销的事务。
    @discardableResult
    public func redo() -> Bool {
        guard isEditable, let transaction = history.popRedo() else { return false }
        guard replay(transaction: transaction, forward: true) else {
            history.restoreAfterFailedRedo(transaction)
            return false
        }
        return true
    }

    // MARK: - 文档生命周期

    /// 载入新文本：清空历史、缓存和组合状态，并按 `markClean` 设置脏标记。
    /// 从会话恢复脏草稿时传 `markClean: false`。
    public func load(
        text: String,
        selections: [TextSelection] = [.caret(at: 0)],
        markClean: Bool = true
    ) {
        buffer = PieceTreeBuffer(text: text)
        navigation = DefaultTextNavigationProvider(buffer: buffer)
        lineIndex = LineIndex(buffer: buffer)
        history.clear()
        selectionModel.set(selections, textLength: buffer.length)
        cachedText = nil
        fullTextBuildCount = 0
        composition = nil
        isDirty = !markClean
    }

    /// 保存成功后清除脏标记。undo/redo 不会自动回到 clean。
    public func markSaved() {
        isDirty = false
    }

    // MARK: - 输入法组合

    /// 更新 marked text。组合期间 buffer 不变，只记录待提交状态。
    /// 组合只以首次设置时的选区为基准，后续更新不会重新捕获光标。
    public func setMarkedText(
        _ markedText: String,
        selectedRange: NSRange,
        replacementRange: NSRange = NSRange(location: NSNotFound, length: 0)
    ) {
        guard isEditable else { return }

        var state = composition ?? CompositionState(
            baseSelections: selectionModel.selections,
            markedText: "",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: replacementRange
        )
        // 输入法可能每次更新都传新的替换范围；NSNotFound 表示沿用首次记录。
        if replacementRange.location != NSNotFound {
            state.replacementRange = replacementRange
        }
        state.markedText = markedText
        state.selectedRange = Self.clampedMarkedRange(selectedRange, in: markedText)
        composition = state
    }

    /// 取消组合：buffer 不变，不产生历史、不置脏。
    public func unmarkText() {
        composition = nil
    }

    /// 提交组合文本。输入法只替换主选区（或输入法显式给出的范围），
    /// 其他光标在选区映射阶段随编辑平移；整个提交是一个事务。
    public func commitComposition(_ text: String) {
        guard isEditable else { return }

        guard let state = composition else {
            insertAtPrimarySelection(text, origin: .inputMethod)
            return
        }

        guard !text.isEmpty else {
            composition = nil
            return
        }

        // 输入法显式给出的替换范围优先；否则使用组合开始时的主选区。
        let target: NSRange
        let replacementRange = state.replacementRange
        if replacementRange.location != NSNotFound,
           replacementRange.location >= 0,
           replacementRange.length >= 0,
           replacementRange.location <= buffer.length,
           replacementRange.length <= buffer.length - replacementRange.location
        {
            target = replacementRange
        } else {
            let base = SelectionModel.clamped(
                state.baseSelections.last ?? selectionModel.primary,
                to: buffer.length
            )
            target = base.range
        }

        if perform(
            edits: [TextEdit(range: target, replacement: text)],
            origin: .inputMethod
        ) != nil {
            composition = nil
        }
    }

    /// 保存、会话、AX 读取前调用：提交 marked text，再返回全文。
    public func prepareForSnapshot() -> String {
        commitPendingInput()
        return text
    }

    /// 显式提交待输入内容；没有组合或 marked text 为空时只清空状态。
    public func commitPendingInput() {
        guard let composition else { return }
        guard !composition.markedText.isEmpty else {
            self.composition = nil
            return
        }
        commitComposition(composition.markedText)
    }

    // MARK: - 核心事务

    @discardableResult
    private func perform(
        edits: [TextEdit],
        origin: EditOrigin,
        explicitSelectionAfter: [TextSelection]? = nil
    ) -> EditorChange? {
        guard isEditable else { return nil }

        let effective = edits.filter { !$0.isEmpty }
        guard !effective.isEmpty else { return nil }

        let selectionBefore = selectionModel.selections
        let versionBefore = buffer.version
        let lineCountBefore = buffer.lineCount

        // 批次非法时 buffer 原子回退并返回空数组：不写历史、不置脏、不发通知。
        let applied = buffer.apply(edits: effective)
        guard !applied.isEmpty else { return nil }

        updateTextCache(with: applied)

        let mappedSelection = explicitSelectionAfter
            ?? SelectionMapper.map(selectionBefore, through: applied)
        selectionModel.set(mappedSelection, textLength: buffer.length)

        let transaction = EditTransaction(
            edits: effective,
            inverseEdits: applied.map {
                TextEdit(range: $0.rangeInResult, replacement: $0.removedText)
            },
            selectionBefore: selectionBefore,
            selectionAfter: selectionModel.selections,
            origin: origin,
            timestamp: now()
        )
        history.record(transaction)
        isDirty = true

        let change = makeChange(
            versionBefore: versionBefore,
            lineCountBefore: lineCountBefore,
            edits: effective,
            applied: applied,
            selectionBefore: selectionBefore,
            origin: origin
        )
        onChange?(change)
        return change
    }

    /// 撤销/重做共用的重放逻辑。
    private func replay(
        transaction: EditTransaction,
        forward: Bool
    ) -> Bool {
        let selectionBefore = selectionModel.selections
        let versionBefore = buffer.version
        let lineCountBefore = buffer.lineCount
        let edits = forward ? transaction.edits : transaction.inverseEdits

        let applied = buffer.apply(edits: edits)
        guard !applied.isEmpty else { return false }

        updateTextCache(with: applied)

        let target = forward ? transaction.selectionAfter : transaction.selectionBefore
        selectionModel.set(target, textLength: buffer.length)
        isDirty = true

        let change = makeChange(
            versionBefore: versionBefore,
            lineCountBefore: lineCountBefore,
            edits: edits,
            applied: applied,
            selectionBefore: selectionBefore,
            origin: forward ? .redo : .undo
        )
        onChange?(change)
        return true
    }

    private func makeChange(
        versionBefore: UInt64,
        lineCountBefore: Int,
        edits: [TextEdit],
        applied: [AppliedEdit],
        selectionBefore: [TextSelection],
        origin: EditOrigin
    ) -> EditorChange {
        EditorChange(
            versionBefore: versionBefore,
            versionAfter: buffer.version,
            edits: edits,
            applied: applied,
            selectionBefore: selectionBefore,
            selectionAfter: selectionModel.selections,
            lineCountBefore: lineCountBefore,
            lineCountAfter: buffer.lineCount,
            isDirty: isDirty,
            canUndo: history.canUndo,
            canRedo: history.canRedo,
            origin: origin
        )
    }

    // MARK: - 删除范围

    private func deletionRange(
        for selection: TextSelection,
        direction: DeleteDirection,
        granularity: TextGranularity
    ) -> NSRange? {
        if selection.range.length > 0 {
            return selection.range
        }

        let caret = selection.range.location
        switch (direction, granularity) {
        case (.backward, .character):
            return makeRange(
                from: navigation.previousCharacterBoundary(before: caret),
                to: caret
            )
        case (.forward, .character):
            return makeRange(
                from: caret,
                to: navigation.nextCharacterBoundary(after: caret)
            )
        case (.backward, .word):
            return makeRange(
                from: navigation.previousWordBoundary(before: caret, mode: .word),
                to: caret
            )
        case (.forward, .word):
            return makeRange(
                from: caret,
                to: navigation.nextWordBoundary(after: caret, mode: .word)
            )
        case (.backward, .line):
            return backwardLineRange(at: caret)
        case (.forward, .line):
            return forwardLineRange(at: caret)
        }
    }

    /// ⌘Delete：删除到行首；已在行首时吃掉上一行的行终止符。
    private func backwardLineRange(at caret: Int) -> NSRange? {
        guard caret > 0 else { return nil }
        let start = buffer.lineStart(at: caret)
        if caret > start {
            return NSRange(location: start, length: caret - start)
        }

        guard let previousStart = lineIndex.previousLineStart(before: caret) else {
            return nil
        }
        let previousLine = lineIndex.lineNumber(at: previousStart)
        let terminatorStart = lineIndex.lineContentEnd(at: previousLine)
        return makeRange(from: terminatorStart, to: caret)
    }

    /// ⌘Fn-Delete：删除到行尾；已在行尾时吃掉行终止符，把下一行接上来。
    private func forwardLineRange(at caret: Int) -> NSRange? {
        guard caret < buffer.length else { return nil }
        let contentEnd = buffer.contentEnd(at: caret)
        if contentEnd > caret {
            return NSRange(location: caret, length: contentEnd - caret)
        }

        guard let nextStart = buffer.nextLineStart(after: caret) else { return nil }
        return makeRange(from: caret, to: min(nextStart, buffer.length))
    }

    private func makeRange(from start: Int, to end: Int) -> NSRange? {
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// 多光标删除范围可能重叠：先排序，再把重叠范围合并为一个，
    /// 保证送给 buffer 的批次合法。
    private func performDeletion(ranges: [NSRange], origin: EditOrigin) {
        guard isEditable else { return }

        let sorted = ranges
            .filter { $0.location >= 0 && $0.length > 0 }
            .sorted {
                if $0.location != $1.location {
                    return $0.location < $1.location
                }
                return $0.length < $1.length
            }

        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last,
               range.location < last.location + last.length
            {
                let end = max(last.location + last.length, range.location + range.length)
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length: end - last.location
                )
            } else {
                merged.append(range)
            }
        }

        guard !merged.isEmpty else { return }
        perform(
            edits: merged.map { TextEdit(range: $0, replacement: "") },
            origin: origin
        )
    }

    // MARK: - 输入法辅助

    /// 没有 combo 状态时，IME 提交只作用于主选区。
    private func insertAtPrimarySelection(_ text: String, origin: EditOrigin) {
        guard isEditable, !text.isEmpty else { return }
        perform(
            edits: [TextEdit(range: selectionModel.primary.range, replacement: text)],
            origin: origin
        )
    }

    private static func clampedMarkedRange(_ range: NSRange, in text: String) -> NSRange {
        let length = text.utf16.count
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(0, range.location), length)
        let safeLength = min(max(0, range.length), length - location)
        return NSRange(location: location, length: safeLength)
    }

    // MARK: - 全文缓存

    private func ensureTextCache() {
        guard cachedText == nil else { return }
        cachedText = NSMutableString(string: buffer.string)
        fullTextBuildCount += 1
    }

    /// 按 base 坐标降序更新缓存，与 buffer 的应用顺序一致：
    /// 先处理高位置编辑，低位置编辑的旧坐标就不会被前面的长度变化影响。
    /// 不能直接使用 `rangeInResult`：删除时它的长度为 0，无法定位被删文本。
    private func updateTextCache(with applied: [AppliedEdit]) {
        guard let cachedText else { return }
        for edit in applied.reversed() {
            let range = edit.rangeInBase
            guard range.location >= 0,
                  range.location <= cachedText.length,
                  range.length <= cachedText.length - range.location
            else {
                // 理论上不可达；缓存损坏时丢弃，下次按需从 buffer 重建。
                self.cachedText = nil
                return
            }
            cachedText.replaceCharacters(in: range, with: edit.replacement)
        }
    }
}
