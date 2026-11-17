import Foundation

/// 基于 piece tree 的文本缓冲。
///
/// 结构：
/// - 两段存储：`original`（初始文本）与 `add`（追加文本），均为 UTF-16 code unit。
/// - 叶子节点持有一个 piece，引用其中一段的连续区间；内部节点只做聚合。
/// - 内部节点缓存：子树 UTF-16 长度、行终止符数、子树高度、piece 数、
///   首字符是否为 LF、末字符是否为 CR。
///
/// 行终止符：LF、CR、CRLF（算一个）、U+2028、U+2029。
/// CRLF 跨子树时按 `左子树 endsWithCR && 右子树 startsWithLF` 修正，只计一次。
public final class PieceTreeBuffer: TextBuffer {
    // MARK: - 常量

    /// 单个 piece 的目标上限（UTF-16 code unit）。2048 约等于 4 KB。
    /// 块越小，编辑拆分时需要重算行统计的文本越少；块数增加带来的
    /// AVL 深度增长可以忽略，piece 数上限由压缩阈值兜底。
    private static let chunkSize = 2 * 1024

    /// 行号查询的采样间隔：每 64 个 code unit 记录一次累计终止符数，
    /// 使 prefixBreakCount 在 piece 内只需扫描不足一个采样块。
    private static let breakSampleInterval = 64

    /// add 缓冲区超过 1 MB 时必须压缩。
    private static let addCompactionLimit = 1_048_576

    /// piece 数超过 `max(2048, length / 1024)` 时压缩，避免退化成逐字符节点。
    private static let minimumPieceLimit = 2_048

    // MARK: - 存储

    private var original: [UInt16]
    private var add: [UInt16] = []
    private var root: Node?

    public private(set) var version: UInt64 = 0

    // MARK: - 初始化

    public init(text: String) {
        let units = Array(text.utf16)
        original = units
        root = Self.buildInitialTree(units: units)
    }

    public convenience init() {
        self.init(text: "")
    }

    // MARK: - TextBuffer

    public var length: Int {
        root?.length ?? 0
    }

    public var lineCount: Int {
        (root?.breaks ?? 0) + 1
    }

    public var pieceCount: Int {
        root?.count ?? 0
    }

    public var string: String {
        let units = collectUnits(in: 0..<length)
        return String(decoding: units, as: UTF16.self)
    }

    public func substring(in range: NSRange) -> String {
        guard isValidRange(range) else {
            assertionFailure("substring 越界: \(range), length=\(length)")
            return ""
        }
        let units = collectUnits(in: range.location..<(range.location + range.length))
        return String(decoding: units, as: UTF16.self)
    }

    public func character(at offset: Int) -> UInt16? {
        guard offset >= 0, offset < length else { return nil }
        return character(in: root, at: offset)
    }

    @discardableResult
    public func apply(edits: [TextEdit]) -> [AppliedEdit] {
        let ordered = edits.filter { !$0.isEmpty }
        guard !ordered.isEmpty else { return [] }
        // 调用方必须给出升序、互不重叠的 base 坐标；整批校验失败时原子回退。
        guard validate(ordered) else { return [] }

        // 先读取被删文本，再降序应用；降序可保证低位置坐标不受高位置编辑影响。
        var removed: [String] = []
        removed.reserveCapacity(ordered.count)
        for edit in ordered {
            removed.append(substring(in: edit.range))
        }

        for edit in ordered.reversed() {
            replaceUnits(in: edit.range, with: Array(edit.replacement.utf16))
        }

        version &+= 1
        compactIfNeeded()

        // 结果范围按升序 + 累计 delta 计算。
        var applied: [AppliedEdit] = []
        applied.reserveCapacity(ordered.count)
        var delta = 0
        for (index, edit) in ordered.enumerated() {
            let resultStart = edit.range.location + delta
            applied.append(
                AppliedEdit(
                    rangeInBase: edit.range,
                    rangeInResult: NSRange(location: resultStart, length: edit.replacementLength),
                    removedText: removed[index],
                    replacement: edit.replacement
                )
            )
            delta += edit.replacementLength - edit.range.length
        }
        return applied
    }

    public func lineNumber(at offset: Int) -> Int {
        guard offset >= 0, offset <= length else {
            assertionFailure("lineNumber 越界: \(offset), length=\(length)")
            return 1
        }
        return prefixBreakCount(upTo: offset) + 1
    }

    public func lineStart(at offset: Int) -> Int {
        guard offset >= 0, offset <= length else {
            assertionFailure("lineStart 越界: \(offset), length=\(length)")
            return 0
        }
        guard offset > 0 else { return 0 }
        return lastBreakEnd(before: offset) ?? 0
    }

    public func lineRange(at line: Int) -> NSRange {
        guard line >= 1, line <= lineCount else {
            assertionFailure("lineRange 越界: \(line), lineCount=\(lineCount)")
            return NSRange(location: 0, length: 0)
        }
        let start = line == 1 ? 0 : breakEnd(globalIndex: line - 1)
        let end = line == lineCount ? length : breakEnd(globalIndex: line)
        return NSRange(location: start, length: max(0, end - start))
    }

    public func contentEnd(at offset: Int) -> Int {
        guard offset >= 0, offset <= length else {
            assertionFailure("contentEnd 越界: \(offset), length=\(length)")
            return 0
        }
        let start = lineStart(at: offset)
        guard let lineBreak = firstBreak(atOrAfter: start) else { return length }
        return lineBreak.start
    }

    public func nextLineStart(after offset: Int) -> Int? {
        guard offset >= 0, offset <= length else { return nil }
        return firstBreak(atOrAfter: offset)?.end
    }

    // MARK: - 编辑

    /// 校验一批 edits：升序、非重叠、范围合法。
    ///
    /// 非法输入直接返回 false，不做断言：查找/输入法/外部桥接都可能传来
    /// 过期坐标，生产环境不能因此崩溃；批量应用本身是原子操作，失败时
    /// 缓冲区保持不变，调用方可以从版本号判断是否生效。
    private func validate(_ edits: [TextEdit]) -> Bool {
        var previousEnd = 0
        for edit in edits {
            let location = edit.range.location
            let end = location + edit.range.length
            guard location >= 0,
                  edit.range.length >= 0,
                  end <= length,
                  location >= previousEnd
            else {
                return false
            }
            previousEnd = end
        }
        return true
    }

    /// 用新文本替换一个区间。调用方保证 range 合法且 edits 已按降序应用。
    private func replaceUnits(in range: NSRange, with replacement: [UInt16]) {
        let start = range.location
        let end = start + range.length

        let (leftOfEnd, rightOfEnd) = split(root, at: end)
        let (left, removed) = split(leftOfEnd, at: start)
        _ = removed

        var middle: Node?
        if !replacement.isEmpty {
            let addStart = add.count
            add.append(contentsOf: replacement)
            let pieces = Self.makePieces(
                source: .add,
                start: addStart,
                length: replacement.count,
                addUnits: add,
                originalUnits: original
            )
            middle = buildTree(pieces[...])
        }

        root = join(join(left, middle), rightOfEnd)
    }

    /// add buffer 过大或 piece 过碎时，把全文合并回 original 并重新分块。
    ///
    /// 这是 O(n) 操作，但只在阈值触发时执行，摊销到每次编辑可以忽略。
    private func compactIfNeeded() {
        let threshold = max(Self.minimumPieceLimit, length / 1024)
        let addLimit = max(64 * 1024, original.count * 2)
        let shouldCompact =
            add.count > Self.addCompactionLimit
                || add.count > addLimit
                || pieceCount > threshold
        guard shouldCompact else { return }

        let units = collectUnits(in: 0..<length)
        original = units
        add.removeAll(keepingCapacity: false)
        let pieces = Self.makePieces(
            source: .original,
            start: 0,
            length: units.count,
            addUnits: add,
            originalUnits: original
        )
        root = buildTree(pieces[...])
    }

    // MARK: - 行查询

    /// 统计 [0, offset) 内完整结束的行终止符数（CRLF 只算一次）。
    ///
    /// 只统计 offset 之前已经完整出现的终止符：offset 停在 CRLF 两个 code unit
    /// 中间时，这个 CRLF 还不算结束，offset 仍属于前一行。
    /// 通过聚合信息整块累加左子树，定位到 offset 所在的 piece 后，
    /// 用每 64 个 code unit 的累计采样值跳过大部分文本，
    /// 因此复杂度是 O(log n + 采样间隔)。
    private func prefixBreakCount(upTo offset: Int) -> Int {
        guard offset > 0, let root else { return 0 }
        var count = 0
        var previousEndsWithCR = false
        var node: Node? = root
        var consumed = 0

        while let current = node {
            if let piece = current.piece {
                let take = min(offset - consumed, piece.length)
                count += prefixBreakCount(
                    in: piece,
                    take: take,
                    pieceStart: consumed,
                    offset: offset,
                    previousEndsWithCR: previousEndsWithCR
                )
                break
            }

            let left = current.left
            let leftLength = left?.length ?? 0
            if offset - consumed <= leftLength {
                node = left
            } else {
                if let left {
                    count += left.breaks
                    // 左子树开头是 LF、已累计文本结尾是 CR 时，同一个 CRLF 被算了两次。
                    if previousEndsWithCR && left.startsWithLF {
                        count -= 1
                    }
                    previousEndsWithCR = left.endsWithCR
                }
                consumed += leftLength
                node = current.right
            }
        }
        return count
    }

    /// 统计单个 piece 前缀中完整终止符的数量。
    ///
    /// 采样值给出 `localStart` 之前的累计数；剩下的不足 64 个 code unit
    /// 按与整树相同的 CRLF 规则扫描，并处理跨 piece 的 CR/LF 组合。
    private func prefixBreakCount(
        in piece: Piece,
        take: Int,
        pieceStart: Int,
        offset: Int,
        previousEndsWithCR: Bool
    ) -> Int {
        guard take > 0 else { return 0 }

        // 短片段没有采样数组，直接从头扫描。
        let hasSamples = !piece.breakSamples.isEmpty
        let block = hasSamples ? take / Self.breakSampleInterval : 0
        let localStart = hasSamples ? block * Self.breakSampleInterval : 0
        var count = hasSamples ? Int(piece.breakSamples[block]) : 0
        let units = sourceUnits(for: piece.source)

        // 采样值把片段开头的 LF 当作独立终止符；若左侧片段以 CR 结尾，
        // 它是跨 piece CRLF 的后半段，需要扣掉一次。
        if localStart > 0,
           previousEndsWithCR,
           units[piece.start] == 0x0A
        {
            count -= 1
        }

        // 采样累计值只统计“最后一个 code unit 已进入前缀”的终止符，
        // 因此跨采样边界的 CRLF 尚未计入。尾部扫描遇到 LF 时应正常计一次；
        // 只有从片段开头扫描时，左侧片段已计入的 CR 才需要抑制这个 LF。
        var prevCR = localStart == 0 && previousEndsWithCR

        var index = localStart
        while index < take {
            let codeUnit = units[piece.start + index]
            if codeUnit == 0x0D {
                let nextGlobal = pieceStart + index + 1
                let hasNextLF =
                    nextGlobal < length && character(at: nextGlobal) == 0x0A
                if hasNextLF {
                    // LF 也在 [0, offset) 内，CRLF 才完整。
                    if nextGlobal < offset {
                        count += 1
                        if index + 1 < take { index += 1 }
                        prevCR = false
                    } else {
                        // 停在 CRLF 中间：CR 尚未构成终止符。
                        prevCR = true
                    }
                } else {
                    count += 1
                    prevCR = true
                }
            } else if codeUnit == 0x0A {
                if !prevCR { count += 1 }
                prevCR = false
            } else if codeUnit == 0x2028 || codeUnit == 0x2029 {
                count += 1
                prevCR = false
            } else {
                prevCR = false
            }
            index += 1
        }

        // 采样边界恰好是 piece 末尾、且 piece 以 CR 结尾时，采样值没有计入
        // 这个 CR；尾部扫描又为空，需要看文档中的下一个字符补判。
        if localStart > 0, localStart == take, take == piece.length, piece.endsWithCR {
            let nextGlobal = pieceStart + piece.length
            let hasNextLF =
                nextGlobal < length && character(at: nextGlobal) == 0x0A
            if !hasNextLF {
                count += 1
            }
        }

        return count
    }

    /// 返回 offset 之前（含）最后一个行终止符的结束位置，即 offset 所在行的行首。
    private func lastBreakEnd(before offset: Int) -> Int? {
        lastBreakEnd(in: root, nodeStart: 0, limit: offset)
    }

    private func lastBreakEnd(in node: Node?, nodeStart: Int, limit: Int) -> Int? {
        guard let node else { return nil }
        guard limit > nodeStart else { return nil }

        if let piece = node.piece {
            let units = sourceUnits(for: piece.source)
            let localEnd = min(limit - nodeStart, piece.length)
            var index = localEnd - 1
            while index >= 0 {
                let codeUnit = units[piece.start + index]
                let globalIndex = nodeStart + index
                if codeUnit == 0x0A {
                    // LF：无论是否与前面 CR 组成 CRLF，行首都从 LF 之后开始。
                    return globalIndex + 1
                }
                if codeUnit == 0x0D {
                    let nextGlobal = globalIndex + 1
                    if nextGlobal < length, character(at: nextGlobal) == 0x0A {
                        // CRLF：LF 也必须落在 limit 之前才算完整，否则继续向前找。
                        if nextGlobal < limit {
                            return nextGlobal + 1
                        }
                    } else {
                        // 独立 CR。
                        return nextGlobal
                    }
                }
                if codeUnit == 0x2028 || codeUnit == 0x2029 {
                    return globalIndex + 1
                }
                index -= 1
            }
            return nil
        }

        guard let left = node.left else { return nil }
        let leftEnd = nodeStart + left.length
        if limit > leftEnd,
           let result = lastBreakEnd(in: node.right, nodeStart: leftEnd, limit: limit)
        {
            return result
        }
        // 右子树没有终止符时回退到左子树；limit 不裁剪，
        // 保证左子树末尾的 CR 仍能通过向后窥视判断它和右子树开头的 LF 组成 CRLF。
        return lastBreakEnd(in: left, nodeStart: nodeStart, limit: limit)
    }

    /// 返回从 offset 起（含）第一个行终止符的 [start, end)。
    private func firstBreak(atOrAfter offset: Int) -> (start: Int, end: Int)? {
        firstBreak(in: root, nodeStart: 0, from: offset)
    }

    private func firstBreak(
        in node: Node?,
        nodeStart: Int,
        from offset: Int
    ) -> (start: Int, end: Int)? {
        guard let node else { return nil }
        let nodeEnd = nodeStart + node.length
        guard offset < nodeEnd else { return nil }

        if let piece = node.piece {
            let units = sourceUnits(for: piece.source)
            let localStart = max(offset, nodeStart) - nodeStart
            var index = localStart
            while index < piece.length {
                let codeUnit = units[piece.start + index]
                let globalIndex = nodeStart + index
                if codeUnit == 0x0D {
                    var end = globalIndex + 1
                    if end < length, character(at: end) == 0x0A { end += 1 }
                    return (globalIndex, end)
                }
                if codeUnit == 0x0A {
                    // 紧接在 CR 后的 LF 属于跨过扫描起点的 CRLF，跳过，避免重复计行。
                    if index > 0, units[piece.start + index - 1] == 0x0D {
                        index += 1
                        continue
                    }
                    if index == 0, globalIndex > 0, character(at: globalIndex - 1) == 0x0D {
                        index += 1
                        continue
                    }
                    return (globalIndex, globalIndex + 1)
                }
                if codeUnit == 0x2028 || codeUnit == 0x2029 {
                    return (globalIndex, globalIndex + 1)
                }
                index += 1
            }
            return nil
        }

        let left = node.left
        let leftLength = left?.length ?? 0
        let leftEnd = nodeStart + leftLength
        if offset < leftEnd {
            if let result = firstBreak(in: left, nodeStart: nodeStart, from: offset) {
                return result
            }
            return firstBreak(in: node.right, nodeStart: leftEnd, from: leftEnd)
        }
        return firstBreak(in: node.right, nodeStart: leftEnd, from: offset)
    }

    /// 返回全局第 k 个行终止符的结束位置（k 从 1 开始）。
    private func breakEnd(globalIndex k: Int) -> Int {
        guard let root else { return 0 }
        return breakEnd(k: k, in: root)
    }

    private func breakEnd(k: Int, in node: Node) -> Int {
        if let piece = node.piece {
            let units = sourceUnits(for: piece.source)
            var count = 0
            var index = 0
            while index < piece.length {
                let codeUnit = units[piece.start + index]
                if codeUnit == 0x0D {
                    count += 1
                    var end = index + 1
                    if end < piece.length, units[piece.start + end] == 0x0A {
                        end += 1
                    }
                    if count == k { return end }
                    index = end
                    continue
                }
                if codeUnit == 0x0A || codeUnit == 0x2028 || codeUnit == 0x2029 {
                    count += 1
                    if count == k { return index + 1 }
                }
                index += 1
            }
            return piece.length
        }

        guard let left = node.left, let right = node.right else { return 0 }
        let merged = left.endsWithCR && right.startsWithLF
        if k <= left.breaks {
            let end = breakEnd(k: k, in: left)
            // 左子树最后一个 CR 与右子树开头的 LF 组成 CRLF，结束位置要跨过 LF。
            if merged, k == left.breaks {
                return left.length + 1
            }
            return end
        }
        // 右子树开头的 LF 与左子树的 CR 是同一个 CRLF，右子树局部索引要 +1。
        let localIndex = k - left.breaks + (merged ? 1 : 0)
        return left.length + breakEnd(k: localIndex, in: right)
    }

    // MARK: - 区间收集

    private func collectUnits(in range: Range<Int>) -> [UInt16] {
        guard !range.isEmpty else { return [] }
        var result: [UInt16] = []
        result.reserveCapacity(range.count)
        collectUnits(in: range, node: root, nodeStart: 0, into: &result)
        return result
    }

    private func collectUnits(
        in range: Range<Int>,
        node: Node?,
        nodeStart: Int,
        into result: inout [UInt16]
    ) {
        guard let node else { return }
        let nodeEnd = nodeStart + node.length
        guard range.lowerBound < nodeEnd, range.upperBound > nodeStart else { return }

        if let piece = node.piece {
            let localStart = max(range.lowerBound - nodeStart, 0)
            let localEnd = min(range.upperBound - nodeStart, piece.length)
            guard localStart < localEnd else { return }
            let units = sourceUnits(for: piece.source)
            result.append(contentsOf: units[(piece.start + localStart)..<(piece.start + localEnd)])
            return
        }

        let leftLength = node.left?.length ?? 0
        collectUnits(in: range, node: node.left, nodeStart: nodeStart, into: &result)
        collectUnits(
            in: range,
            node: node.right,
            nodeStart: nodeStart + leftLength,
            into: &result
        )
    }

    private func character(in node: Node?, at offset: Int) -> UInt16? {
        guard let node else { return nil }
        if let piece = node.piece {
            guard offset >= 0, offset < piece.length else { return nil }
            return sourceUnits(for: piece.source)[piece.start + offset]
        }
        let leftLength = node.left?.length ?? 0
        if offset < leftLength {
            return character(in: node.left, at: offset)
        }
        return character(in: node.right, at: offset - leftLength)
    }

    // MARK: - Piece / Node

    private struct Piece {
        enum Source {
            case original
            case add
        }

        let source: Source
        let start: Int
        let length: Int
        let breaks: Int
        let startsWithLF: Bool
        let endsWithCR: Bool
        /// 每 64 个 code unit 边界处的累计终止符数（长度为 k 的终止符
        /// 要等最后一个 code unit 进入前缀后才计入），用于行号查询走二分采样。
        let breakSamples: [UInt16]
    }

    private final class Node {
        let piece: Piece?
        var left: Node?
        var right: Node?
        var length: Int = 0
        var breaks: Int = 0
        var count: Int = 0
        var height: Int = 0
        var startsWithLF: Bool = false
        var endsWithCR: Bool = false

        init(piece: Piece) {
            self.piece = piece
            update()
        }

        init(left: Node?, right: Node?) {
            self.piece = nil
            self.left = left
            self.right = right
            update()
        }

        /// 重新计算聚合值。内部节点固定有两个孩子，叶子持有 piece。
        func update() {
            if let piece {
                left = nil
                right = nil
                length = piece.length
                breaks = piece.breaks
                count = 1
                height = 1
                startsWithLF = piece.startsWithLF
                endsWithCR = piece.endsWithCR
                return
            }

            let leftLength = left?.length ?? 0
            let rightLength = right?.length ?? 0
            length = leftLength + rightLength

            var breakCount = (left?.breaks ?? 0) + (right?.breaks ?? 0)
            if let left, let right, left.endsWithCR, right.startsWithLF {
                // 同一个 CRLF 在左右子树各计了一次，合并时减一。
                breakCount -= 1
            }
            breaks = breakCount

            count = (left?.count ?? 0) + (right?.count ?? 0)
            height = 1 + max(left?.height ?? 0, right?.height ?? 0)
            startsWithLF = left?.startsWithLF ?? false
            endsWithCR = right?.endsWithCR ?? false
        }

        var balanceFactor: Int {
            (left?.height ?? 0) - (right?.height ?? 0)
        }
    }

    // MARK: - 构建与平衡

    private static func buildInitialTree(units: [UInt16]) -> Node? {
        let pieces = makePieces(
            source: .original,
            start: 0,
            length: units.count,
            addUnits: [],
            originalUnits: units
        )
        return buildBalanced(pieces[...])
    }

    private func buildTree(_ pieces: ArraySlice<Piece>) -> Node? {
        Self.buildBalanced(pieces)
    }

    private static func buildBalanced(_ pieces: ArraySlice<Piece>) -> Node? {
        guard !pieces.isEmpty else { return nil }
        if pieces.count == 1 {
            return Node(piece: pieces[pieces.startIndex])
        }
        let middle = pieces.startIndex + pieces.count / 2
        let left = buildBalanced(pieces[pieces.startIndex..<middle])
        let right = buildBalanced(pieces[middle..<pieces.endIndex])
        return Node(left: left, right: right)
    }

    /// 把一段连续文本切成不超过 chunkSize 的 piece。
    private static func makePieces(
        source: Piece.Source,
        start: Int,
        length: Int,
        addUnits: [UInt16],
        originalUnits: [UInt16]
    ) -> [Piece] {
        guard length > 0 else { return [] }
        var pieces: [Piece] = []
        pieces.reserveCapacity(length / chunkSize + 1)
        let units = source == .original ? originalUnits : addUnits
        var offset = 0
        while offset < length {
            let pieceLength = min(chunkSize, length - offset)
            pieces.append(
                makePiece(
                    source: source,
                    start: start + offset,
                    length: pieceLength,
                    units: units
                )
            )
            offset += pieceLength
        }
        return pieces
    }

    private static func makePiece(
        source: Piece.Source,
        start: Int,
        length: Int,
        units: [UInt16]
    ) -> Piece {
        var breaks = 0
        // 短片段（编辑产生的新增文本）不值得为采样分配数组；
        // 查询时会直接扫描不足 64 个 code unit。
        let tracksSamples = length >= breakSampleInterval
        var samples: [UInt16] = []
        if tracksSamples {
            samples.reserveCapacity(length / breakSampleInterval + 1)
        }

        // 单遍同时统计终止符和采样值：
        // - CRLF 延迟到 LF 处理，保证只在 LF 位置计入一次；
        // - 采样值记录“最后一个 code unit 已进入前缀”的完整终止符数，
        //   因此查询停在 CRLF 中间时不会提前计数。
        var index = 0
        while index < length {
            if tracksSamples, index % breakSampleInterval == 0 {
                samples.append(UInt16(breaks))
            }

            let codeUnit = units[start + index]
            if codeUnit == 0x0D {
                if index + 1 < length, units[start + index + 1] == 0x0A {
                    // CRLF 由下一个 LF 统一计数。
                } else {
                    breaks += 1
                }
            } else if codeUnit == 0x0A || codeUnit == 0x2028 || codeUnit == 0x2029 {
                breaks += 1
            }
            index += 1
        }

        // 长度正好落在采样边界时，循环内没有机会记录末尾累计值。
        // 采样值表示“已完整结束”的终止符：片段末尾的 CR 可能和下一片段的
        // LF 组成 CRLF，因此这里先不计入，查询时再按文档相邻字符补判。
        if tracksSamples, length % breakSampleInterval == 0 {
            let endsWithCR = units[start + length - 1] == 0x0D
            samples.append(UInt16(endsWithCR ? breaks - 1 : breaks))
        }

        return Piece(
            source: source,
            start: start,
            length: length,
            breaks: breaks,
            startsWithLF: units[start] == 0x0A,
            endsWithCR: units[start + length - 1] == 0x0D,
            breakSamples: samples
        )
    }

    private func sourceUnits(for source: Piece.Source) -> [UInt16] {
        switch source {
        case .original: return original
        case .add: return add
        }
    }

    // MARK: - AVL split / join

    /// 按 UTF-16 偏移把树拆成 [0, offset) 与 [offset, end)。
    private func split(_ node: Node?, at offset: Int) -> (Node?, Node?) {
        guard let node else { return (nil, nil) }

        if let piece = node.piece {
            if offset <= 0 { return (nil, node) }
            if offset >= piece.length { return (node, nil) }
            let units = sourceUnits(for: piece.source)
            let leftPiece = Self.makePiece(
                source: piece.source,
                start: piece.start,
                length: offset,
                units: units
            )
            let rightPiece = Self.makePiece(
                source: piece.source,
                start: piece.start + offset,
                length: piece.length - offset,
                units: units
            )
            return (Node(piece: leftPiece), Node(piece: rightPiece))
        }

        let left = node.left
        let right = node.right
        let leftLength = left?.length ?? 0
        if offset < leftLength {
            let (a, b) = split(left, at: offset)
            return (a, join(b, right))
        }
        if offset == leftLength {
            return (left, right)
        }
        let (a, b) = split(right, at: offset - leftLength)
        return (join(left, a), b)
    }

    /// 按 AVL 规则合并两棵树；高度差过大时递归下沉，否则新建内部节点。
    private func join(_ left: Node?, _ right: Node?) -> Node? {
        guard let left else { return right }
        guard let right else { return left }

        if left.height > right.height + 1, let leftRight = left.right {
            left.right = join(leftRight, right)
            return balance(left)
        }
        if right.height > left.height + 1, let rightLeft = right.left {
            right.left = join(left, rightLeft)
            return balance(right)
        }
        return Node(left: left, right: right)
    }

    private func balance(_ node: Node) -> Node {
        node.update()
        let factor = node.balanceFactor
        if factor > 1, let left = node.left {
            if (left.left?.height ?? 0) < (left.right?.height ?? 0) {
                node.left = rotateLeft(left)
                node.update()
            }
            return rotateRight(node)
        }
        if factor < -1, let right = node.right {
            if (right.right?.height ?? 0) < (right.left?.height ?? 0) {
                node.right = rotateRight(right)
                node.update()
            }
            return rotateLeft(node)
        }
        return node
    }

    private func rotateLeft(_ node: Node) -> Node {
        guard let pivot = node.right else { return node }
        node.right = pivot.left
        pivot.left = node
        node.update()
        pivot.update()
        return pivot
    }

    private func rotateRight(_ node: Node) -> Node {
        guard let pivot = node.left else { return node }
        node.left = pivot.right
        pivot.right = node
        node.update()
        pivot.update()
        return pivot
    }

    // MARK: - 工具

    private func isValidRange(_ range: NSRange) -> Bool {
        range.location >= 0
            && range.length >= 0
            && range.location + range.length <= length
    }
}
