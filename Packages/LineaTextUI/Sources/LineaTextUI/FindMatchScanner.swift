import Foundation

/// 查找栏默认匹配的本地快速扫描。
///
/// 只用于在 `NSTextFinder` 发布 `incrementalMatchRanges` 之前提供即时高亮：
/// 查找器的全量增量搜索在匹配不在可见区域时会延迟约 1 秒，键盘输入期间
/// 用户会感到“输入后要等一会才有反馈”。扫描语义与查找栏默认值对齐：
/// 字面量包含、忽略大小写、不重叠、不循环。
public enum FindMatchScanner {
    /// 与多光标上限一致；超出部分不再返回，避免极端文档拖慢每次按键。
    public static let maximumMatchCount = 10_000

    /// 返回 `needle` 在 `text` 中的所有非重叠匹配（升序）。
    public static func ranges(
        of needle: String,
        in text: String,
        limit: Int = maximumMatchCount
    ) -> [NSRange] {
        guard !needle.isEmpty, !text.isEmpty, limit > 0 else { return [] }

        let nsText = text as NSString
        var results: [NSRange] = []
        var searchStart = 0
        while searchStart < nsText.length {
            let found = nsText.range(
                of: needle,
                options: [.caseInsensitive],
                range: NSRange(
                    location: searchStart,
                    length: nsText.length - searchStart
                )
            )
            guard found.location != NSNotFound else { break }
            results.append(found)
            guard results.count < limit else { break }
            // 与查找器一致：从匹配末尾继续，空匹配（needle 非空时不会发生）也保证前进。
            searchStart = found.location + max(found.length, 1)
        }
        return results
    }
}
