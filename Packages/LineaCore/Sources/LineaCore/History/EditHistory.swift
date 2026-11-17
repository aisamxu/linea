import Foundation

/// 一次可撤销动作。
///
/// - `edits` 使用动作前（base）坐标，重做时直接应用。
/// - `inverseEdits` 使用动作后（结果）坐标，撤销时直接应用。
/// - 只记录被替换文本，不保存整树快照。
public struct EditTransaction: Equatable, Sendable {
    public let edits: [TextEdit]
    public let inverseEdits: [TextEdit]
    public let selectionBefore: [TextSelection]
    public let selectionAfter: [TextSelection]
    public let origin: EditOrigin
    public let timestamp: TimeInterval
    /// 估算的内存占用：正反向替换文本的 UTF-16 字节数。
    public let memoryCost: Int

    public init(
        edits: [TextEdit],
        inverseEdits: [TextEdit],
        selectionBefore: [TextSelection],
        selectionAfter: [TextSelection],
        origin: EditOrigin,
        timestamp: TimeInterval
    ) {
        self.edits = edits
        self.inverseEdits = inverseEdits
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
        self.origin = origin
        self.timestamp = timestamp

        let units = edits.reduce(0) { $0 + $1.replacementLength }
            + inverseEdits.reduce(0) { $0 + $1.replacementLength }
        self.memoryCost = units * MemoryLayout<UInt16>.size
    }
}

/// 撤销/重做栈。
///
/// 一个用户动作对应一个事务；连续键入的合并规则也在这一层实现，
/// 引擎只负责产生事务。历史的顺序是“最旧在前、最新在后”。
public final class EditHistory {
    public struct Limits: Equatable, Sendable {
        public var maximumEntries: Int
        public var maximumBytes: Int

        public init(
            maximumEntries: Int = 2_000,
            maximumBytes: Int = 64 * 1024 * 1024
        ) {
            self.maximumEntries = max(0, maximumEntries)
            self.maximumBytes = max(0, maximumBytes)
        }
    }

    /// 连续键入合并窗口，只有间隔小于 0.5s 的普通键入才可能合并。
    public static let typingCoalescingInterval: TimeInterval = 0.5

    public let limits: Limits

    private var undoStack: [EditTransaction] = []
    private var redoStack: [EditTransaction] = []
    private var undoBytes = 0
    private var redoBytes = 0
    /// 强制下一个事务单独成步的屏障。用于编辑冻结/解冻等历史边界场景。
    private var coalescingBarrier = false

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoCount: Int { undoStack.count }
    public var redoCount: Int { redoStack.count }
    public var totalBytes: Int { undoBytes + redoBytes }

    /// 仅供测试与诊断；数组是值拷贝，不会影响内部栈。
    public var undoEntries: [EditTransaction] { undoStack }
    public var redoEntries: [EditTransaction] { redoStack }

    /// 打断连续键入合并：下一次记录的事务不再与上一条合并。
    /// 编辑冻结/解冻、IME 提交等历史边界应显式调用，不能依赖 0.5s 时间窗口。
    public func breakCoalescing() {
        coalescingBarrier = true
    }

    /// 记录新事务。新编辑立即清空 redo；随后按条目/字节上限淘汰最旧的历史。
    public func record(_ transaction: EditTransaction) {
        redoStack.removeAll()
        redoBytes = 0

        // 屏障存在时跳过合并，并立即消费屏障：只有紧接着的一次记录受影响。
        if coalescingBarrier {
            coalescingBarrier = false
            undoStack.append(transaction)
            undoBytes += transaction.memoryCost
        } else if let previous = undoStack.last,
           Self.canCoalesce(previous: previous, next: transaction)
        {
            let merged = Self.merged(previous: previous, next: transaction)
            undoBytes += merged.memoryCost - previous.memoryCost
            undoStack[undoStack.count - 1] = merged
        } else {
            undoStack.append(transaction)
            undoBytes += transaction.memoryCost
        }

        trim()
    }

    /// 取出最近的可撤销事务并放入 redo 栈。
    public func popUndo() -> EditTransaction? {
        guard let transaction = undoStack.popLast() else { return nil }
        undoBytes -= transaction.memoryCost
        redoStack.append(transaction)
        redoBytes += transaction.memoryCost
        return transaction
    }

    /// 取出最近的可重做事务并放回 undo 栈。
    public func popRedo() -> EditTransaction? {
        guard let transaction = redoStack.popLast() else { return nil }
        redoBytes -= transaction.memoryCost
        undoStack.append(transaction)
        undoBytes += transaction.memoryCost
        return transaction
    }

    /// buffer 应用失败时把事务放回原栈，避免历史与文本状态脱节。
    public func restoreAfterFailedUndo(_ transaction: EditTransaction) {
        guard redoStack.last == transaction else { return }
        redoStack.removeLast()
        redoBytes -= transaction.memoryCost
        undoStack.append(transaction)
        undoBytes += transaction.memoryCost
    }

    public func restoreAfterFailedRedo(_ transaction: EditTransaction) {
        guard undoStack.last == transaction else { return }
        undoStack.removeLast()
        undoBytes -= transaction.memoryCost
        redoStack.append(transaction)
        redoBytes += transaction.memoryCost
    }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        undoBytes = 0
        redoBytes = 0
        coalescingBarrier = false
    }

    // MARK: - 上限

    private func trim() {
        // 条目上限先到先淘汰；字节上限再兜底。
        while undoStack.count > limits.maximumEntries {
            undoBytes -= undoStack.removeFirst().memoryCost
        }
        while undoBytes + redoBytes > limits.maximumBytes, !undoStack.isEmpty {
            undoBytes -= undoStack.removeFirst().memoryCost
        }
    }

    // MARK: - 连续键入合并

    /// 合并条件严格限制为：单光标、纯插入、同一位置连续、间隔 < 0.5s、
    /// 两段文本都不含行终止符。换行、删除、多光标、IME 提交都不会合并。
    private static func canCoalesce(
        previous: EditTransaction,
        next: EditTransaction
    ) -> Bool {
        guard previous.origin == .typing, next.origin == .typing else { return false }
        guard previous.edits.count == 1, next.edits.count == 1 else { return false }
        guard previous.inverseEdits.count == 1, next.inverseEdits.count == 1 else { return false }

        let previousEdit = previous.edits[0]
        let nextEdit = next.edits[0]

        guard previousEdit.range.length == 0, nextEdit.range.length == 0 else { return false }
        guard !previousEdit.replacement.isEmpty, !nextEdit.replacement.isEmpty else { return false }
        guard !containsLineTerminator(previousEdit.replacement),
              !containsLineTerminator(nextEdit.replacement)
        else {
            return false
        }

        guard previous.selectionBefore.count == 1,
              previous.selectionAfter.count == 1,
              next.selectionBefore.count == 1,
              next.selectionAfter.count == 1
        else {
            return false
        }

        let previousBefore = previous.selectionBefore[0]
        let previousAfter = previous.selectionAfter[0]
        let nextBefore = next.selectionBefore[0]
        guard previousBefore.isCaret, previousAfter.isCaret, nextBefore.isCaret else {
            return false
        }
        guard previousBefore.range.location == previousEdit.range.location else { return false }
        guard nextBefore.range.location == nextEdit.range.location else { return false }
        guard previousAfter == nextBefore else { return false }
        guard nextEdit.range.location
            == previousEdit.range.location + previousEdit.replacementLength
        else {
            return false
        }

        let interval = next.timestamp - previous.timestamp
        return interval >= 0 && interval < typingCoalescingInterval
    }

    private static func merged(
        previous: EditTransaction,
        next: EditTransaction
    ) -> EditTransaction {
        let base = previous.edits[0]
        let combined = base.replacement + next.edits[0].replacement

        let forward = [TextEdit(range: base.range, replacement: combined)]
        // 合并后的反向编辑在最终坐标中删除整段新文本。
        let inverse = [
            TextEdit(
                range: NSRange(location: base.range.location, length: combined.utf16.count),
                replacement: ""
            )
        ]

        return EditTransaction(
            edits: forward,
            inverseEdits: inverse,
            selectionBefore: previous.selectionBefore,
            selectionAfter: next.selectionAfter,
            origin: .typing,
            timestamp: next.timestamp
        )
    }

    private static func containsLineTerminator(_ text: String) -> Bool {
        text.utf16.contains { unit in
            unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
        }
    }
}
