# 移动端开发 Brief（v1）

> 本文件是 Android / iOS / QA 三个并行任务的共同约定。协议以 `docs/LAN-transfer-spec.md` 为准。

## 目标

为「文件互传助手」开发 Android 与 iOS 原生 App，**只保留「电脑设备」功能**：
同一 Wi-Fi 下发现 macOS / Windows 版，6 位配对码配对，像微信一样收发文字和文件。

**不要**实现手机输入 / ADB / 移动设备页（安卓无需 ADB 权限，iOS 无需 USB）。

## 平台要求

| 平台 | 要求 |
| --- | --- |
| Android | Kotlin 原生，`minSdk 28`，`compileSdk 36` / `targetSdk 36`；推荐 Jetpack Compose（也可原生 View） |
| iOS | Swift + SwiftUI 原生，`iOS 17.0+`；用 XcodeGen 生成 `.xcodeproj` |

包名 / Bundle ID 统一：`dev.local.adbtype.mobile`。

## 目录与写权限

- Android：`mobile/android/`（Android 开发者独占）
- iOS：`mobile/ios/`（iOS 开发者独占）
- 协议测试：`mobile/tests/`（QA 独占）
- 文档 / 根 README / 发布：Lead 负责，开发同学不要改

> **测试范围**：本轮只验收移动端与电脑端的「电脑设备」互联互传（发现 / 配对 / 文字 / 文件）；
> macOS 的「移动设备 / ADB」模块不测，Android / iOS 也都不实现 ADB、USB、手机输入功能。

## 一期功能（两端一致）

1. **发现**：UDP 52730 每 2 秒广播 `{app,v,id,name,port}`；监听 0.0.0.0:52730；
   忽略自己、非法报文；8 秒无心跳标离线 / 移出附近列表；向已知好友单播心跳（可选但推荐）。
2. **配对**：本机显示自己的 6 位配对码；首次发送输入对方码；配对成功后双方持久化设备 ID。
3. **聊天**：左侧设备列表（已配对 + 附近设备），右侧当前设备独立会话；离线好友保留，历史可看。
4. **文字**：中文 / emoji；空文字拒绝；左收右发气泡、时间、复制。
5. **文件**：系统文件选择器 / 分享面板选文件；发送 `file` 头 + 原始字节；接收保存到 App 文档目录，
   重名编号；显示进度，失败清理半截文件；收到后可打开 / 分享。
6. **接收文件落盘（用户可访问，不放 App 私有沙盒）**：
   - Android：公共 `Download/文件互传助手/`（API 29+ 用 MediaStore.Downloads；API 28 用公共 Downloads + 存储权限），
     打开/分享走 MediaStore content URI；
   - iOS：保存到 Documents 下 `Downloads/`（通过「文件」App 可见：我的 iPhone › 文件互传助手 › Downloads）；
     图片/视频在获得相册权限后额外保存到系统相册。
7. **持久化**：设备 ID、已配对 ID、好友、每设备聊天记录（`chats/<id>.json` 或等价），重启恢复。
7. **错误处理**：连接超时 6s、读写超时 30s、对方退出 / Wi-Fi 断开提示，不崩溃。

可选加分（不影响验收）：本地别名、手动重连、上次在线时间、聊天记录清空只清当前设备。

## 协议要点（必须逐字段兼容）

- TCP：4 字节大端长度 + UTF-8 JSON；帧上限 16 MiB；文件不套 JSON。
- 握手：`hello {app,v,id,name,code?}` → `hello_ok {name,id}` / `pair_required {name}` / `error {message}`。
- 内容：`text {text}`、`file {name,size}` + 原始字节；接收回 `ok`；结束 `bye`。
- 配对：已配对 ID 直接 hello_ok；未配对时 hello.code 去空白后必须等于本机当前 6 位码；
  否则回 pair_required。发送方收到 hello_ok 后把对方 ID 加入已配对集合。
- 文件：每次发送动作（一段文字或一批文件中的一个文件）新建一条 TCP；文件 256 KiB 一块；
  接收方 `name` 只取最后一段路径、拒绝空 / `.` / `..`，重名 ` (2)` 编号。
- 发现报文里的 `port` 是本机 TCP 监听端口；TCP 监听随机端口。

参考实现（macOS，Swift）：`macos/Sources/LANTransfer.swift`；Windows 参考：`windows/src/ADBTypeLink.Core/`。

## 构建环境

- Android SDK：`/Users/pichs/Android/sdk`（platforms 28–37、build-tools 36、emulator、system-image android-35）
- JDK：`JAVA_HOME=/Users/pichs/Library/Java/JavaVirtualMachines/corretto-17.0.19/Contents/Home`
- Gradle：可用 `~/.gradle/wrapper/dists/` 里的发行版生成 wrapper；需要联网拉 AndroidX / Compose 依赖
- iOS：Xcode 26.6、`xcodegen` 2.46、iOS 18 模拟器；`xcodebuild -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`

## 交付

- 完整源码、可重复构建脚本 / 说明、平台 README；
- 至少通过 `./gradlew assembleDebug` 与单元测试（Android）、`xcodegen generate` + `xcodebuild`（iOS）；
- 不允许提交任何密钥或本机私密路径；不要 commit / push，由 Lead 统一处理。
