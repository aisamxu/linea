import AppKit
import STTextView
import STTextKitPlus

/// 在 NSRange（稳定的会话快照格式）与 NSTextSelection（TextKit 2 内部格式）之间转换。
///
/// 顺序必须保留：STTextView 把最后一个 selection 当作主选区，输入法候选窗口、
/// 滚动定位和命令处理都依赖它。
enum TextSelectionBridge {
    static func ranges(in textView: STTextView) -> [NSRange] {
        let layoutManager = textView.textLayoutManager
        guard let contentManager = layoutManager.textContentManager else {
            return [NSRange(location: 0, length: 0)]
        }

        let textLength = contentManager.length
        let ranges = layoutManager.textSelections
            .filter { !$0.isTransient }
            .flatMap(\.textRanges)
            .compactMap { textRange -> NSRange? in
                let range = NSRange(textRange, in: contentManager)
                guard range.location != NSNotFound else { return nil }
                return clamped(range, to: textLength)
            }

        return ranges.isEmpty ? [NSRange(location: 0, length: 0)] : ranges
    }

    static func setRanges(_ ranges: [NSRange], in textView: STTextView) {
        let layoutManager = textView.textLayoutManager
        guard let contentManager = layoutManager.textContentManager else { return }

        let textLength = contentManager.length
        let sourceRanges = ranges.isEmpty ? [NSRange(location: 0, length: 0)] : ranges
        var selections: [NSTextSelection] = []

        for sourceRange in sourceRanges {
            let range = clamped(sourceRange, to: textLength)
            guard let textRange = NSTextRange(range, in: contentManager) else { continue }
            selections.append(
                NSTextSelection(range: textRange, affinity: .downstream, granularity: .character)
            )
        }

        if selections.isEmpty {
            selections = [
                NSTextSelection(contentManager.documentRange.location, affinity: .downstream)
            ]
        }

        layoutManager.textSelections = selections
    }

    static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: 0, length: 0)
        }

        let safeLength = max(0, length)
        let location = min(max(0, range.location), safeLength)
        let rangeLength = min(max(0, range.length), safeLength - location)
        return NSRange(location: location, length: rangeLength)
    }
}
