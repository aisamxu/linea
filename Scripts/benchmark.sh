#!/usr/bin/env bash
# 本机 Release 性能基准：LineaTextUI 视图层（编辑 + 可见区域绘制 + 输入法 + 查找）。
#
# App 级数据（真实 EditorViewController、窗口、滚动、内存）需要临时 SPM 宿主，
# 结果记录在 Documentation/Performance.md 的 Phase 5 小节；本脚本用于快速回归。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v swift >/dev/null 2>&1; then
  echo "错误：swift 不可用" >&2
  exit 1
fi

swift test \
  -c release \
  --package-path "$ROOT_DIR/Packages/LineaTextUI" \
  --filter LineaTextViewPerformance
