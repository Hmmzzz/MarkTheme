# Third-Party Notices

MarkTheme 不包含任何第三方源码副本。构建与运行时依赖以下外部组件，它们各自遵循自身的
许可证，并由构建工具链或越狱环境提供：

## Theos

MarkTheme 使用 [Theos](https://theos.dev/) 构建与打包。Theos 及其 `dm.pl` 打包工具不随
本项目分发。

## RootHide / libroot

跨 package scheme 的 `jbroot` 路径解析由越狱环境提供的 `libroothide`（RootHide）或 Theos
自动链接的 `libroot` 兼容实现完成。相关头文件与运行时库不随本项目分发。

参见 [RootHide Developer](https://github.com/roothide/Developer)。

## ElleKit

Runtime 的方法替换通过 [ElleKit](https://github.com/evelyneee/ellekit) 提供的
`CydiaSubstrate` 兼容接口完成。ElleKit 由越狱环境提供，作为软件包依赖声明，不随本项目
分发。

## 系统库

Manager 链接系统提供的 `libz`，以及 Apple 的 UIKit、Foundation、CoreGraphics、ImageIO、
QuartzCore 与 UniformTypeIdentifiers 框架。这些均为 iOS 系统组件，不随本项目分发。

## 主题资产

MarkTheme 不提供、销售、授权、审核或分发任何主题、图标或字体资产。用户导入的第三方主题
包及其中的图像内容，其版权与授权条款由相应作者持有；本项目的 GPL 许可不授予任何第三方
资产权利。
