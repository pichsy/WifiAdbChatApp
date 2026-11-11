# 发布安装包

> **导航**：[项目首页](../README.md) · [文档中心](../docs/README.md) · [2.3.0 发布说明](../docs/release-notes-2.3.0.md)

正式发布的安装包统一放在这里，方便直接从仓库下载。

| 平台 | 版本 | 文件 | 大小 | SHA-256 |
| --- | --- | --- | --- | --- |
| macOS | 2.3.0 | [文件互传助手-2.3.0.dmg](文件互传助手-2.3.0.dmg) | 4.0 MB | `3a11d130eb4247aab8d6be5cb1284d7c726f5b91fcfe314b35b86845dc3e2d1d` |
| macOS（zip 备用） | 2.3.0 | [文件互传助手-2.3.0-macOS.zip](文件互传助手-2.3.0-macOS.zip) | 3.4 MB | `26da1683b9f7628a3adfee9762e605b5379dad6496a170abea4b7b164b128007` |
| Android | 2.2.0 | [文件互传助手-Android-2.2.0.apk](文件互传助手-Android-2.2.0.apk) | 42 MB | `0bcbeccbe83978f1ec2ba4532f10d6d2932da8b3cd1f3f43ce158099d8e470eb` |
| iOS | 2.2.0 | [文件互传助手-iOS-2.2.0.ipa](文件互传助手-iOS-2.2.0.ipa) | 2.2 MB | `84a9122d811cc6c403d6ddb37fedfb9f84892456c723c67f12ffc45f0ec58d81` |
| Windows | 2.2.0 | [文件互传助手-2.2.0-安装包.exe](文件互传助手-2.2.0-安装包.exe) | 28.1 MB | `60ce64db9c6c253c7e398d683ea5dbfeee34f75a060e7da2ded513549b832ac2` |

> 当前 macOS 为 **2.3.0**；Windows / Android / iOS 仍为 **2.2.0**（上一轮四端统一版本）。
> **iOS ipa 未签名**，需要用自己的 Apple Developer Team 重签后才能装真机；
> **Android apk 已用项目 release key 签名**，可直接侧载安装；与之前的 debug 签名版本不兼容，
> 首次安装需先卸载旧版。Windows 安装包由
> `windows/build-release.ps1` 生成（内置 .NET 8 运行时，目标机器无需安装 .NET）。
> 校验值也可在 [SHA256SUMS.txt](SHA256SUMS.txt) 里查到。
> macOS 更新内容见 [docs/release-notes-2.3.0.md](../docs/release-notes-2.3.0.md)；其它端见
> [docs/release-notes-2.2.0.md](../docs/release-notes-2.2.0.md)。
> Android 签名证书 SHA-256：`710a0df5cf33e705b15ee652496a0f32d2513b2120acba8537e0285a8aaa2496`。

## macOS 安装

1. 下载 `文件互传助手-2.3.0.dmg` 后双击挂载（或解压 `-macOS.zip`）。
2. 把「文件互传助手.app」拖进「应用程序」；如果之前装过旧版，选择**替换**。
3. 首次打开如果被 Gatekeeper 拦截：右键 App →「打开」；或执行 dmg 里的
   `授权并安装.sh`；macOS 15+ 也可以在「系统设置 → 隐私与安全性」点「仍要打开」。
4. 第一次使用「电脑设备」页时，按提示允许**本地网络**权限。

## Android 安装

1. 下载 `文件互传助手-Android-2.2.0.apk`。
2. 用 USB 线安装：`adb install -r 文件互传助手-Android-2.2.0.apk`；或把 APK 传到手机，
   在文件管理器里打开并允许「安装未知应用」。如果装过旧 debug 签名版本，先执行
   `adb uninstall dev.local.adbtype.mobile`（会清掉 App 数据）再安装。
3. 首次打开需要允许「本地网络 / 附近设备」相关权限；收到的文件保存在
   `Download/文件互传助手/`，可在系统「文件管理 → 下载」里直接看到。

> APK 已用项目 release keystore 签名；keystore / 密码不随仓库分发，后续升级请保留本地
> `mobile/android/keystore/`。正式上架 Google Play 仍建议使用独立的正式签名密钥。

## iOS 安装

1. 下载 `文件互传助手-iOS-2.2.0.ipa`。
2. **该 IPA 未签名，不能直接双击安装**。需要用自己的 Apple Developer Team 重签：
   在 Xcode 里打开 `mobile/ios/ADBTypeMobile.xcodeproj`，选择 Team 后 Archive / 导出 IPA；
   或用 `codesign` + 自己的 provisioning profile 重签。
3. 首次运行需允许「本地网络」；收到的文件在「文件」App › 我的 iPhone › 文件互传助手 ›
   Downloads，图片 / 视频还会额外存入系统相册（首次会询问「仅添加照片」）。

## Windows 安装

1. 双击 `文件互传助手-2.2.0-安装包.exe`。
2. 按向导走完：欢迎页 → 选择安装位置（默认 `D:\Program Files\文件互传助手`，向导里可以改成任意目录）→ 安装。
   主程序、3 个原生库、图标和卸载程序都会放进这个目录，运行时直接从该目录启动，
   不会再把程序文件解压到 `C:\...\Temp`。
3. 完成页有 **创建桌面快捷方式**（默认勾选，点「完成」时才创建）和 **立即运行 文件互传助手**（默认勾选），
   按需取消后点「完成」。
4. 首次运行请在 Windows 防火墙放行「专用网络」（发现 UDP 52730 + 随机 TCP 传输端口）。

> 从 2.1.0（或更早）升级：直接运行 2.2.0 安装包、选同一个安装目录覆盖安装即可，
> 聊天记录、配对关系和收到的文件都在 `%APPDATA%\ADBTypeLink` 与下载目录，不受影响。
>
> 聊天记录、配对信息和接收到的文件属于用户数据，仍在 `%APPDATA%\ADBTypeLink`
> 与下载目录里，不随安装位置变化。

静默安装、卸载、SmartScreen 提示等细节见 [安装说明.md](安装说明.md)。

## 说明

- macOS 支持 macOS 13+，通用二进制（Apple 芯片 / Intel）；Android 支持 Android 8.0+（API 28），
  iOS 支持 iOS 17+；Windows 支持 Windows 10 1809+ / 11 x64。
- macOS / Windows / iOS 均未做正式签名 / 公证；Android 为项目 release key 签名。首次打开可能被
  Gatekeeper / SmartScreen / 系统安全提示拦截，按上面的说明放行或重新签名。
- 更新内容见根目录 [README](../README.md) 和各端 README 的更新记录。
- Windows 2.2.0：新增「移动设备」页 **ADB 截屏**（可缩放窗口预览、保存到下载目录）；
  顶部改成 macOS 风格胶囊页签，窗口使用圆角；覆盖安装即可从 2.1.0 升级。
- Windows 2.1.0：点右上角 ✕ 不再退出，窗口收进**托盘**后台继续收发；
  左键托盘图标恢复窗口，右键托盘图标可「显示主窗口 / 退出文件互传助手」。
- `release/` 只存正式发布的安装包；macOS `macos/dist/`、Windows `windows/publish/` 等中间产物都不进 git。
