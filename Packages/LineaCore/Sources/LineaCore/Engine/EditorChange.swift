import Foundation

/// 一次成功编辑后的完整变化描述。
///
/// `edits` 使用编辑前（base）坐标；`applied` 同时给出 base 与结果坐标，
/// 视图可据此做精确失效，历史记录只需要 inverse edits。
public struct EditorChange: Equatable, Sendable {
    public let versionBefore: UInt64
    public let versionAfter: UInt64
    public let edits: [TextEdit]
    public let applied: [AppliedEdit]
    public let selectionBefore: [TextSelection]
    public let selectionAfter: [TextSelection]
    public let lineCountBefore: Int
    public let lineCountAfter: Int
    public let isDirty: Bool
    public let canUndo: Bool
    public let canRedo: Bool
    public let origin: EditOrigin

    public init(
        versionBefore: UInt64,
        versionAfter: UInt64,
        edits: [TextEdit],
        applied: [AppliedEdit],
        selectionBefore: [TextSelection],
        selectionAfter: [TextSelection],
        lineCountBefore: Int,
        lineCountAfter: Int,
        isDirty: Bool,
        canUndo: Bool,
        canRedo: Bool,
        origin: EditOrigin
    ) {
        self.versionBefore = versionBefore
        self.versionAfter = versionAfter
        self.edits = edits
        self.applied = applied
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
        self.lineCountBefore = lineCountBefore
        self.lineCountAfter = lineCountAfter
        self.isDirty = isDirty
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.origin = origin
    }
}
