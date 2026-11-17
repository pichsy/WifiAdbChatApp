# 文件互传助手 2.4.0 发布说明

> **导航**：[文档中心](README.md) · [项目首页](../README.md) · [安装包](../release/README.md)

发布日期：2026-11-15

## 版本

| 平台 | 版本 | 安装包 |
| --- | --- | --- |
| macOS | **2.4.0**（build 15） | `文件互传助手-2.4.0.dmg` / `文件互传助手-2.4.0-macOS.zip` |
| Windows | **2.4.0** | `文件互传助手-2.4.0-安装包.exe` |
| Android | 2.2.0 | `文件互传助手-Android-2.2.0.apk` |
| iOS | 2.2.0 | `文件互传助手-iOS-2.2.0.ipa` |

## 文件窗口搜索与类型过滤

- 路径输入框正下方新增搜索栏和「全部 / 图片 / 视频」过滤选项；
- 搜索只针对**当前目录**，支持包含匹配和字符顺序模糊匹配，不递归子目录；
- 类型过滤与搜索叠加生效：例如输入 `screen` 并选择「图片」；
- 图片过滤只显示图片文件，视频过滤只显示视频文件；「全部」显示文件夹和所有文件；
- 过滤后自动清理不可见的选中项；没有匹配时显示「没有匹配的文件」；
- macOS 使用分段按钮，Windows 使用下拉选项；列表和网格模式共用同一套过滤结果。

## macOS 其他更新

包含 2.3.0 的文件浏览、多选、右键菜单、列表/网格、缩略图和批量操作能力；
本版仅新增当前目录搜索与类型过滤，协议和聊天缓存格式不变。

## Windows 其他更新

Windows 文件管理窗口已复刻 macOS：常用目录、路径跳转、精确路径定位、隐藏文件、
列表/网格、图片/GIF/视频缩略图、Ctrl/Shift 多选、右键新建/上传/刷新/复制路径/
下载/批量删除、/data/data 包名与 run-as 浏览；本版新增当前目录搜索与类型过滤。

## 安装与升级

- macOS：下载 `文件互传助手-2.4.0.dmg`，拖进「应用程序」覆盖旧版；
- Windows：下载 `文件互传助手-2.4.0-安装包.exe`，按向导选原安装目录覆盖安装（内置 .NET 8 运行时）；
- 升级只替换 App，不修改聊天记录、配对关系和接收文件。

## 校验值

| 文件 | SHA-256 |
| --- | --- |
| 文件互传助手-2.4.0.dmg | `1ce12ba67a9a7361f71500d392e1cc69c7aa1e163e76a540b0d9c10a7eff57a7` |
| 文件互传助手-2.4.0-macOS.zip | `6443777ef873b71b65d4dc8b9cb4dddadbc4b8111ea96af3777287127a3769ab` |
| 文件互传助手-2.4.0-安装包.exe | `b1b12596dddf6f6ae6b2a1431f6381f7b82b9a89c3b7c8fbc86f3b57aa0d1b61` |

## GitHub Release 附件名

GitHub 会剥离附件名里的中文，因此 Release 附件使用 ASCII 文件名；仓库 `release/` 内仍是中文名：

| GitHub Release 附件 | 仓库 release/ 文件 |
| --- | --- |
| WifiAdbChatApp-2.4.0.dmg | 文件互传助手-2.4.0.dmg |
| WifiAdbChatApp-2.4.0-macOS.zip | 文件互传助手-2.4.0-macOS.zip |
| WifiAdbChatApp-2.4.0-Windows-Setup.exe | 文件互传助手-2.4.0-安装包.exe |
| WifiAdbChatApp-Android-2.2.0.apk | 文件互传助手-Android-2.2.0.apk |
| WifiAdbChatApp-iOS-2.2.0-unsigned.ipa | 文件互传助手-iOS-2.2.0.ipa |
| WifiAdbChatApp-2.4.0-Windows-Install-Notes.md | 安装说明.md |
| SHA256SUMS.txt | 已按 GitHub 附件名重新生成 |

完整产品能力与核心技术见：[docs/product-and-tech.md](product-and-tech.md)
