# MarkTheme 0.3.2

## 简体中文

本版专注性能优化，保持现有主题功能、图像效果和应用流程。

- 将图标遮罩与 overlay 合并为一次绘制，减少中间位图与重复绘制。
- 跨 App 复用公共装饰图片的解码结果，所有图标栅格缓存共用 32 MiB / 256 项留存预算。
- 按实际图标依赖判断是否清理系统图标缓存，合并相邻重复请求；保留失败重试和连续切换的正确性。
- 编译资源一次分组并复用有界选择计划，每次编译仍独立验证当前资产的摘要和 PNG 内容。

宿主微基准中，120–512 像素图标的 mask + overlay 合成耗时下降约 33%–38%。
这一结果只覆盖合成阶段，不代表真机整体提速比例，详见[性能记录](PERFORMANCE.md)。

验证：两种 package scheme 各通过 2,218 项 Foundation 断言；RootHide 与 rootless
安装包均通过结构、架构、链接、权限和进程白名单检查。维护者已测试 Runtime 205
测试包并反馈未发现问题。App build 为 27，Runtime build 为 205。

下载与越狱环境匹配的包：RootHide 使用 `iphoneos-arm64e`，conventional rootless
使用 `iphoneos-arm64`。升级后按 App 提示完成 Respring。

## English

This release focuses on performance while preserving existing theme features, rendered appearance,
and the apply workflow.

- Compose icon masks and overlays in one pass, eliminating an intermediate bitmap and repeated drawing.
- Reuse decoded decoration images across apps, with a shared 32 MiB / 256-entry raster-cache retention budget.
- Skip system icon-cache clears when icon dependencies are unchanged and coalesce adjacent duplicate requests,
  preserving retries and ordered state transitions.
- Group compiler resources once and reuse bounded selection plans while independently validating current
  asset hashes and PNG contents on every compilation.

Host microbenchmarks measured approximately 33%–38% less mask-and-overlay composition time for
120–512-pixel icons. This measures the composition stage only, not overall on-device performance.

Validation: 2,218 Foundation assertions pass for each package scheme. Both packages pass layout,
architecture, linking, permission, and process-filter checks. The maintainer reported no issues during
manual testing of the Runtime 205 test build. App build: 27; Runtime build: 205.

Choose `iphoneos-arm64e` for RootHide or `iphoneos-arm64` for conventional rootless, then follow the
app's Respring prompt after upgrading.
