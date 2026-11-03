# 文件互传助手 · 局域网互传（macOS / Windows / 移动端规划）

一套局域网直连的小工具，按端分成独立目录，互不交叉：

- **macOS 端**（[`macos/`](macos/)）：SwiftUI 原生 App。既能用 adb 把文字/文件送到手机，也能和电脑像微信一样聊天互传。
- **Windows 端**（[`windows/`](windows/)）：Avalonia + .NET 8 桌面端，和 macOS 端同一套协议、同样的聊天界面。
- **移动端**（[`mobile/`](mobile/)）：规划中，目前只有 README。

电脑之间**直连传输，不经过服务器**：UDP 52730 发现设备，6 位配对码配对，之后用 TCP 收发
文字和文件；聊天记录、配对关系本地持久化。macOS 端会把已配对设备记成好友常驻左侧列表，
对方离线时保留并自动重连，也提供手动重连。

> 改名说明：App 的显示名称统一为「文件互传助手」。内部 Bundle ID、可执行文件名和协议广播
> 标识仍是 `ADBType` / `ADBTypeLink`，不影响与旧版本或其他端互传，已有配对和聊天记录继续有效。

---

## 仓库结构

```
.
├─ macos/                 macOS 端（源码、图标、打包脚本、联调工具）
│  ├─ Sources/            SwiftUI App 源码
│  ├─ Resources/          Info.plist、图标、手机剪贴板 dex
│  ├─ packaging/          分发用安装说明与安装脚本
│  ├─ tests/              协议探针 / 界面离屏渲染 / 互通测试
│  ├─ build.sh            编译出「文件互传助手.app」
│  └─ package.sh          生成 dmg / zip
├─ windows/               Windows 端（Avalonia + .NET 8）
│  ├─ src/                Core、App、SmokeTest、TestPeer
│  ├─ build.ps1           构建 + 发布
│  └─ README.md           构建、使用、防火墙说明
├─ mobile/                移动端（规划中，只有 README）
├─ docs/
│  ├─ LAN-transfer-spec.md   三端共用的协议 + 界面规格
│  └─ screenshots/           界面预览图
├─ README.md
└─ .gitignore
```

## 各端状态

| 端 | 状态 | 说明 |
| --- | --- | --- |
| macOS | ✅ 可运行 | 手机输入 / 手机文件传输 / 电脑聊天互传；已配对好友列表 + 别名 + 每设备独立会话 + 自动/手动重连 + 发送进度/取消 + 消息右键菜单/文件缺失删除线；已打包 1.6（dmg + zip） |
| Windows | ✅ 代码完成，待 Windows 真机验证 | macOS 上编译 0 warning、冒烟测试 37/37 + 9/9、与 macOS 端双向真实收发通过 |
| Mobile | 📝 规划中 | 协议与一期范围见 [`mobile/README.md`](mobile/README.md) |

## 界面预览

| macOS「电脑设备」页（深色） | Windows 端（深色） |
| --- | --- |
| ![macOS](docs/screenshots/macos-chat-dark.png) | ![Windows](docs/screenshots/windows-chat-dark.png) |

浅色版：[macOS](docs/screenshots/macos-chat-light.png) · [Windows](docs/screenshots/windows-chat-light.png)

## 快速开始

**macOS**

```bash
cd macos
./build.sh          # 需要 Xcode 命令行工具；默认 arm64 + x86_64
open 文件互传助手.app
```

**Windows**（在 Windows 上执行）

```powershell
powershell -ExecutionPolicy Bypass -File windows\build.ps1
```

**移动端**：见 [`mobile/README.md`](mobile/README.md)（暂未实现）。

## 文档

- 局域网协议 + 双端界面规格：[`docs/LAN-transfer-spec.md`](docs/LAN-transfer-spec.md)
- macOS 端构建、打包、使用、限制：[`macos/README.md`](macos/README.md)
- Windows 端构建、使用、防火墙：[`windows/README.md`](windows/README.md)
- Windows 真机测试清单：[`windows/TESTING.md`](windows/TESTING.md)
- macOS 联调工具（探针 / Python 对端 / 互通脚本）：[`macos/tests/README.md`](macos/tests/README.md)
- 移动端规划：[`mobile/README.md`](mobile/README.md)

## 安装包

macOS 的 dmg / zip 由 `macos/package.sh` 生成在 `macos/dist/`（构建产物，不进 git）。
Windows 的自包含 exe 由 `windows/build.ps1` 生成在 `windows/publish/`（同样不进 git）。

## 已知限制

- 局域网传输是明文直连，没有加密，仅适合可信的家庭 / 办公网络。
- 公司 / 酒店 Wi-Fi 常有 AP 隔离，两端互相搜不到时换手机热点再试。
- macOS 首次使用「电脑设备」页需要允许「本地网络」权限；Windows 首次运行需要放行防火墙的专用网络。
- Windows 端尚未在真实 Windows 机器上运行验证（界面 / 防火墙 / 拖拽交互需真机点一遍）。
