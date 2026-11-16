#!/usr/bin/env bash
# 从项目根目录的品牌源图生成 macOS AppIcon 所需的全部尺寸。
# 源图是唯一事实来源；本脚本可重复执行，生成结果会提交到仓库。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/linea-b2-l-caret.png"
DEST="$ROOT_DIR/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "$SOURCE" ]]; then
  echo "错误：找不到图标源文件 $SOURCE" >&2
  exit 1
fi

if ! command -v sips >/dev/null 2>&1; then
  echo "错误：sips 不可用" >&2
  exit 1
fi

mkdir -p "$DEST"

generate() {
  local pixels="$1"
  local filename="$2"
  # 使用 sips 等比缩放并统一输出为 PNG，保留源图透明通道
  sips -s format png -z "$pixels" "$pixels" "$SOURCE" --out "$DEST/$filename" >/dev/null
}

generate 16   "icon_16x16.png"
generate 32   "icon_16x16@2x.png"
generate 32   "icon_32x32.png"
generate 64   "icon_32x32@2x.png"
generate 128  "icon_128x128.png"
generate 256  "icon_128x128@2x.png"
generate 256  "icon_256x256.png"
generate 512  "icon_256x256@2x.png"
generate 512  "icon_512x512.png"
generate 1024 "icon_512x512@2x.png"

cat > "$DEST/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo "已生成 AppIcon：$DEST"
