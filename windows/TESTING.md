# Windows 端测试指南

> 当前状态：代码已完成；在 macOS 上编译 0 warning、冒烟测试 37/37 + 9/9 通过、
> 与 macOS 端真实 TCP 双向互通通过。**尚未在真实 Windows 机器上运行过**，
> 所以下面第 3、4 步是本次换到 Windows 后最需要做的验证。

## 0. 准备

- Windows 10 1809+ / Windows 11（x64 或 ARM64）
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)（构建需要；发布出的自包含 exe 运行时不需要）
- 两台设备连同一个 Wi-Fi / 交换机；网络位置设为「专用网络」

```powershell
dotnet --version    # 应显示 8.x
```

获取代码：`git clone https://gitee.com/pichs/WifiAdbChatApp.git`，或直接把 `windows/` 目录拷到 Windows 上。

## 1. 一键构建 + 自动冒烟测试（5 分钟）

在 `windows/` 目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

它会依次：

1. `dotnet restore` / `dotnet build -c Release`（期望：0 warning、0 error）
2. 跑冒烟测试（期望：**37 通过 / 0 失败**，退出码 0）
3. 发布自包含单文件：
   - `publish\win-x64\ADBTypeLink.App.exe`
   - `publish\win-arm64\ADBTypeLink.App.exe`

只想先编译：`powershell -ExecutionPolicy Bypass -File .\build.ps1 -SkipPublish`
跳过冒烟测试：`-SkipSmokeTest`

单独跑冒烟测试（含跨进程子进程测试）：

```powershell
dotnet run --project src\ADBTypeLink.SmokeTest -c Release
dotnet run --project src\ADBTypeLink.SmokeTest -c Release -- --cross-process
```

## 2. 单机检查界面（不需要第二台电脑）

用演示数据直接看界面和交互：

```powershell
.\publish\win-x64\ADBTypeLink.App.exe --demo
# 或者
dotnet run --project src\ADBTypeLink.App -c Release -- --demo
```

确认：

- [ ] 窗口标题 / 侧栏品牌是「文件互传助手」，任务栏图标是新 logo
- [ ] 左侧设备列表、本机配对码（6 位，可复制/换一个）、接收目录、已配对数量显示正常
- [ ] 右侧消息气泡左收右发、头像、时间、复制、文件「打开 / 显示」正常
- [ ] **输入框固定在底部**，Enter 发送、Shift+Enter 换行
- [ ] 附件按钮可以选多个文件，进入待发送 chips，可单个移除/清空
- [ ] 配对弹窗、清空记录确认弹窗能正常打开/关闭
- [ ] 深浅色跟随系统正常；缩放窗口到最小 900×620 不破版

还可以让程序自己截一张界面图（不需要屏幕录制权限）：

```powershell
.\publish\win-x64\ADBTypeLink.App.exe --screenshot out.png --theme dark
.\publish\win-x64\ADBTypeLink.App.exe --screenshot out-light.png --theme light --demo-heavy
```

## 3. Windows ↔ macOS 联调（重点）

1. Windows 打开 `ADBTypeLink.App.exe`；macOS 打开 `文件互传助手.app`（本机已有）；
2. 两台连同一个局域网，几秒内左侧「附近设备」应出现对方；
3. 首次发送需要配对：在对方界面左侧看到 6 位配对码，点击「配对…」输入；
4. 配对成功后测试：
   - [ ] Windows → Mac 发送中文文字（含 emoji），Mac 聊天记录出现；
   - [ ] Mac → Windows 发送中文文字，Windows 聊天记录出现；
   - [ ] 双向发送文件（选 1 个约 1 MB 的文件），接收目录出现文件，大小一致；
   - [ ] Windows 一次选多个文件发送，Mac 侧全部收到；
   - [ ] Mac 侧同名文件再发一次，Windows 接收目录自动变成 `xxx (2).扩展名`；
   - [ ] 窗口拖拽文件到聊天区，进入待发送 chips，点「发送文件」才真正发送；
   - [ ] 关闭两端再打开：聊天记录、配对关系、接收目录都恢复；
   - [ ] 输错配对码：提示「配对码不对…」，可重试；
   - [ ] 关闭 Mac 端后再从 Windows 发送：几秒内提示连接失败，不崩溃。

发送/接收目录：

- Windows 默认 `%USERPROFILE%\Downloads\ADBType 接收`
- 聊天记录 `%APPDATA%\ADBTypeLink\chat.json`（清空记录不会删文件）

## 4. Windows ↔ Windows 联调（可选）

两台 Windows 各运行一份 `publish\win-x64\ADBTypeLink.App.exe`，流程同上。
如果其中一台是 ARM 设备（如骁龙本），用 `win-arm64` 目录下的 exe。

## 5. 防火墙 / 网络排查

首次运行如果任何一台都看不到对方：

1. Windows 安全中心 → 防火墙和网络保护 → 允许应用通过防火墙，勾选 **专用**；
2. 当前 Wi-Fi 若被识别为「公用网络」，改成「专用网络」；
3. 需要放行：UDP **52730**（发现）+ 应用启动时随机 TCP 端口（传输）；
4. 公司 / 酒店 Wi-Fi 可能有 AP 隔离，换手机热点再试。

## 6. 出问题时请提供

- 哪一步、期望什么、实际什么（最好带截图）
- 两台设备的系统（Windows 版本 / macOS 版本）、是否同一 Wi-Fi
- 窗口底部状态栏文字 / `%APPDATA%\ADBTypeLink\chat.json`（如有）
- 命令行启动时的 stderr 输出
