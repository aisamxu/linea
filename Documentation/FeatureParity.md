# Linea 1.0.2 功能基线（1.1.0 对拍清单）

本文件记录 1.0.2 的全部用户可见行为，作为 1.1.0 自建编辑/布局引擎的功能对拍依据。Phase 5 逐项验收时在“对拍”列勾选。

分类：

- ✅ 必须保持：行为、快捷键、文件/会话格式完全一致。
- ⚠️ 可接受差异：明确记录差异，不视为回归。
- ❌ 明确不做：产品没有入口，重写时不新增。

## 1. 窗口与标签

| 编号 | 行为 | 1.0.2 实现 | 要求 | 对拍 |
| --- | --- | --- | --- | --- |
| W1 | 多窗口 | File > New Window（⇧⌘N）；每窗口独立标签组 | ✅ | ☐ |
| W2 | 标签栏 | 每窗口自定义 SwiftUI 标签栏：标题、脏点、关闭按钮、末尾 `+`；1.1.0 起点击标签栏空白处与 ⌘N / ⌘T 一样新建标签 | ✅（新增空白点击） | ☐ |
| W3 | 每标签独立状态 | 独立文本、选区、滚动位置、撤销历史 | ✅ | ☐ |
| W4 | 切换标签 | 保留全部选区、主选区与滚动原点 | ✅ | ☐ |
| W5 | 关闭脏标签 | Save / Don't Save / Cancel | ✅ | ☐ |
| W6 | 关闭最后一个标签 | 关闭窗口 | ✅ | ☐ |
| W7 | 关闭所有窗口 | 不退出 App；Dock 重新打开时新建或置前已有窗口 | ✅ | ☐ |
| W8 | Untitled 编号 | 按窗口内最大编号递增（Untitled 1、Untitled 2…） | ✅ | ☐ |
| W9 | 重复打开文件 | 聚焦已有标签，不新建重复标签 | ✅ | ☐ |
| W10 | 关闭快捷键 | ⌘W 关闭标签；⇧⌘W 关闭窗口 | ✅ | ☐ |

## 2. 文件

| 编号 | 行为 | 1.0.2 实现 | 要求 | 对拍 |
| --- | --- | --- | --- | --- |
| F1 | 打开 | ⌘O；支持多选；解析 Finder 别名 | ✅ | ☐ |
| F2 | 保存 | ⌘S 保存；⇧⌘S 另存为 | ✅ | ☐ |
| F3 | 外部修改 | 打开/切换/保存前比较文件签名；Overwrite / Reload / Cancel | ✅ | ☐ |
| F4 | 文件缺失 | Save As / Recreate / Cancel | ✅ | ☐ |
| F5 | 重载 | 保留选区（越界 clamp）、保留滚动原点、清空撤销、置为 clean | ✅ | ☐ |
| F6 | 编码 | 严格 UTF-8；非法字节报错，不静默替换 | ✅ | ☐ |
| F7 | 写入 | 原子写入 | ✅ | ☐ |
| F8 | 未实现 | 无自动保存、最近文件、文件监视、iCloud、打印、导出 | ❌ | — |

## 3. 脏状态与草稿

| 编号 | 行为 | 1.0.2 实现 | 要求 | 对拍 |
| --- | --- | --- | --- | --- |
| D1 | 单调脏 | 首次可撤销编辑后置脏；保存/重载清除；undo/redo 不自动清 | ✅ | ☐ |
| D2 | 草稿 | 正常退出时为脏文档和未命名文档写草稿 | ✅ | ☐ |
| D3 | 崩溃恢复 | 崩溃、强退、断电不保证恢复；不新增恢复机制 | ❌ | — |
| D4 | 草稿安全 | 目录 0700、文件 0600；草稿名路径穿越防护 | ✅ | ☐ |

## 4. 会话

| 编号 | 行为 | 1.0.2 实现 | 要求 | 对拍 |
| --- | --- | --- | --- | --- |
| S1 | 版本 | `version: 1`；不升级格式 | ✅ | ☐ |
| S2 | 窗口 | frame、激活窗口 | ✅ | ☐ |
| S3 | 标签 | 顺序、当前标签、路径、显示名、脏状态、草稿、文件签名 | ✅ | ☐ |
| S4 | 编辑器状态 | 全部选区（UTF-16 `NSRange`，最后为主）、滚动原点（clip view bounds） | ✅ | ☐ |
| S5 | 恢复 | 校正窗口位置；脏草稿恢复后仍为脏、撤销历史为空 | ✅ | ☐ |

## 5. 编辑区外观与文本服务

| 编号 | 行为 | 1.0.2 实现 | 要求 | 对拍 |
| --- | --- | --- | --- | --- |
| A1 | 字体/行高 | 默认 13pt `monospacedSystemFont`；lineHeightMultiple 1.2；1.1.0 支持 10–24pt 缩放，行高随字号等比 | ✅（新增缩放） | ☐ |
| A2 | Tab | `defaultTabInterval = 28pt`；无自定义 tab stops | ✅ | ☐ |
| A3 | 换行 | 无软换行，横向滚动 | ✅ | ☐ |
| A4 | 滚动条 | 横纵自动隐藏；无边框 | ✅ | ☐ |
| A5 | 行号 | 始终显示；默认 11pt 等宽数字，随正文字号等比缩放；`.secondaryLabelColor`；右侧分隔线；最小宽度 35 | ✅ | ☐ |
| A6 | 当前行高亮 | 无 | ❌ | — |
| A7 | 外观 | 跟随系统浅色/深色；无主题设置 | ✅ | ☐ |
| A8 | 文本服务 | 关闭拼写/语法/自动更正/自动替换/智能引号/自动补全；关闭字体面板 | ✅ | ☐ |
| A9 | 缩放/偏好 | 1.0.2 无字体缩放；1.1.0 新增 ⌘+/⌘-/⌘0（10–24pt，持久化），仍无偏好设置窗口 | ✅（新增缩放） | ☐ |

## 6. 查找与替换

| 编号 | 行为 | 1.0.2 实现 | 要求 | 对拍 |
| --- | --- | --- | --- | --- |
| P1 | 查找栏 | 1.0.2 用系统 `NSTextFinder`；1.1.0 改为自建 `FindBarView`，不再依赖私有 find bar | ✅（重写） | ☐ |
| P2 | 快捷键 | ⌘F / ⌥⌘F / ⌘G / ⇧⌘G；搜索框内 Return/⇧Return 下一个/上一个，Esc 收起 | ✅ | ☐ |
| P3 | 增量搜索 | 每次键入立即调用本地 `FindMatchScanner` 重算并自绘高亮，无发布延迟 | ✅ | ☐ |
| P4 | 多光标 | 打开查找/替换前折叠为单光标 | ✅ | ☐ |
| P5 | 替换 | 走编辑事务；Replace All 合并为一个撤销条目，并保持替换前的滚动位置与行号完整 | ✅（新引擎目标） | ☐ |
| P6 | 高亮 | 视图直接使用扫描出的匹配范围自绘黄色高亮；不创建遮罩子视图 | ✅ | ☐ |
| P7 | 全部匹配转多光标 | Find > Select All Matches（⌥⌘G）或查找栏 S*，把全部查找结果写成多选区，可直接编辑 | ✅（新增） | ☐ |
| P8 | 自动预填 | 有单行选区时 ⌘F/⌥⌘F 直接把它填入搜索框；跨行选区不预填 | ✅（新增） | ☐ |
| P9 | 搜索选项 | Aa 区分大小写；wd 全字匹配（两侧不能是字母/数字/下划线）；可组合 | ✅（新增） | ☐ |

## 7. 多光标

| 编号 | 行为 | 1.0.2 实现 | 要求 | 对拍 |
| --- | --- | --- | --- | --- |
| M1 | ⌘D | 选择下一个相同词；ASCII 标识符词边界（字母/数字/下划线）；大小写敏感；不重叠、不循环 | ✅ | ☐ |
| M2 | ⌃⌘G | 选择全部相同词 | ✅ | ☐ |
| M3 | ⇧⌘L | 在选中行行首加光标 | ✅ | ☐ |
| M4 | ⌘+点击 | 加/移除光标；再点已有光标即移除，至少保留一个 | ✅ | ☐ |
| M5 | ⇧⌃+点击 | 追加光标（1.0.2 原生多选手势） | ✅ | ☐ |
| M6 | Esc | 折叠为单光标；输入法组合中不折叠 | ✅ | ☐ |
| M7 | 上限 | 1.0.2 上限 10,000 个选区；1.1.0 起取消数量上限，整篇文档逐行加光标不受限 | 已取消限制 | ☐ |
| M8 | 无匹配 | 无可选内容时 beep，不改变选区 | ✅ | ☐ |
| M9 | 一次按键 | 所有光标一次事务、一次撤销 | ✅ | ☐ |
| M10 | 行边界 | LF/CR/CRLF/U+2028/U+2029 统一为行终止符 | ✅（新引擎统一） | ☐ |
| M11 | 行尾光标 | 行尾光标位于行终止符之前 | ✅ | ☐ |
| M12 | ⌥+点击 | 与 ⌘+点击一致：加/移除光标；⇧⌥+点击只追加、不移除 | ✅（新增） | ☐ |

## 8. 剪贴板与右键菜单

| 编号 | 行为 | 1.0.2 实现 | 要求 | 对拍 |
| --- | --- | --- | --- | --- |
| C1 | Copy | 写 RTF + 纯字符串；多选区按文档顺序用 `\n` 连接 | ✅ | ☐ |
| C2 | Paste | ⌘V 与右键 Paste 均只按纯文本粘贴 | ✅ | ☐ |
| C3 | Cut | Copy + 一次删除事务 | ✅ | ☐ |
| C4 | 右键菜单 | Cut / Copy / Paste / Paste and Match Style / 分隔线 / Select All | ✅ | ☐ |
| C5 | 空白处右键 | 没有非插入点选区时，先选中点击处单词再弹菜单 | ✅ | ☐ |

## 9. 拖放

| 编号 | 行为 | 1.0.2 实现 | 要求 | 对拍 |
| --- | --- | --- | --- | --- |
| T1 | 应用内拖拽 | 移动文本 | ✅ | ☐ |
| T2 | 应用外拖拽 | 复制文本 | ✅ | ☐ |
| T3 | 外部纯文本 | 插入到落点 | ✅ | ☐ |
| T4 | 文件 URL | 1.0.2 不接收；现在支持拖入 txt/md 等纯文本文件打开为新标签 | ✅（新增） | ☐ |
| T5 | RTF 拖入 | STTextView `isRichText = true`，可能带入字体/颜色（保存时丢失） | ⚠️ 统一纯文本，不复现副作用 | ☐ |

## 10. 输入法、听写与系统输入

| 编号 | 行为 | 1.0.2 实现 | 要求 | 对拍 |
| --- | --- | --- | --- | --- |
| I1 | Marked text | 组合文本、候选窗以主选区定位、`hasMarkedText` 可靠 | ✅ | ☐ |
| I2 | 多光标 | 只在主选区组合；提交后其他光标随文本平移 | ✅ | ☐ |
| I3 | 听写 | 走 `NSTextInputClient` 的 marked text 路径 | ✅ | ☐ |
| I4 | emoji picker | 走 `NSTextInputClient` | ✅ | ☐ |
| I5 | 组合边界 | 保存/切换标签/关闭/退出前提交组合，不写半成品草稿 | ✅（新引擎显式 `commitPendingInput()`） | ☐ |
| I6 | 组合中 Esc/⌘Z | Esc 取消组合；⌘Z 在组合中不执行撤销 | ✅ | ☐ |

## 11. 无障碍

| 编号 | 行为 | 1.0.2 实现 | 要求 | 对拍 |
| --- | --- | --- | --- | --- |
| X1 | 文本区属性 | text area、值、选中文本/范围、插入点行号、可见字符范围、行/坐标定位 | ✅ | ☐ |
| X2 | AXTextMarker | 未实现 | ✅ 同等能力为基线；VoiceOver spike 后再决定是否补 | ☐ |
| X3 | 通知 | 编辑、选区、滚动后发出对应 AX 通知 | ✅ | ☐ |

## 12. 明确不做

无 Services 菜单、无朗读菜单、无补全 UI、无打开最近、无打印/导出、无自动更新、无分屏、无字数统计、无文件树、无插件、无语法高亮、无富文本。

## 13. 已知可接受差异（1.1.0）

| 编号 | 差异 | 1.0.2 | 1.1.0 |
| --- | --- | --- | --- |
| V1 | U+2028（⇧Return）行号 | TextKit paragraph gutter 不把 U+2028 计为一行 | 新行模型将 U+2028 作为正常行并显示行号 |
| V2 | 外部 RTF 拖入 | 可能带入字体/颜色（保存时丢失） | 统一按纯文本处理 |
| V3 | RTL 的 Option+拖拽 | 传 `visual: true`，按视觉顺序选择 | 按逻辑顺序选择 |

三项均写入本文件并由人工确认，不视为功能回归。

## 14. 测试与回归语料

### 现有 84 个测试（1.0.2）

- 核心/数据 28：`DocumentStoreTests` 9、`SessionModelsTests` 6、`SessionStoreTests` 13。
- 纯逻辑 25：`MultiCursorControllerTests` 18、`WindowGeometryTests` 7。
- 编辑器 31：`EditorIntegrationTests` 11、`EditorViewportTests` 5、`MultiCursorSelectionAdjusterTests` 10、`MultiCursorPerformanceTests` 5。

1.1.0 迁移策略见主计划：53 个直接保留、21 个改写、10 个 adjuster 用例 1:1 移植。

### 关键回归语料

- `abc\ndef` + 两整行选区 → 输入 `X`/`Y` → undo/redo 文本与光标。
- 60 行行首光标连续输入 → 两次 undo → 原文。
- 500 光标连续输入 → 一次 undo → 原文；选区数保持 500。
- 10 万行 + 500 稀疏光标 → 插入/undo → 文本与选区正确。
- 空文档、单字符、无尾随换行、尾随换行、连续空行、CR、CRLF、U+2028、U+2029。
- CJK、emoji、ZWJ、组合字符、surrogate pair。
- 长行 100 万字符滚动/编辑/命中。
- 中文输入法逐键、候选、取消、提交、切标签、退出。
- 查找/下一个/上一个/Replace All/撤销后高亮。
- 会话恢复：窗口/标签/滚动/选区/草稿；脏草稿恢复后仍脏、历史为空。
- 冻结期间 IME/拖放/查找替换/剪贴板不能修改文本。

### 测试隔离底线

- `SessionStore(rootURL:)` 注入临时目录；测试不调用无参初始化。
- `AppDelegate.detectTestMode()` 早退，不安装主菜单、不写真实会话。
- 新引擎/布局层不得在初始化、静态变量或启动路径读写真实 `~/Library/Application Support/Linea`。
- 保留 0700/0600 权限断言与草稿路径穿越防护测试。

## 15. Phase 5 自动化覆盖状态（2026-11-17）

上表的“对拍”列用于**人工实机验收**，由发布前在 App 中逐项勾选；本节的自动化覆盖不能替代它，
但可用于缩小人工验收范围、定位回归。

### 已由自动化测试覆盖

| 领域 | 覆盖项 | 测试位置 |
| --- | --- | --- |
| 文本/行模型 | 编辑、删除、批量应用、LF/CR/CRLF/U+2028/U+2029、CJK/emoji/ZWJ/surrogate、差分与 fuzz | `Packages/LineaCore/Tests`（129 个，全部通过） |
| 撤销/事务 | 一次动作一步、500 光标一步撤销、合并规则、冻结边界、历史上限 | `Packages/LineaCore/Tests` |
| 选区 | clamp、重叠合并、主选区、批量映射、adjuster 10 个用例移植 | `Packages/LineaCore/Tests` |
| 多光标命令 | M1–M3、M7–M11（词范围、取消数量上限、行边界、CR/U+2028） | `Packages/LineaCore/Tests/MultiCursorCommandsTests.swift` |
| 多光标交互 | M4–M6、M12（⌘+点击、⇧⌃+点击、Esc、⌥+点击） | `LineaTextViewEditingTests.swift` |
| 剪贴板 | C1–C3（纯文本粘贴、多选区换行连接、Cut 一个事务） | `LineaTextViewEditingTests.swift` |
| 拖放 | T1–T5（内部移动、外部插入、文件拖入打开、统一纯文本） | `LineaTextViewDragAndDropTests.swift`（11 个）、`TextFileDropTests.swift`（6 个） |
| 查找替换 | 匹配扫描（大小写、整词、不重叠、上限、Unicode）；查找栏交互与替换由人工验收 | `FindMatchScannerTests.swift`（9 个） |
| 输入法 | I1、I2、I5、I6（marked text、主选区组合、提交边界、组合中 Esc/⌘Z） | `LineaTextViewInputMethodTests.swift`（15 个） |
| 无障碍 | X1、X3（属性读取与通知） | `LineaTextViewAccessibilityTests.swift`（8 个） |
| 布局几何 | 行高、命中测试、可见行、长行分块、行号宽度 | `CoreTextLayoutEngineTests`、`LongLineLayoutTests`、`TextGeometryTests` |
| 字号缩放 | 10–24pt 夹取、偏好持久化、布局重建、顶部行不跳变、横向保持左边缘文本列、纯颜色切换不丢缓存 | `LineaTextViewTests`、`EditorFontZoomTests` |
| App 集成 | 初始加载、越界 clamp、两次输入两步撤销、冻结、重载清历史、视口尾部、空文档无横向滚动条、500 光标结构护栏 | `Tests/LineaTests`（已改写，待 CI 首次运行） |

总计：LineaCore 129 个、LineaTextUI 136 个、App XCTest 63 个（核心/数据 28 + 窗口几何 7 + 焦点 1 + 集成 12 + 视口 7 + 性能护栏 5 + 字号缩放 3）。
LineaCore/LineaTextUI 已在本机全部通过；App XCTest 因本机只有 CommandLineTools、没有 Xcode，
无法本地执行，由 `.github/workflows/test-ci.yml` 在 macOS runner 上运行。

### 仍需人工实机验收

- **窗口/标签/文件/会话**：W1–W10、F1–F7、D1–D4、S1–S5。这些逻辑未改动，但引擎切换后需确认保存、草稿、恢复、外部修改提示的实际流程；另外确认点击标签栏空白处能新建标签，且点击标签/加号不会误建。
- **外观**：A1–A9。字体、行高、tab、行号 gutter、浅色/深色外观需要目视对比 1.0.2。
- **查找栏与菜单**：P2–P3、P7–P9、C4。查找栏外观与对齐、Aa/wd 开关、S*/R→/R* 按钮、Replace All 后滚动位置与行号、右键菜单项需要目视确认。
- **真实输入路径**：I1–I4。中文/日文/韩文输入法、候选窗定位、听写、emoji picker 必须实机操作。
- **VoiceOver**：X1–X3。朗读、按行/字符导航、选择、撤销、查找。
- **真实拖拽手势**：T1、T2。跨应用拖拽与内部拖拽的鼠标手感、插入光标指示。
- **可接受差异**：V1–V3 由人工确认签字（U+2028 行号、RTF 拖入、RTL Option+拖拽）。
- **快捷键实测**：⌘D/⌃⌘G/⇧⌘L/⌘+点击/Esc/⌘Z 等在真实键盘事件下的分发（单元测试直接调用命令层）。

## 16. 编辑命令覆盖矩阵（Phase 3）

`LineaTextView` 通过 `NSStandardKeyBindingResponding`、`NSTextInputClient` 与 responder chain 接管下表命令。
未列出的命令一律视为“无入口、不实现”，避免键盘绑定静默失效却无人知晓；实现位于
`Packages/LineaTextUI/Sources/LineaTextUI/LineaTextView.swift`，纯移动逻辑位于 `TextInputController.swift`，
行为测试位于 `LineaTextViewEditingTests.swift`。

### 已实现

| 分类 | 命令 | 行为 |
| --- | --- | --- |
| 插入 | `insertText:replacementRange:`、`insertText:` | 所有选区一次事务替换；IME 提交同样走这里 |
| 插入 | `insertNewline:` | 插入 LF（`\n`） |
| 插入 | `insertLineBreak:` | ⇧Return，插入 U+2028 |
| 插入 | `insertParagraphSeparator:` | ⌃Return，插入 U+2029 |
| 插入 | `insertTab:` / `insertBacktab:` | 插入 HT / U+0019（与 1.0.2 一致，不改为空格） |
| 插入 | `insertNewlineIgnoringFieldEditor:`、`insertTabIgnoringFieldEditor:`、单双引号 ignoring substitution | 与普通插入相同 |
| 删除 | `deleteBackward:` / `deleteForward:` | 按 grapheme 删除；CRLF 作为整体跨过 |
| 删除 | `deleteBackwardByDecomposingPreviousCharacter:` | 与 `deleteBackward:` 相同 |
| 删除 | `deleteWordBackward:` / `deleteWordForward:` | Unicode 词边界删除 |
| 删除 | `deleteToBeginningOfLine:` / `deleteToEndOfLine:` | 行首删除从行首到光标；行尾删除从光标到换行符之前 |
| 删除 | `deleteToBeginningOfParagraph:` / `deleteToEndOfParagraph:` | 无软换行，与行命令相同 |
| 删除 | `delete:` | 删除所有非空选区 |
| 移动 | `moveLeft:`/`moveRight:`/`moveBackward:`/`moveForward:` | 按 grapheme 移动；有选区时只折叠 |
| 移动 | `moveWordLeft:`/`moveWordRight:`/`moveWordBackward:`/`moveWordForward:` | Unicode 词边界移动 |
| 移动 | `moveToBeginningOfLine:`/`moveToEndOfLine:`/`moveToLeftEndOfLine:`/`moveToRightEndOfLine:` | 行首/行尾（行尾停在终止符之前） |
| 移动 | `moveToBeginningOfParagraph:`/`moveToEndOfParagraph:` | 与行命令相同 |
| 移动 | `moveToBeginningOfDocument:`/`moveToEndOfDocument:` | 文档首/尾 |
| 移动 | `moveUp:`/`moveDown:`/`pageUp:`/`pageDown:` | 固定行高垂直移动，连续移动保留原始 x |
| 移动 | 以上命令的全部 `...AndModifySelection:` 变体 | Shift 扩展选区；保存锚点，反向移动可回缩 |
| 滚动 | `scrollPageUp:`/`PageDown:`/`LineUp:`/`LineDown:`/`scrollToBeginningOfDocument:`/`EndOfDocument:` | 只滚动视口，不移动光标 |
| 滚动 | `centerSelectionInVisibleArea:` | 把主光标滚入可见区域 |
| 选择 | `selectAll:` | 全选 |
| 选择 | `selectWord:` / `selectLine:` / `selectParagraph:` | 双击/三击背后的命令；段落等于行 |
| 选择 | `cancelOperation:` | Esc 折叠多光标为主选区；组合中不折叠 |
| 撤销 | `undo:` / `redo:` | 直接走 `EditorEngine` 历史，不依赖 `NSUndoManager` |
| 剪贴板 | `cut:` / `copy:` / `paste:` / `pasteAsPlainText:` | Copy 写 RTF + 纯文本；Cut = Copy + 一次删除事务；Paste 只读 `.string` |
| 鼠标 | `mouseDown:` / `mouseDragged:` / `mouseUp:` / `menuForEvent:` | 单击、拖拽、双击选词、三击选行、Shift 扩展、⌘+点击增减光标、⇧⌃+点击追加光标、边缘自动滚动；右键菜单与 1.0.2 一致 |

### 明确不做

| 命令 | 原因 |
| --- | --- |
| `changeCaseOfLetter:`、`uppercaseWord:`、`lowercaseWord:`、`capitalizeWord:` | 产品无菜单入口 |
| `transpose:`、`transposeWords:` | 产品无菜单入口 |
| `yank:` | Emacs 键位，产品无入口 |
| `indent:` | 无菜单入口；Tab 直接插入制表符 |
| `complete:`、`quickLookPreviewItems:` | 无补全 UI、无预览入口 |
| `insertContainerBreak:` | 无入口 |
| `NSServicesMenuRequestor` / 朗读菜单 | 产品无入口 |

### 已知测试边界

- 真实键位要经过 `NSTextInputContext` 分发，无法在无 App 事件循环的 SPM 测试中稳定模拟；
  命令层与插入层由直接调用覆盖，真实键入在 Phase 5 App 集成时人工验收。
- 鼠标事件中的坐标换算、拖拽自动滚动同样只在控制器/人工验收覆盖，单元测试直接调用 `select(at:)`。
