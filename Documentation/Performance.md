# Linea 性能基线

本文件记录各版本的性能实测数据，作为 1.1.0 自建编辑/布局引擎的对比依据。所有数据为人工在本机 Release 构建上测得，不作为 CI 门禁。

## 测量条件

- 机器：Apple M2，24 GB，macOS 15.5（Darwin 24.5.0）
- 构建：Release（`swift build -c release`），基准宿主为临时 SPM 工程，直接复用 `Sources/Linea` 与当时的 vendored STTextView（已删除，补丁说明见 [History/STTextViewPatches.md](History/STTextViewPatches.md)）
- 窗口：900×600，字体 13pt 等宽系统字体，行高 1.2，tab 间隔 28pt
- 计时范围：输入事件入口到 `layoutSubtreeIfNeeded()` 完成，包含布局与绘制准备，不含屏幕合成
- 场景：每行一个零宽光标，`insertText` + 选区同步 + 布局
- 滚动：在 10 万行文档中从上到下取 120 个位置，统计 `scroll + reflect + layoutSubtreeIfNeeded` 每帧耗时
- 内存：`task_vm_info.phys_footprint`，比较打开 10 万行文档前后的增量

## 1.0.2 基线（2026-11-17）

### 编辑

| 场景 | 插入 | 撤销 | 重做 |
| --- | ---: | ---: | ---: |
| 单光标 | 6.6 ms | 2.8 ms | 2.6 ms |
| 60 光标 | 25.0–31.6 ms | 14.2–19.3 ms | 15.8–17.8 ms |
| 500 光标（12 次中位数） | 76.4 ms | 58.0 ms | 64.0 ms |
| 10 万行 + 500 稀疏光标 | 889 ms | 699 ms | — |

500 光标单次插入波动较大（49–82 ms），主要受 TextKit 布局失效区域与插入点视图重建影响。

### 打开、滚动与内存

| 场景 | 1.0.2 |
| --- | ---: |
| 打开 10 万行到首帧布局完成 | 44 ms |
| 10 万行滚动，120 帧平均 | 22.3 ms/帧（约 45 fps） |
| 10 万行滚动，最差帧 | 45.8 ms |
| 100k 行（3.2 MB UTF-16）打开后 footprint 增量 | 9.27 MB（约文本字节 × 2.9） |

滚动数据包含 STTextView/TextKit 的可视行布局与行号 gutter 更新；当前实现已经能打开大文件，但滚动帧率明显低于 60 fps，这是新布局引擎要解决的核心问题之一。

### 数据来源

- 编辑、稀疏光标：`/tmp/linea-bench`（临时基准工程，不属于仓库）
- 打开/滚动/内存：同一工程的 `--baseline` 模式，函数 `testOpenHundredThousandLines`、`testScrollHundredThousandLines`、`testMemoryHundredThousandLines`
- 历史数据与补丁说明见 [`Documentation/History/STTextViewPatches.md`](History/STTextViewPatches.md)（Phase 5 删除 Vendor 时归档）

## LineaCore Phase 1（2026-11-17）

### 测量条件

- 机器同上；`swift test -c release --package-path Packages/LineaCore`
- 只测文本内核，不含布局/绘制；每组取 3 次最小值
- 性能测试位于 `Packages/LineaCore/Tests/LineaCoreTests/LineaCorePerformanceTests.swift`
- 结构参数：piece 目标 2048 UTF-16 code unit；行号采样间隔 64 code unit；piece 数上限 `max(2048, length / 1024)`

### 实测

| 场景 | 实测 | 目标 |
| --- | ---: | ---: |
| 2 MB 文本 + 500 个分散插入 | 2.2–3.9 ms | ≤ 5 ms |
| 10 MB 文本 + 单次插入 | 0.010–0.017 ms | ≤ 2 ms |
| 10 万行 `lineNumber(at:)` | 0.12–0.13 µs/次 | ≤ 1 µs/次 |
| 10 万行 + 500 光标插入 + 撤销（核心） | 2.6–3.6 ms | — |
| 1 MB UTF-16 区间 `substring` | 1.2–1.6 ms | — |

行号查询最初按 piece 内逐 code unit 扫描，100k 行实测约 5 µs/次；改为每 64 个 code unit
记录累计终止符数后降到 0.13 µs/次。piece 从 8192 缩到 2048 后，500 次批量编辑从约
5–6 ms 降到 2–3 ms，代价是 AVL 树节点增多，由压缩阈值兜底。

`String(decoding: [UInt16], as: UTF16.self)` 在本机百万字符实测约 55–65 ms，
是超长行布局的首个瓶颈；改为 `String(utf16CodeUnits:count:)` 后降到约 0.6 ms。
同时新增 `utf16Units(in:)`，让布局层可以按块读取 UTF-16，避免为百万字符单行
构造整行 `String`。

Debug 测试只保留宽松护栏（2 MB/500 edits < 250 ms、10 MB 单编辑 < 50 ms、
行号 < 20 µs/次、1 MB substring < 100 ms），防止数量级退化，不作为性能结论。

## LineaTextUI Phase 2（2026-11-17）

### 测量条件

- 机器同上；`swift test -c release --package-path Packages/LineaTextUI`
- 只测布局 + 直接绘制，不启动完整 App、不含窗口合成
- 绘制目标为 900×600 的离屏位图；滚动测试连续绘制 60 帧，每帧前进约 20 行
- 性能测试位于 `Packages/LineaTextUI/Tests/LineaTextUITests/LongLineLayoutTests.swift`
- 长行参数：超过 32K UTF-16 的行分块；每块 4K UTF-16；可见块才创建 `CTLine`

### 实测

| 场景 | 实测 | Phase 2 目标 |
| --- | ---: | ---: |
| 打开 10 万行并完成首帧（引擎 + 可见行布局 + 绘制准备） | 2.5–2.7 ms | ≤ 100 ms |
| 10 万行滚动 60 帧，平均 | 0.21–0.24 ms/帧 | ≤ 8 ms |
| 10 万行滚动 60 帧，最差 | 1.4–1.5 ms | ≤ 8 ms |
| 100 万 UTF-16 单行首次布局 + 行尾光标 + 命中测试 | 9.4–10.3 ms | 单帧 ≤ 16 ms |
| 100 万字符单行，仅绘制首屏 900pt | 只生成 1 个可见块 | 不排版整行 |
| 10 万行全选后重绘 | 只排版可见的 ≤ 45 行 | 不遍历全文 |

1M 单行首次布局包含：读取 UTF-16 units（约 0.2 ms）、切块与前缀估算（约 3 ms）、
行尾光标与命中测试（约 0.3–3 ms）。只绘制可见块，整行 `CTLine` 和整行 `String`
均未构造。

内存 gate（文本字节 × 3）尚未自动化：当前结构上只保留 piece 存储、超长行 UTF-16
units、可见块 `CTLine` 和按行 CTLine 缓存（上限 2048 行）；大 frame 的窗口级
footprint 需要在 Phase 5 用完整 App 实测。

## LineaTextUI Phase 3（2026-11-17）

### 测量条件

- 机器同上；`swift test -c release --package-path Packages/LineaTextUI --filter LineaTextViewPerformance`
- 场景为 `LineaTextView.insertText("x")`：所有光标一次事务，随后绘制一帧 900×600 可见区域（含文本、选区、光标）
- 绘制前先预热可见行布局缓存，模拟连续输入时的稳定状态
- `core` 为同文本、同选区的独立 `EditorEngine` 纯插入耗时，不含视图；`edit` 为视图路径（引擎 apply + 选区映射 + 布局失效 + frame 更新 + scroll-to-caret）；`draw` 为可见区域一位图绘制
- 每组单次测量，未取中位数；数据用于确认数量级，Phase 5 再按 best-of-5 记录
- 性能测试位于 `Packages/LineaTextUI/Tests/LineaTextUITests/LineaTextViewPerformanceTests.swift`

### 实测

| 场景 | core | edit | draw | 总计 | Phase 3 目标 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 单光标（1 万行文档） | 0.015 ms | 0.066 ms | 0.210 ms | 0.28 ms | ≤ 16 ms |
| 60 光标 | 0.084 ms | 0.102 ms | 0.222 ms | 0.32 ms | ≤ 16 ms |
| 500 光标 | 1.31 ms | 1.32 ms | 0.213 ms | 1.53 ms | ≤ 33 ms |
| 500 光标 undo | — | — | — | 0.91 ms | ≤ 33 ms |
| 10 万行 + 500 稀疏光标 insert | — | 1.68 ms | — | 1.68 ms | ≤ 100 ms |
| 10 万行 + 500 稀疏光标 undo | — | — | — | 0.93 ms | ≤ 100 ms |

视图路径相对纯引擎只增加固定开销：单光标多出约 0.05 ms（frame 更新、滚动、失效），
500 光标多出约 0.01 ms（批量选区已由引擎一次算好，视图不逐个处理）。
绘制只处理可见行，与文档总行数无关，因此 1 万行与 1000 行文档的 draw 基本持平。
500 光标的核心耗时为选区批量映射与 500 个 piece 编辑，仍是当前最大项，距离 16 ms
的 Phase 6 最终目标有约 10 倍余量。

Debug 测试只保留数量级护栏（单/60 光标 < 300 ms、500 光标 < 2 s、
10 万行 + 500 光标 insert/undo < 5 s），不作为性能结论。

## LineaTextUI Phase 4 输入法（2026-11-17）

### 测量条件

- 机器同上；`swift test -c release --package-path Packages/LineaTextUI --filter LineaTextViewPerformance`
- 1 万行文档，光标位于第 4000 行附近；模拟拼音逐键更新，marked text 从 1 个字符增长到 10 个字符
- 每次 `setMarkedText` 后绘制一帧 900×600 可见区域，包含组合虚拟行、下划线与组合光标
- 性能测试位于 `LineaTextViewPerformanceTests.inputMethodUpdateAndDrawWithinFrameBudget`

### 实测

| 场景 | 实测 | Phase 4 目标 |
| --- | ---: | ---: |
| 输入法逐键更新 + 重绘（10 次平均） | 1.67 ms/次 | < 16 ms |

组合渲染不改 buffer，每帧只临时拼接「行前缀 + marked text + 行后缀」并排版一行；
绘制路径只多画 marked text、下划线和组合光标，不触碰其他行。

## LineaTextUI Phase 4 查找（2026-11-17）

### 测量条件

- 机器同上；`swift test -c release --package-path Packages/LineaTextUI --filter LineaTextViewPerformance`
- 5 万行 × 100 UTF-16 code unit = 500 万 code unit（UTF-16 字节 10 MB）
- 计时范围：`LineaTextView.string` 构建全文缓存 + `NSString.range(of:options:.backwards)` 一次全文搜索（未命中）
- 只测单次冷启动，未取中位数；用于确认打开查找栏时主线程开销在 Phase 5 目标内
- 性能测试位于 `LineaTextViewPerformanceTests.finderBuildsTenMegabyteStringAndSearchesWithinBudget`

### 实测

| 场景 | 实测 | Phase 4 目标 |
| --- | ---: | ---: |
| 10 MB 文档构建全文字符串 + 一次搜索 | 23.6 ms | 主线程无 > 100 ms 卡顿 |

`NSTextFinderClient.string` 被查找栏读取时按需构建全文缓存，首次构建之后随编辑增量维护；
本次耗时同时包含 `PieceTreeBuffer` 按 UTF-16 拼接全文与 NSString 搜索，仍低于 100 ms 门槛。
Debug 测试只保留 3 s 数量级护栏。

## 1.1.0 目标（Phase 5 验收）

本机 Release，900×600，中位数（best-of-5）：

| 场景 | 目标 |
| --- | ---: |
| 单光标按键（含重绘） | ≤ 8 ms |
| 单光标连续输入 p95 | ≤ 16 ms |
| 60 光标按键 | ≤ 16 ms |
| 500 光标按键 | ≤ 33 ms |
| 500 光标 undo | ≤ 33 ms |
| 10 万行 + 500 稀疏光标插入/undo | ≤ 100 ms |
| 打开 10 万行 | ≤ 100 ms |
| 滚动 10 万行 | 稳定 60 fps 以上，目标 120 fps |
| 100 万 UTF-16 单行滚动/命中 | 单帧 ≤ 16 ms（Phase 2 spike 后确认） |
| 2 MB + 500 edits 核心应用 | ≤ 5 ms |
| 内存 footprint | UTF-16 文本字节 × 3 以内（original/add + 全文缓存 + 历史） |
| 打开查找栏并增量搜索 10 MB 文档 | 主线程无 > 100 ms 卡顿 |

Phase 6 打磨后的最终目标：

- 单光标 ≤ 5 ms
- 60 光标 ≤ 8 ms
- 500 光标 ≤ 16 ms
- 10 万行 + 500 光标 ≤ 50 ms
- 输入到可见更新 ≤ 1 帧

## 记录规则

- 每个 Phase 结束时用同一基准流程补测并追加到本文件，保留旧数据。
- 每次计时拆分为 `core.apply` → `selection update` → `layout` → `draw` 四段；1.0.2 无法拆分，只记录总耗时。
- Debug XCTest 只做宽松 smoke 护栏，不作为性能结论。
- 与 Sublime Text 的同机对比为人工记录，不进入 CI。
