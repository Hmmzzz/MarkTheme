# MarkTheme 0.3.3

## 简体中文

本版修复 iOS 17.3.1 中设置内部图标与分享页 AirDrop 图标的主题兼容路径，
对应 [Issue #7](https://github.com/Hmmzzz/MarkTheme/issues/7)。

- 支持设置页面的 GraphicIcon 取图路径，新增 30 组经过系统二进制核对的名称映射，
  让现有主题的 `WiFi`、`General` 等资源可用于对应的新图标请求。
- 优先使用当前名称，再回退到已确认的旧主题名称；区分密码列表的 `KeychainSync`
  与设备密码的 `Passcode`，缺少适用资源时保留系统图标。
- 修复分享活动经代理包装后丢失原始身份的问题，使 AirDrop 等没有应用 Bundle ID
  的活动仍可找到对应的主题图标。
- 对重复 `.png` 扩展名给出导入诊断，避免将无法命中的文件显示为可用资源。

验证：两种 package scheme 各通过 2,434 项 Foundation 断言；RootHide 与 rootless
均通过构建和安装包检查。App build 为 28，Runtime build 为 206。
本次修复尚未验证真机上的实际显示效果。

下载与越狱环境匹配的包：RootHide 使用 `iphoneos-arm64e`，conventional rootless
使用 `iphoneos-arm64`。升级后按 App 提示完成 Respring。

## English

This release fixes theme compatibility paths for icons inside Settings and the AirDrop icon in
share sheets on iOS 17.3.1, addressing [Issue #7](https://github.com/Hmmzzz/MarkTheme/issues/7).

- Support the Settings GraphicIcon image path with 30 name mappings verified against the system
  binary, allowing existing theme resources such as `WiFi` and `General` to serve matching requests.
- Prefer current resource names before confirmed legacy names. Keep `KeychainSync` for the password
  list distinct from `Passcode` for the device passcode, and retain system icons when no resource matches.
- Preserve the original activity identity through share-sheet wrappers so AirDrop and other activities
  without an application bundle identifier can resolve their themed icons.
- Report repeated `.png` extensions during import instead of listing unusable filenames as available resources.

Validation: 2,434 Foundation assertions pass for each package scheme. Both RootHide and rootless
builds and package checks pass. App build: 28; Runtime build: 206.
The visual results of this fix have not yet been verified on a physical device.

Choose `iphoneos-arm64e` for RootHide or `iphoneos-arm64` for conventional rootless, then follow the
app's Respring prompt after upgrading.
