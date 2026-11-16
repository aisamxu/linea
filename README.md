# Linea

![Linea 图标](Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png)

Linea 是一个轻量、原生、多光标的 macOS 纯文本编辑器。窗口、菜单和标签栏使用 AppKit / SwiftUI 搭建，文本编辑基于 [STTextView](https://github.com/krzyzanowskim/STTextView)。

- 只支持 Apple 芯片（arm64），最低 macOS 14。
- 只处理 UTF-8 纯文本，不换行、横向滚动，跟随系统浅色/深色外观。
- 正常退出时保存会话；下次启动恢复窗口、标签、光标和滚动位置。
- 未签名构建，由 GitHub Actions 产出一个可下载的 ZIP。

## 功能

- 多窗口、每窗口多标签；新建、打开多个文件、保存、另存为。
- 未命名文档显示为 `Untitled N`；有未保存修改的标签显示圆点。
- 行号、当前文档查找与替换、独立撤销栈。
- 跟随系统外观，纯文本编辑器关闭拼写检查、自动更正、智能引号和自动补全。
- 粘贴始终按纯文本处理，不会带入来源应用的字体和颜色。
- 保存前检测文件是否被其他程序修改；可覆盖或重新载入。
- 关闭未保存标签时提示保存、放弃或取消。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 新建标签 | ⌘N |
| 新建窗口 | ⇧⌘N |
| 打开文件 | ⌘O |
| 关闭标签 / 窗口 | ⌘W / ⇧⌘W |
| 保存 / 另存为 | ⌘S / ⇧⌘S |
| 查找 / 替换 | ⌘F / ⌥⌘F |
| 下一个 / 上一个匹配 | ⌘G / ⇧⌘G |
| 选择下一个相同文本 | ⌘D |
| 选择全部相同文本 | ⌃⌘G |
| 在选中行尾添加光标 | ⇧⌘L |
| 添加光标 | ⌘ + 点击文本 |
| 折叠多光标 | Esc |
| 撤销 / 重做 | ⌘Z / ⇧⌘Z |

纯光标时第一次按 ⌘D 会先选中当前单词，再按一次才开始逐个追加匹配项。原生 Shift+Control+点击仍然可用。查找操作会把多光标折叠为单个光标。删除、方向键等原生编辑命令会作用于所有光标；连续输入也会保持所有光标。

## 会话恢复

会话文件位于：

```text
~/Library/Application Support/Linea/
├── Session/
│   ├── current.json          # 最近一次正常退出写入的会话清单
│   ├── consumed.json         # 启动恢复时的消费标记
│   └── failed-*.json         # 无法读取时归档的旧清单
└── Sessions/
    └── <sessionID>/
        └── <tabID>.txt       # 仅修改过的文件和未命名文档的文本草稿
```

行为说明：

- **编辑期间不写任何恢复快照。** 只有正常退出时，才在后台写草稿和清单，写完后再结束应用。
- 退出写会话期间会暂时冻结编辑和标签操作，避免快照之后的新修改丢失；如果写入失败并取消退出，会恢复编辑。
- 已保存且未修改的文件只记录路径，不复制内容。
- 已修改的本地文件和未命名文档会写 UTF-8 文本草稿；恢复后仍保持未保存状态，不会自动覆盖磁盘文件。
- 启动时先把清单消费为 `consumed.json`，再恢复内容；即使恢复中途崩溃，也不会在下次启动重放旧会话。
- 恢复窗口 frame、窗口顺序、标签顺序、当前标签、所有选区和滚动位置。
- 会话目录权限为 `0700`，清单和草稿文件权限为 `0600`。草稿未加密，只保存在本机，不会上传。
- 崩溃、强制退出或断电后不保证恢复未保存内容。
- 没有窗口或标签时退出，会清理旧会话，避免下次意外恢复。

## 构建与测试

要求：macOS 14+、Apple 芯片、Xcode 26、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Linea.xcodeproj \
  -scheme Linea \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  build
open build/Build/Products/Debug/Linea.app
```

运行测试：

```bash
xcodebuild test \
  -project Linea.xcodeproj \
  -scheme Linea \
  -destination 'platform=macOS,arch=arm64'
```

仓库不提交生成的 `Linea.xcodeproj`。CI 在 `macos-26`（arm64）上动态选择最新的 Xcode 26，生成工程、运行 XCTest、构建 Release arm64 `.app`、校验架构与最低系统版本，并上传 `Linea.zip` artifact。PR、push 和手动触发都会运行 CI。

## 版本与标签

当前正式版本为 **1.0.0**，版本号遵循语义化版本。发布时在通过 CI 的 `main` 提交上创建 annotated tag `vMAJOR.MINOR.PATCH`（本次为 `v1.0.0`）并推送；tag 推送同样会触发 CI，随后使用该 tag 创建 GitHub Release，并附加 CI 构建的 `Linea.zip`。

## 下载未签名 App

正式版本发布在 GitHub Releases 页面，附件是由 CI 构建的 `Linea.zip`；也可以在 Actions 页面下载最近一次 CI artifact。`Linea.app` 没有开发者签名和公证，Gatekeeper 会拦截首次打开。对来源可信的构建，可以：

1. 解压 ZIP，把 `Linea.app` 放到 `/Applications` 或其他目录。
2. 尝试打开一次，然后前往“系统设置 > 隐私与安全性”，选择“仍要打开”。
3. 或者在终端执行 `xattr -dr com.apple.quarantine /path/to/Linea.app` 后重新打开。

不要对来源不明的应用绕过 Gatekeeper。

## 已知限制

- 首版只支持 UTF-8；打开不是合法 UTF-8 的文件会报错。
- 不包含语法高亮、文件树、插件、项目工作区、自动换行或主题切换。
- 不恢复全屏、最小化状态；只恢复普通窗口 frame 和会话内容。
- 内置行号 gutter 在极大文档滚动时的性能取决于 STTextView；10 万行加载已纳入自动化测试。
- 中文输入法在单光标下使用 STTextView 原生实现；多光标组合输入依赖 TextKit 行为，仍需实机验证，若出现异常可先按 Esc 折叠为单光标输入。
- 崩溃、系统强制结束进程或断电不属于会话恢复保证范围。
- 不支持代码签名、公证或自动更新。

## 验收清单

在 Apple 芯片 Mac 上使用 CI 产物逐项检查：

- [ ] 多个窗口、多个标签、当前标签、所有光标和滚动位置在正常退出/重启后恢复。
- [ ] 已修改文件和未命名文档恢复后仍为未保存状态，磁盘文件未被自动覆盖。
- [ ] 编辑期间 `Application Support/Linea/Session` 不产生新快照；正常退出后才写入。
- [ ] 关闭未保存标签的 Save / Don't Save / Cancel 三条路径。
- [ ] 文件被外部修改后，保存时出现 Overwrite / Reload / Cancel；文件缺失时可另存或重建。
- [ ] ⌘D、⌃⌘G、⇧⌘L、⌘+点击、Esc 和多光标连续输入、删除、方向键行为正确。
- [ ] 多光标编辑一次撤销能恢复整次输入；撤销/重做后光标仍保持多个。
- [ ] 查找、替换、下一个/上一个匹配可用。
- [ ] 单光标与多光标下的中文输入法组合输入可用，或已记录限制。
- [ ] 约 10 MB / 10 万行文本可打开、滚动、编辑、退出保存和恢复；记录行号与滚动响应。
- [ ] ZIP 内 `.app` 为 arm64、最低系统版本 14.0，图标在 Dock/Finder 中正确显示。
- [ ] 重启后 `consumed.json` 和旧的 session 目录被清理。

## 许可证

Linea 以 **GPL-3.0** 发布，完整文本见 [LICENSE](LICENSE)。STTextView 同样采用 GPLv3（并提供商业授权），因此本项目的二进制分发需要同时提供对应源码。若需闭源分发，需要自行取得 STTextView 的商业授权。
