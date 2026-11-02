# macOS 端协议与界面联调工具

这些脚本用来在没有 UI 自动化的情况下验证「电脑设备」页的局域网协议，以及离屏检查聊天界面。
它们复用 macOS 端真实的 `LANModel`（[`Sources/LANTransfer.swift`](../Sources/LANTransfer.swift)），
不是另写一份模拟实现。

## 文件

| 文件 | 作用 |
| --- | --- |
| `build.sh` | 编译 `/tmp/lan_probe` 和 `/tmp/render_chat_ui` |
| `lan_probe.swift` | 无界面命令行探针：`serve` 监听并打印收到的文字/文件；`send` 发现对端、配对、发文字/文件；`pair` 只配对 |
| `render_chat_ui.swift` | 用 NSHostingView 离屏渲染 `LANTransferView`（可指定尺寸/浅色深色），截图到 PNG，方便检查布局 |
| `py_send.py` | Python 发送端：按协议发现 macOS 探针并发文字/文件 |
| `run_mac_receive_test.sh` | macOS 接收路径测试：Python 发送端 → macOS 探针，校验配对码、中文文字、1 MiB 文件字节一致 |
| `run_interop_windows_receive.sh` | macOS 发送 → Windows Core 接收（用 `windows/src/ADBTypeLink.SmokeTest --role=server`），校验文字、1.5 MB 文件、Windows chat.json |
| `run_interop_mac_receive.sh` | Windows Core 发送（`windows/src/ADBTypeLink.TestPeer send`）→ macOS 接收，校验配对、中文/emoji、900 KB 文件 |

## 使用

在**仓库根目录**执行：

```bash
bash macos/tests/build.sh

# 只测 macOS 接收
bash macos/tests/run_mac_receive_test.sh

# Windows Core 接收（需要先 dotnet build 冒烟测试项目）
bash macos/tests/run_interop_windows_receive.sh

# Windows Core 发送 → macOS 接收（需要先 dotnet build TestPeer）
bash macos/tests/run_interop_mac_receive.sh
```

`lan_probe` 直接使用真实数据目录（`~/Library/Application Support/ADBType/`），
测试脚本会在开始时备份 `paired.json` / `chat.json`，结束时还原；接收目录都指到 `/tmp`。
Windows Core 的数据目录通过 `--data-dir` 指到 `/tmp`，不会碰 macOS 端数据。

## 说明

- Windows 端的 TestPeer 和冒烟测试构建方式见 [`windows/README.md`](../../windows/README.md)：
  ```bash
  dotnet build windows/src/ADBTypeLink.SmokeTest/ADBTypeLink.SmokeTest.csproj -c Release
  dotnet build windows/src/ADBTypeLink.TestPeer/ADBTypeLink.TestPeer.csproj -c Release
  ```
- 本机同时跑多个实例时，127.0.0.1 的单播 UDP 只会投递给其中一个 socket，
  广播路径和 `LocalInstanceRegistry` 兜底由 Windows Core 处理；测试脚本用广播发现即可。
- 渲染脚本只是布局参考，不能替代真机上的鼠标/键盘交互测试。
