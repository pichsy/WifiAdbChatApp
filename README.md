# ADB 输入 · macOS 原生小工具

在 Mac 上输入内容，按 Enter，直接打进**手机当前获得焦点的输入框**。

两条路径自动切换，按钮文字也会跟着变：

- **纯英文 / 数字**：按钮显示「发送到输入框」，`adb shell input text <内容>`，秒发。
- **含中文 / emoji**：按钮显示「发送到设备剪贴板」。`input text` 敲不了中文，于是把文字写进
  手机系统剪贴板，再由你在手机上长按输入框点「粘贴」。不碰手机上的任何界面，不会误操作。

写手机剪贴板用的是随 App 内置的一个 2 KB dex（`adbtype-clip.jar`），以 shell 身份
`app_process` 运行并调用系统 `IClipboard`。手机端不用装任何 App，也不用切输入法。

桌面端是个纯原生 SwiftUI 单窗口程序：无网页、无 Electron、无第三方依赖，启动即用，
产物约 1 MB。

## 构建与运行

```bash
./build.sh          # 需要 Xcode 命令行工具（swiftc），默认编 arm64 + x86_64 通用包
open ADBType.app
```

- 产物 `ADBType.app` 可以直接拖到「应用程序」目录。
- 构建目标为 macOS 13+ 通用二进制（Apple 芯片 / Intel 都能跑），本机临时签名。
- adb 自动查找顺序：已保存的路径 → `ANDROID_HOME` / `ANDROID_SDK_ROOT` → `~/Android/sdk`
  → `~/Library/Android/sdk` → Homebrew → 登录 shell 的 PATH。都找不到时点右下角齿轮手动选择。

## 打包给别人用

```bash
./package.sh        # 生成 dist/ADBType-1.0.dmg 和 dist/ADBType-1.0-macOS.zip
```

- dmg / zip 里带《安装说明.txt》和「授权并安装.sh」（可执行 shell 脚本）：在终端执行
  `bash 授权并安装.sh`，即可自动装进「应用程序」、清掉 `com.apple.quarantine` 并打开
  App（没有管理员权限时会弹窗要密码）。
- 没有苹果开发者签名和公证（需要付费 Developer ID），手动安装的话第一次打开要：
  右键 →「打开」；若提示「已损坏」，执行
  `xattr -dr com.apple.quarantine /Applications/ADBType.app`。
  macOS 15+ 也可在「系统设置 → 隐私与安全性」点「仍要打开」。
- 对方的电脑上仍要有 adb（Android Studio 自带，或单独下载 platform-tools），App 会自动找，
  找不到可在齿轮里手动选。

## 使用

- 顶部选择设备（多台手机时）；插拔会自动刷新（窗口在前台时每 4 秒静默刷新一次）。
- 输入后 `Enter` 或 `⌘↩` 发送。
- **先清空设备输入框**：把光标移到末尾后连发 40 次退格，再输入新内容（仅英文/数字模式）。
- **发送后按回车键**：输入完再点一次 Enter，适合搜索框、聊天输入框（仅英文/数字模式）。
- 输入中文时按钮会变成「发送到设备剪贴板」，复制成功后状态栏会提示你去手机上长按粘贴。
- 发送成功后输入内容保持全选，直接键入下一个值即可覆盖。
- 最近 12 条发送记录，点击回填。

## 已知限制

- 中文会**覆盖手机剪贴板**里的原有内容（写之前请留个心）。
- 粘贴要看输入框自己的长按菜单：绝大多数原生输入框、微信、浏览器都有「粘贴」；
  少数自绘输入框（游戏、部分 Flutter 界面）没有，换成常规输入框即可。
- 手机必须**亮屏解锁**；锁屏状态下注入会落在锁屏界面。
- 个别 App 的输入框（安全键盘、密码框）可能不响应模拟输入。
- 与 QtScrcpy 等自带 adb 的工具可能争抢 5037 端口：应用会自动重试一次；反复失败时关掉
  对方，或让双方使用同一个 adb。
- 「清空」是退格 40 次的实现，超长文本可能清不干净，可多点几次。

## 主要命令

```
adb -s <serial> shell input keyevent 123 67 67 ...   # 清空：MOVE_END + DEL × 40
adb -s <serial> shell input text '123456'            # 纯 ASCII：空格会转成 %s
adb -s <serial> push adbtype-clip.jar /data/local/tmp/adbtype-clip.jar
adb -s <serial> shell 'CLASSPATH=/data/local/tmp/adbtype-clip.jar app_process /system/bin Clip <base64>'
adb -s <serial> shell input keyevent 66              # 回车
```

## 目录

| 文件 | 说明 |
| --- | --- |
| `Sources/ADB.swift` | 定位 adb、执行进程（带超时/重试）、解析设备、拼接命令、写手机剪贴板 |
| `Sources/AppModel.swift` | 状态管理与发送流程（后台线程执行，不卡界面） |
| `Sources/ContentView.swift` | 单窗口界面 |
| `Sources/ADBTypeApp.swift` | App 入口与菜单 |
| `tools/clip/Clip.java` | 写入手机剪贴板的 dex 源码 |
| `tools/buildclip.sh` | 编译出 `Resources/adbtype-clip.jar` |
| `Resources/icon-source.png` | 图标原图（192×192） |
| `tools/makeicon.sh` | 从原图生成整套 AppIcon.icns（无原图时退回矢量绘制） |
| `tools/makeicon.swift` | 旧的矢量图标生成器（备用） |
| `build.sh` | 编译（arm64 + x86_64）并组装 .app |
| `package.sh` | 生成可分发的 dmg / zip |
| `packaging/安装说明.txt` | 写给使用者的安装与连接手机步骤 |
| `packaging/授权并安装.sh` | 终端里执行即可安装 + 解除 macOS 隔离限制 |
