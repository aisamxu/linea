# Linea

![Linea 图标](Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png)

Linea 是一个轻量、原生、多光标的 macOS 纯文本编辑器。窗口、菜单和标签栏使用 AppKit / SwiftUI 搭建，文本编辑基于 [STTextView](https://github.com/krzyzanowskim/STTextView) 2.4.1；项目内 vendored 了该版本并附带多光标性能补丁，说明见 [Vendor/STTextView/LINEA_PATCHES.md](Vendor/STTextView/LINEA_PATCHES.md)。

- 只支持 Apple 芯片（arm64），最低 macOS 14。
- 只处理 UTF-8 纯文本，不换行、横向滚动，跟随系统浅色/深色外观。
- 正常退出时保存会话；下次启动恢复窗口、标签、光标和滚动位置。
- 由 GitHub Actions 构建并做免费 ad-hoc 签名，未使用 Developer ID 公证，以 DMG 分发。

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

STTextView 2.4.1 已放在 `Vendor/STTextView`，`xcodegen generate` 会直接使用本地包；无需额外拉取该依赖。补丁不改变公开接口，升级方式见 [Vendor/STTextView/LINEA_PATCHES.md](Vendor/STTextView/LINEA_PATCHES.md)。

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

仓库不提交生成的 `Linea.xcodeproj`。CI 在 `macos-26`（arm64）上动态选择最新的 Xcode 26，生成工程、运行 XCTest、构建 Release arm64 `.app`、为完整 `.app` 做 ad-hoc 签名并验证签名、校验架构/版本与最低系统版本，然后生成包含 `/Applications` 符号链接的 DMG、挂载复验并输出 `.sha256`。CI 只在推送 `v*` 版本 tag 时运行。

## 版本与标签

当前正式版本为 **1.0.2**，版本号遵循语义化版本。`main` 已启用保护分支，禁止直接 push、强制 push 和删除分支，变更必须通过 PR 合并；日常 push 和 PR 不触发 CI，只有推送 `v*` tag 时才运行构建和测试。发布时在通过 CI 的 `main` 提交上创建 annotated tag `vMAJOR.MINOR.PATCH`（本次为 `v1.0.2`）并推送；随后使用该 tag 创建 GitHub Release，并附加 CI 构建的 DMG 与 SHA-256 文件。

## 下载 App

正式版本发布在 GitHub Releases 页面，附件是由 CI 构建并 ad-hoc 签名的 `Linea-1.0.2-macos-arm64.dmg` 和对应的 `Linea-1.0.2-macos-arm64.dmg.sha256`；也可以在 Actions 页面下载最近一次 CI artifact。

下载后建议先校验 SHA-256：

```bash
shasum -a 256 -c Linea-1.0.2-macos-arm64.dmg.sha256
```

安装步骤：

1. 双击 DMG，把 `Linea.app` 拖入 `/Applications`，然后推出磁盘映像。
2. macOS 14：首次打开如提示“无法验证开发者”，右键 App 选择“打开”。
3. macOS 15 及以上：先尝试打开；如被拦截，前往“系统设置 > 隐私与安全性”，在安全性区域选择“仍要打开”。新版系统不再保证右键“打开”能绕过。
4. 如仍被隔离，在终端执行 `xattr -dr com.apple.quarantine /Applications/Linea.app` 后重新打开。

`Linea.app` 使用免费 ad-hoc 签名，可以避免未签名 bundle 被误判为“已损坏”，但没有 Developer ID 签名和 Apple 公证，因此首次打开仍会被 Gatekeeper 拦截。不要对来源不明的应用绕过 Gatekeeper。

### 签名与 Gatekeeper

- 自签名证书不能解决升级确认问题：它能通过 `codesign --verify`，但 `spctl` 仍会拒绝，也不能提交 Apple 公证；浏览器下载的每个新版本都会重新带上 `com.apple.quarantine`。
- Gatekeeper 对隔离 App 只接受 Developer ID 签名 + Apple 公证。完全无提示的首次安装和后续升级需要付费 Apple Developer Program（$99/年）。
- 免费替代方案：通过终端 `curl`/`gh release download` 下载（通常不会附加 quarantine）、使用 Sparkle 自动更新，或每次手动执行 `xattr`。Linea 当前没有内置自动更新。
- 不要通过全局关闭 Gatekeeper 来规避提示。

## 已知限制

- 首版只支持 UTF-8；打开不是合法 UTF-8 的文件会报错。
- 不包含语法高亮、文件树、插件、项目工作区、自动换行或主题切换。
- 不恢复全屏、最小化状态；只恢复普通窗口 frame 和会话内容。
- 内置行号 gutter 在极大文档滚动时的性能取决于 STTextView；10 万行加载已纳入自动化测试。
- 中文输入法在单光标下使用 STTextView 原生实现；多光标组合输入依赖 TextKit 行为，仍需实机验证，若出现异常可先按 Esc 折叠为单光标输入。
- 崩溃、系统强制结束进程或断电不属于会话恢复保证范围。
- 仅使用免费 ad-hoc 签名，未使用 Developer ID 签名和 Apple 公证；首次打开仍需确认，不支持自动更新；不使用自签名证书（无法绕过 Gatekeeper）。

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
- [ ] DMG 可挂载，根目录包含 `Linea.app` 和指向 `/Applications` 的符号链接；`.app` 为 arm64、版本 1.0.2/build 3、最低系统版本 14.0，ad-hoc 签名校验通过，图标在 Dock/Finder 中正确显示。
- [ ] `.sha256` 校验通过。
- [ ] 从浏览器下载后首次打开不再显示“已损坏”，macOS 14 可通过右键“打开”，macOS 15+ 可通过“系统设置 > 隐私与安全性 > 仍要打开”。
- [ ] 重启后 `consumed.json` 和旧的 session 目录被清理。

## 许可证

Linea 以 **GPL-3.0** 发布，完整文本见 [LICENSE](LICENSE)。STTextView 同样采用 GPLv3（并提供商业授权），因此本项目的二进制分发需要同时提供对应源码。若需闭源分发，需要自行取得 STTextView 的商业授权。
