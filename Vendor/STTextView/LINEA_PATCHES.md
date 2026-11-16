# Linea 对 STTextView 的本地补丁

本目录是 [STTextView](https://github.com/krzyzanowskim/STTextView) **2.4.1**（commit `bbdcfd9d413ad3055dafd23a223be9bd39742f89`）的 vendored 副本，仅用于修复 Linea 多光标编辑的性能热点。上游许可证见 [LICENSE.md](LICENSE.md)，Linea 继续以 GPL-3.0 分发。

示例工程 `TextEdit`、`TextEdit.SwiftUI` 和 `.github` 已从副本中移除，`Sources/`、`Tests/`、`Package.swift` 及上游许可证保持原样。

## 补丁列表

### 1. 合并插入点刷新

文件：`Sources/STTextViewAppKit/STTextView.swift`

`updateSelectedRangeHighlight()` 原本在每个零宽选区回调里调用 `updateInsertionPointStateAndRestartTimer()`。该函数自身会遍历全部插入点，因此 k 个光标会退化为 O(k²)。现在只记录是否需要刷新，遍历结束后统一调用一次。

### 2. 行号 gutter 跳过无关的选区扫描

文件：`Sources/STTextViewAppKit/STTextView+Gutter.swift`

`isLineSelected` 会为每条可见行遍历全部选区。Linea 没有启用 `highlightSelectedLine`，因此现在仅在 `gutterView.highlightSelectedLine == true` 时计算，避免 O(可见行 × 光标数) 的无效开销。

### 3. 批量替换只做一次选区去重

文件：

- `Sources/STTextViewCommon/STTextContentStorage.swift`
- `Sources/STTextViewAppKit/STTextView.swift`

`STTextContentStorage.fix_fixSelectionAfterChangeInCharacterRange()` 原本在每次 `replaceContents` 后都用嵌套循环去重。多光标替换会对 k 个 range 各调用一次，形成昂贵的 O(k²) 路径。

现在：

- 多 range 替换开始时通过 `beginDeferringSelectionFix()` 进入延迟状态；整批替换结束后调用一次 `endDeferringSelectionFix()`。
- 去重键改用 `NSRange` 的 `Set`，不再用逐个 `NSTextRange` 的相等比较。
- 单 range 编辑保持原行为。

## 本地测量

在同一台 Apple 芯片 Mac、900×600 窗口、每行一个零宽光标的基准中（`insertText` + 选区同步 + `layoutSubtreeIfNeeded`）：

| 场景 | 打补丁前 | 打补丁后（Debug） | 打补丁后（Release） |
| --- | ---: | ---: | ---: |
| 60 光标插入 | ~62 ms | ~40–46 ms | ~38 ms |
| 500 光标插入 | ~4.85 s | ~270–330 ms | ~245–253 ms |
| 500 光标撤销 | 未单独测 | ~220–240 ms | ~192–194 ms |

500 光标插入后选区数量和一次撤销后的选区数量均保持 500。

## 维护方式

- 这些补丁只针对多光标热点，不改变单光标和 IME 行为。
- 升级 STTextView 时先尝试用新版源码重新跑 `MultiCursorPerformanceTests`；若上游已修复，删除本目录并在 `project.yml` 恢复远程 `exactVersion`。
- 如果继续保留补丁，优先向上游提交 PR，并在本文件记录新的版本、commit 和 diff 范围。
