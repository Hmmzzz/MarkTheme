# MarkTheme 导入适配与资源目录扩展指南

本文档定义 MarkTheme 如何把 SnowBoard、IconBundles、WinterBoard 等外部主题格式适配为自己的主题规格。它同时是新增资源类型、兼容规则和测试场景时的实现检查清单。

## 1. 核心原则

外部目录是输入提示，不是 MarkTheme 的持久化契约。完整流程必须遵守：

1. 审计 ZIP、归档或目录，拒绝路径穿越、特殊节点、规范化碰撞和超限输入。
2. 根据目录、Bundle ID、文件名和文件签名识别资源语义。
3. 由 importer 生成 `MTResourceKey`，完成冲突优先级和 module 配置处理。
4. 完成 PNG 结构与像素解码验证。
5. 把存活资源转换为 MarkTheme 标准路径。
6. 在 Library 原子事务中同时写入摘要对象和真实 `resources/` 主题树。
7. 发布前及重新加载时，验证精确目录树、大小与 SHA-256。

不得因为外部文件夹名称看起来正确而跳过内容校验，也不得因为外部文件夹名称错误而直接丢弃具有高置信语义的资源。

## 2. 分类置信度

分类按以下优先级执行。

### 2.1 已知资源目录

以下目录在任意包装深度、任意大小写下都可以作为高置信锚点：

- `IconBundles/`
- `Bundles/`
- `UIImages/`
- `AnemoneEffects/`

锚点之前的下载目录、压缩包目录或无关包装目录不携带资源语义，应当剥离。

### 2.2 已知 Bundle ID

即使外层目录不叫 `Bundles`，路径中出现下列已知 Bundle ID 时，也可恢复对应的 `Bundles/<id>/` 逻辑路径：

- `com.apple.springboard`
- `com.apple.TelephonyUI`
- `com.apple.UI`
- `com.apple.UIKit`
- `com.apple.mobileicons.framework`
- `MTUIResourceBundleIsSupported()` 接纳的 Settings 与 ShareSheet Bundle

普通 App 的 Bundle 目录只有在名称包含 `.` 且文件名属于确认过的 Bundle icon 形式时才可自动恢复。这个限制用于避免把 `Artwork/icon.png` 之类普通图片误判成 App 图标。

### 2.3 具有唯一语义的文件名

目录错误或缺失时，以下文件名族可以直接推断：

- 含点号 Bundle ID 的 IconBundles 图标名，例如 `com.example.app@3x.png`
- 全局 `icon_mask.png`、`icon_pattern.png`、`icon_folder.png`、`icon_folder_light.png`
- Clock 部件名
- Badge 与 Folder 背景名
- 已确认的 Status Bar subject
- AppIconMask / AppIconPattern
- iPhone / iPad Shadow 与 Overlay

文件必须先有 PNG signature；通过分类后仍必须进入正常 importer 和完整图片验证。

### 2.4 有歧义的名称

脱离 Bundle 或资源族上下文时，不得猜测以下名称：

- `WiFi@3x.png`
- `1@3x.png`
- `icon.png`
- `background.png`

如果未来要接纳这类名称，必须增加一个新的、可验证的上下文信号，而不能扩大通用文件名规则。

## 3. MarkTheme 标准资源目录

`MTResourceKey` 是语义权威；目录是稳定、可读的实体表示。当前资源映射如下：

| Module / Surface | 标准目录 |
|---|---|
| `icons.static` | 优先保留 `IconBundles/` 或 `Bundles/<bundle-id>/` |
| `icons.clock` | 优先保留清晰的 SpringBoard `Bundles/` 名称，否则 `Clock/` |
| `icons.calendar` | 没有独立图片目录；使用 Calendar 静态图标和 manifest 配置 |
| `badges` | `Badges/` |
| `ui.dialer` | `Dialer/` |
| `folders` | `Folders/` |
| `icons.mask` | `IconEffects/Masks/` |
| `icons.overlay` | `IconEffects/Overlays/` |
| `icons.shadow` | `IconEffects/Shadows/` |
| `ui.statusbar` | `StatusBar/` |
| `ui.resources` + `preferences.icon` | `Settings/` |
| `ui.resources` + `share.activity` | `ShareSheet/` |
| 尚未显式分类的新 module | `Modules/<module-id>/`，仅作为防丢失兜底 |

多 `.theme` 组件保留为：

```text
Components/<原组件名>.theme/<标准资源目录>/...
```

新增正式 module 时，不应长期依赖 `Modules/<module-id>/` 兜底；必须为用户可理解的资源族补充明确目录。

## 4. 名称保留规则

MarkTheme 自有标准不意味着全部改名。满足以下条件的既有名称应保留：

- 能稳定表达 Bundle ID、资源角色、scale 或设备 trait；
- 不包含路径分隔符、控制字符或不安全组件；
- NFC 规范化和大小写折叠后没有碰撞；
- 不依赖已经废弃的运行时实现才能理解。

优先保留 `IconBundles`、`Bundles/<bundle-id>`、Clock 部件、Badge 名称和作者提供的 `.theme` 组件名。`UIImages`、`AnemoneEffects` 这类含糊或引擎绑定的目录在持久化时转换为 MarkTheme 资源族。

## 5. 重复与冲突

- 同一推断路径、相同 SHA-256：只保留一份逻辑输入。
- 同一推断路径、不同内容：将后续来源放入确定性的 `Components/<name>.theme/`，再由正常资源优先级解决。
- 两个最终资源仍命中同一 MarkTheme 路径：保留排序靠前的清晰名称，其余文件在扩展名前追加 12 位稳定摘要。
- 不允许静默覆盖。
- capability 来自多个兼容 importer 时，构造 manifest 前必须确定性去重。

## 6. Library 契约

当前 Library 快照的顶层结构为：

```text
<snapshot>/
├── assets/          # 以 SHA-256 命名的去重对象，供现有 Runtime 使用
├── resources/       # 按 MarkTheme 标准路径组织的真实主题文件
├── manifest.json
└── revision.json
```

`resources/` 不是符号链接或仅含映射的目录。每个文件都由已验证的 staging 对象 clone 或复制产生，并在发布前重新读取计算 SHA-256。

正式加载必须：

- 枚举并比对精确目录树；
- 拒绝未知节点、符号链接、所有者或权限异常；
- 核对每个资源的大小和 digest；
- 支持取消；
- 在清理与恢复中使用有深度和节点数上限的安全递归删除。

旧 formal 快照可能没有 `resources/`，必须继续可读。新布局通过 importer version offset 区分，当前 offset 为 `100`。

## 7. 新增资源类型的实现清单

新增 module、surface 或外部命名规则时，必须逐项完成：

1. 在 module contract 中定义稳定的 module、surface、subject、variant、scale 和 trait。
2. 在对应 importer 中只接纳有证据支持的命名形式。
3. 判断文件名能否脱离目录独立识别；不能时保留必要的 Bundle 或目录上下文。
4. 在 `MTThemeSourceRoot` 增加高置信恢复规则，避免扩大歧义匹配。
5. 在 `MTMarkThemeStandardRelativePath()` 增加明确的标准目录。
6. 为组件选择、依赖资源和冲突优先级补充规则。
7. 确认 capability 不会因多来源发现而重复。
8. 增加端到端 ZIP 测试，并验证实际 `resources/` 文件。
9. 重新加载 Library 当前快照，证明目录不是只在 Import Review 阶段有效。
10. 更新本文档和面向用户的兼容说明。

## 8. 必测兼容矩阵

每个已支持资源族至少测试：

- 原生标准目录；
- 目录大小写变化；
- 单层与多层包装；
- 错误外层目录；
- 无资源目录但文件名具有唯一语义；
- 已知 Bundle ID 位于非标准路径；
- 相同内容重复；
- 同名不同内容冲突；
- 伪 PNG；
- 有歧义文件名；
- `__MACOSX` / AppleDouble 等包装数据；
- prepare、commit、实体目录 digest 和 authoritative reload。

当前综合矩阵入口是 `MTTestSemanticLayoutCompatibilityMatrix()`。任何新 module 未进入该矩阵，都不应宣称完成了全链路导入兼容。

## 9. 关键实现位置

- 输入根与智能分类：`workflow/MTThemeSourceRoot.m`
- IconBundles / Bundle 图标规则：`importers/MTIconBundlesImporter.m`
- Legacy Badge、Status Bar、Mask、Shadow、Overlay 规则：`importers/MTLegacyThemeResourcesImporter.m`
- UI Bundle 规则：`importers/MTUIResourcesImporter.m`
- MarkTheme 标准路径：`workflow/MTThemeImport.m`
- Library 实体资源树与校验：`library/MTThemeLibraryTransaction.m`
- Library 安全清理：`library/MTThemeLibraryFilesystem.m`
- 综合兼容矩阵：`tests/main.m`
