import Foundation

/// 查找栏匹配选项。
///
/// 默认与 macOS 查找栏一致：字面量包含、忽略大小写；
/// `wholeWord` 打开后要求匹配两侧都不是单词字符（字母、数字、下划线）。
public struct FindMatchOptions: Equatable, Sendable {
    public var matchCase: Bool
    public var wholeWord: Bool

    public init(matchCase: Bool = false, wholeWord: Bool = false) {
        self.matchCase = matchCase
        self.wholeWord = wholeWord
    }

    public static let standard = FindMatchOptions()
}

/// 查找栏的本地快速扫描。
///
/// 查找栏已改为自建 UI，本扫描器同时承担即时高亮与导航/替换的匹配来源。
/// 语义：字面量包含、默认忽略大小写、不重叠、不循环。
public enum FindMatchScanner {
    /// 与多光标上限一致；超出部分不再返回，避免极端文档拖慢每次按键。
    public static let maximumMatchCount = 10_000

    /// 单词字符集合：字母、数字、下划线。全字匹配要求匹配两侧都不是这些字符。
    private static let wordCharacters: CharacterSet =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    /// 返回 `needle` 在 `text` 中的所有非重叠匹配（升序）。
    public static func ranges(
        of needle: String,
        in text: String,
        limit: Int = maximumMatchCount
    ) -> [NSRange] {
        ranges(of: needle, in: text, options: .standard, limit: limit)
    }

    /// 返回带选项的匹配。`wholeWord` 的边界判断在 UTF-16 码元层面完成，
    /// 非 BMP 字符按“非单词字符”处理（与常见编辑器一致，且避免逐匹配构造子串）。
    public static func ranges(
        of needle: String,
        in text: String,
        options: FindMatchOptions,
        limit: Int = maximumMatchCount
    ) -> [NSRange] {
        guard !needle.isEmpty, !text.isEmpty, limit > 0 else { return [] }

        let nsText = text as NSString
        let compareOptions: NSString.CompareOptions =
            options.matchCase ? [] : [.caseInsensitive]
        var results: [NSRange] = []
        var searchStart = 0
        while searchStart < nsText.length {
            let found = nsText.range(
                of: needle,
                options: compareOptions,
                range: NSRange(
                    location: searchStart,
                    length: nsText.length - searchStart
                )
            )
            guard found.location != NSNotFound else { break }

            if !options.wholeWord || isWholeWord(found, in: nsText) {
                results.append(found)
                guard results.count < limit else { break }
            }
            // 始终从匹配末尾继续，避免全字匹配被拒绝时在同一位置反复命中。
            searchStart = found.location + max(found.length, 1)
        }
        return results
    }

    /// 匹配两侧（若存在）都不是单词字符，才算全字匹配。
    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        if range.location > 0,
           isWordCharacter(text.character(at: range.location - 1)) {
            return false
        }
        let end = range.location + range.length
        if end < text.length, isWordCharacter(text.character(at: end)) {
            return false
        }
        return true
    }

    private static func isWordCharacter(_ codeUnit: unichar) -> Bool {
        // 代理项码元不能构成 Unicode Scalar，直接视为非单词字符。
        guard let scalar = Unicode.Scalar(codeUnit) else { return false }
        return wordCharacters.contains(scalar)
    }
}
