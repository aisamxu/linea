import Foundation

/// UTF-16 文档范围的校验与夹取。
///
/// 所有范围都使用 UTF-16 `NSRange`，语义与引擎、会话和剪贴板一致。
/// 提供两档夹取：编辑命令内部按 0 修正负分量，外部入口则整体
/// 拒绝畸形范围，避免不同调用点各自处理边界时产生分叉。
public extension NSRange {
    /// 把范围夹取到 `0...textLength`。
    ///
    /// 负位置/负长度按 0 处理（与选区模型的既有语义一致），
    /// `NSNotFound` 视为非法并返回文档开头的空范围。
    /// 位置越界夹到文档末尾，长度越界截断到剩余文本长度。
    func clampedToTextLength(_ textLength: Int) -> NSRange {
        let safeLength = max(0, textLength)
        guard location != NSNotFound else {
            return NSRange(location: 0, length: 0)
        }
        let clampedLocation = min(max(0, location), safeLength)
        let clampedLength = min(max(0, length), safeLength - clampedLocation)
        return NSRange(location: clampedLocation, length: clampedLength)
    }

    /// 严格夹取：负位置或负长度视为非法输入并归零，其余规则同上。
    ///
    /// 供 AX、输入法和选区桥接等外部入口使用，避免把畸形范围
    /// 悄悄修正成文档开头的有效范围。
    func sanitizedToTextLength(_ textLength: Int) -> NSRange {
        guard location != NSNotFound, location >= 0, length >= 0 else {
            return NSRange(location: 0, length: 0)
        }
        return clampedToTextLength(textLength)
    }

    /// 范围是否完整落在 `0...textLength` 内。
    ///
    /// 负文本长度本身就是错误状态，任何范围都判为非法。
    func isValidTextRange(in textLength: Int) -> Bool {
        guard textLength >= 0 else { return false }
        return location != NSNotFound
            && location >= 0
            && length >= 0
            && location <= textLength
            && length <= textLength - location
    }
}
