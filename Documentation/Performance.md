# Linea 性能基线

本文件记录各版本的性能实测数据，作为 1.1.0 自建编辑/布局引擎的对比依据。所有数据为人工在本机 Release 构建上测得，不作为 CI 门禁。

## 测量条件

- 机器：Apple M2，24 GB，macOS 15.5（Darwin 24.5.0）
- 构建：Release（`swift build -c release`），基准宿主为临时 SPM 工程，直接复用 `Sources/Linea` 与 vendored STTextView
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

行号查询最初按 piece 内逐 code unit 扫描，100k 行实测约 5 µs/次；改为每 64 个 code unit
记录累计终止符数后降到 0.13 µs/次。piece 从 8192 缩到 2048 后，500 次批量编辑从约
5–6 ms 降到 2–3 ms，代价是 AVL 树节点增多，由压缩阈值兜底。

Debug 测试只保留宽松护栏（2 MB/500 edits < 250 ms、10 MB 单编辑 < 50 ms、
行号 < 20 µs/次），防止数量级退化，不作为性能结论。

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
