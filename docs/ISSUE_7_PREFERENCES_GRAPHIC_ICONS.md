# Issue #7：设置与 AirDrop 图标兼容性

iOS 17.3.1 / 21D61 的 Preferences 除 `PKIconImageCache` 外，还包含
`ISIcon initWithType:` → `_IconServices_SwiftUI.AsyncIconImage` 路径。
新增 `preferences.graphic-icon-image` adapter 覆盖这条路径。
完整二进制地址、30 对资源名称和 ABI 来源保存在本地研究记录
`research/issue-7-preferences-graphic-icons-21D61.md`；按仓库约定，该研究目录不随源码分发。

## 实现

- 只在 `com.apple.Preferences` / `Preferences` 进程内安装；校验 IconServices
  类来源、方法编码及继承关系，再 hook `ISConcreteIcon` 的同步/异步取图方法。
- 只处理精确 `ISTypeIcon` 实例的 `com.apple.graphic-icon.*` 标识符。现有
  `PKIconImageCache` adapter 独立保留，两条路径共用主题 snapshot resolver。
- 查找顺序是完整原始标识符 → 21D61 二进制证明的 PK key → 已列明的历史 key。
  每一层先遍历自身的 scale/device 变体，再进入下一层；导入后的原始资源名不被改写。
  例如 `com.apple.graphic-icon.passwords` 回退到 `KeychainSync`，
  `com.apple.graphic-icon.passcode` 回退到 `Passcode`。
- renderer 读取原 `IFImage` 的实际 scale、pixelSize、minimumSize、iconSize 和 largest，
  要求 descriptor scale 一致。主题像素保持尺寸和缩放后，用已验证 ABI 的 `IFCacheImage`
  初始化器构造新图，再核对所有几何属性。placeholder、缺图、ABI 或几何不匹配均保留原图。
- 异步包装只接受实际 block signature 匹配的 `void(image)` / `void(image,error)`。
  它保持原回调队列与每次调用次数；nil 图和非 nil error 跳过转换，resolver 未命中返回原图。
  未知 block 形状及非 block 对象原样传给系统。仅标记本次新建的替代图，避免同步/异步嵌套重复转换。

## AirDrop 与资源名称

分享活动经过 proxy/configuration 包装后，旧身份解析只递归保留 App bundle identifier，
会丢弃没有 App bundle 的内层 `UIAirDropActivity` 图标身份。现在保留内层活动身份，
仍优先采用明确的 App bundle 或配置中的活动类名，并对循环引用和过深包装安全回退。
这修复了可由合成对象稳定复现的通用缺口；Issue 中的设备没有提供调用轨迹，不能据此断言
报告者必然经过了这条包装路径。

设置资源额外兼容三个已核对的历史名称，原始名称始终优先。重复 `.png.png` 扩展名现在
产生导入诊断，避免将无法匹配的名称报告为可用图标。规则见
[导入适配说明](IMPORT_ADAPTER_GUIDE.md)。

## 验证状态

[Foundation 合约测试](../tests/MTPreferencesGraphicIconContractTests.m) 已以 ARC、`-O2`、
`-Wall -Wextra -Werror` 编译运行，通过 51 条断言，覆盖真实 global/stack/heap block、
未知签名直通、nil/error/miss、原队列、回调次数，以及跨 autoreleasepool 的异步保活和释放。

2026-10-23 的完整 `./tests/run` 同时通过 roothide/rootless 两种宏配置的各 2434 条
Foundation 断言及静态、生命周期边界审计，包含新增的 149 条资源兼容断言、16 条分享身份断言
和 51 条回调契约断言。RootHide 与 rootless 包均构建并通过包审计，两个 Runtime 均包含
`arm64` 和 `arm64e`；0.3.3 的构建编号为 Runtime 206 / App 28。

这是主机代码验证。现有 `Settings-icon-class-metadata` 档案实际来自 iconservicesagent，
尚未捕获设置进程真实 completion signature，也未部署本次修复或验证设置列表的实机显示结果。
