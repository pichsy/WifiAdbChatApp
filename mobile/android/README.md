# 文件互传助手 · Android 端

Android 原生 App（Kotlin + Jetpack Compose），只做「电脑设备」功能：
在同一 Wi-Fi / 局域网里发现 macOS / Windows 版「文件互传助手」，用 6 位配对码配对后，
像微信一样收发文字和文件。

- 包名：`dev.local.adbtype.mobile`
- `minSdk 28`（Android 9）、`compileSdk 36`、`targetSdk 36`
- 协议：与电脑端完全一致，见 [docs/LAN-transfer-spec.md](../../docs/LAN-transfer-spec.md)
- **不含** ADB / 手机输入 / 移动设备页（那是 macOS 端的功能）

---

## 功能

### 已实现

- **发现**：UDP 52730 每 2 秒广播 `{app,v,id,name,port}`，同时发往 `255.255.255.255`
  与 `127.0.0.1`；监听 `0.0.0.0:52730`，8 秒无心跳标离线并移出「附近设备」；
  对已知设备（含已配对好友）单播心跳。
- **配对**：本机首页显示自己的 6 位配对码（可复制、可「换一个」）；
  首次发送时弹出配对框输入对方 6 位码，配对成功后双方持久化设备 ID，之后直接发送。
- **文字**：中文 / emoji；空文字本地拒绝；左收右发气泡、时间、长按复制。
- **文件**：系统文件选择器多选 → 待发送列表（chips）→ 逐个文件新建 TCP 连接发送；
  **接收的文件保存到用户可见的公共 `Download/文件互传助手/`**（不再放 App 私有沙盒）：
  - API 29+：`MediaStore.Downloads` + `RELATIVE_PATH=Download/文件互传助手`，
    `IS_PENDING` 写入，完成后返回 content URI；
  - API 28：公共 `Downloads/文件互传助手` 目录 + `WRITE_EXTERNAL_STORAGE` 运行时权限；
  - 重名自动 ` (2)` 编号，显示进度，失败自动删除半截文件；
  - 聊天里点「打开 / 分享」直接使用 content URI（API 28 走 FileProvider，带读取授权）；
  - 路径穿越（`..`、`/..`、Windows 反斜杠路径）会被拒绝。
- **图片 / 视频消息**：固定 **120×90dp** 圆角缩略图（视频叠加播放图标），
  图片缩略图用 Glide（content URI 和本地路径都支持）、视频用 MediaMetadataRetriever 取首帧；
  点击图片用 filepicker 的 `ImagePreviewDialog` 全屏放大、点击视频用 `VideoPreviewDialog` 播放
  （content URI 会先复制到 `cache/media-preview` 得到本地路径）；
  缩略图加载失败显示占位，文件被删除时保持「文件已不存在」，其它文件仍是文件卡片。
- **离线保留**：已配对好友常驻列表，离线显示「离线 · 上次 HH:mm」；
  每个设备独立聊天记录，重启恢复；清空聊天只清当前会话、不删已收文件。
- **错误处理**：TCP 连接 6 秒超时、读写 30 秒超时、对端退出 / Wi-Fi 断开提示，
  任何连接异常都不影响监听，App 不崩溃。

### 一期范围外（不影响电脑互传）

- 后台常驻 / 前台服务（App 退到后台后进程被系统回收就会停止收消息）；
- 群发给多台设备、消息已读回执、端到端加密；
- 本地别名（UI 未做，存储模型里保留了 `alias` 字段）。

---

## 构建

### 环境

| 项 | 值 |
| --- | --- |
| JDK | 17（本机验证过 Amazon Corretto 17；`JAVA_HOME` 指向 JDK 17 即可） |
| Android SDK | platform 36 + build-tools 36（用 `ANDROID_HOME` 或 `local.properties` 指定） |
| Gradle | 8.13（wrapper 已带在仓库里，无需另外安装） |
| AGP / Kotlin | 8.13.0 / 2.2.21 |
| Compose | BOM 2025.06.01（Material3） |

图片 / 视频预览依赖（用户提供的 filepicker 库及其依赖，已写入 `app/build.gradle.kts`）：

| 依赖 | 版本 | 用途 |
| --- | --- | --- |
| `com.gitee.pichs:filepicker` | 8.2.0 | 全屏图片 / 视频预览弹窗（ImagePreviewDialog / VideoPreviewDialog） |
| `com.gitee.pichs:xwidget` | 5.8.1 | filepicker 的 UI 控件 |
| `com.github.bumptech.glide:glide` | 4.16.0 | 图片缩略图加载 |
| `com.github.liangjingkanji:BRV` | 1.6.1 | filepicker 列表（仓库在 JitPack） |
| `io.github.razerdp:BasePopup` | 3.2.1 | filepicker 弹窗基类 |
| `androidx.media3:media3-exoplayer` / `media3-ui` | 1.7.1 | 视频播放 |
| `androidx.appcompat` / `com.google.android.material` / `androidx.recyclerview` / `androidx.constraintlayout` / `androidx.databinding:viewbinding` | 1.7.1 / 1.14.0 / 1.4.0 / 2.2.2 / 8.13.0 | filepicker 的 AppCompat / Material3 / ViewBinding 依赖 |

> BRV 只发布在 JitPack，`settings.gradle.kts` 的 `dependencyResolutionManagement` 里已加
> `maven("https://jitpack.io")`，首次构建需要联网。

`local.properties` 里写你本机的 SDK 路径（该文件已在 `.gitignore` 里，不要提交）：

```properties
sdk.dir=<你的 Android SDK 路径>
```

### 命令

```bash
cd mobile/android

# 构建 debug APK
./gradlew assembleDebug

# 跑 JVM 单元测试（帧编解码 / 握手配对 / 聊天缓存 / 文件名 / 公共下载保存 / 持久化）
./gradlew testDebugUnitTest

# 安装到已连接的手机（需要 adb）
./gradlew installDebug
```

产物：

```
mobile/android/app/build/outputs/apk/debug/app-debug.apk
```

单元测试报告：

```
mobile/android/app/build/reports/tests/testDebugUnitTest/index.html
```

---

## APK 签名

2.2.0 的 release APK 已用本项目的 release key 重新签名：

- keystore：`mobile/android/keystore/adbtype-release.keystore`（本地文件，**不提交仓库**）
- alias：`adbtype`
- 密码：同目录 `credentials.txt`（权限 600，不提交仓库）
- 证书 SHA-256：`710a0df5cf33e705b15ee652496a0f32d2513b2120acba8537e0285a8aaa2496`

注意：这个 release key 与旧的 Android Debug 签名不同，**不能直接覆盖安装旧 debug 版**。
如果手机上装过旧版，需要先卸载（会清掉 App 数据），再安装签名 APK：

```bash
adb uninstall dev.local.adbtype.mobile
adb install -r 文件互传助手-Android-2.2.0.apk
```

后续升级必须继续使用同一份 keystore，请自行备份 `mobile/android/keystore/`。

---

## 使用

1. 手机和电脑连同一 Wi-Fi / 局域网；
2. 两边都打开 App：手机首页显示自己的 6 位配对码，电脑端也能看到自己的码；
3. 手机「附近设备」出现电脑后：
   - 想先配对：点设备行右边的「配对」，输入**电脑屏幕上**的 6 位码；
   - 也可以直接进聊天窗口发消息，第一次发送会自动弹出配对框；
4. 配对成功后可直接收发文字和文件；文件用输入框左边的 📎 选择；
5. 收到的文件自动保存到**公共下载目录** `下载/文件互传助手/`，
   系统「文件管理 / 下载」里能直接看到；聊天里点「打开 / 分享」即可用其它 App 处理。
   首页本机卡片会显示当前保存位置。

> 首次运行时，部分国产 ROM 会拦截局域网访问 / 广播；如发现搜不到设备，
> 请在系统设置里允许本 App 的「本地网络 / WLAN」权限，并保持 App 在前台。

---

## 权限

| 权限 | 用途 |
| --- | --- |
| `INTERNET` | TCP 收发 |
| `ACCESS_NETWORK_STATE` / `ACCESS_WIFI_STATE` | 获取 Wi-Fi 状态、申请组播锁 |
| `CHANGE_WIFI_MULTICAST_STATE` | 部分机型需要组播锁才能稳定收 UDP 广播 |
| `WRITE_EXTERNAL_STORAGE`（`maxSdkVersion=28`） | 仅 API 28：把收到的文件写进公共 `Downloads/文件互传助手`；API 29+ 走 MediaStore，不需要任何存储权限 |

不需要读取存储权限（选文件用 SAF，接收文件写公共下载目录，打开 / 分享用 content URI + FileProvider）。
API 28 若拒绝存储权限，收到的文件会退回 App 专属目录并在状态栏提示（传输不会失败）。
明文 TCP 无加密，仅适合可信的家庭 / 办公局域网。

---

## 目录结构

```
mobile/android/
├── app/src/main/java/dev/local/adbtype/mobile/
│   ├── MainActivity.kt          # Compose 入口 + API 28 存储权限请求
│   ├── LanViewModel.kt          # 引擎状态 → UI 状态、配对弹窗、文件选择
│   ├── core/                    # 纯 Kotlin（可在 JVM 单元测试）
│   │   ├── LanJson.kt           # 极简 JSON 编解码（不依赖 org.json）
│   │   ├── LanFrame.kt          # 4 字节大端长度 + UTF-8 JSON 帧
│   │   ├── LanProtocol.kt       # 协议常量、报文构造、发现报文校验
│   │   ├── Pairing.kt           # 6 位配对码、服务端 hello 判定、客户端握手解析
│   │   ├── FileNames.kt         # 路径穿越拒绝、重名编号、大小格式化
│   │   ├── ReceivedFilePublisher.kt  # 「收到文件保存到哪里」抽象 + 目录实现（JVM 可测）
│   │   ├── MediaType.kt         # 图片 / 视频 / 其它文件的后缀判定（JVM 可测）
│   │   ├── ChatStore.kt         # 每设备独立聊天记录（chats/<设备ID>.json）
│   │   ├── LanStores.kt         # device_id / paired.json / friends.json
│   │   ├── LanModels.kt         # 数据模型与状态快照
│   │   └── LanEngine.kt         # UDP 发现 + TCP 监听/发送 + 状态管理
│   ├── data/
│   │   └── AndroidReceivedFilePublisher.kt  # API 29+ MediaStore.Downloads / API 28 公共 Downloads
│   └── ui/                      # Compose 界面（设备列表 / 聊天 / 弹窗 / 打开分享）
│       ├── MediaPreview.kt      # 缩略图（Glide / 视频首帧）+ content URI 转本地预览路径
│       └── FileActions.kt       # 打开 / 分享（content URI / FileProvider）
└── app/src/test/java/...        # JVM 单元测试
```

---

## 协议实现要点

| 项 | 实现 |
| --- | --- |
| UDP 发现端口 | `52730`，2 秒广播，8 秒判离线，3 秒清理 |
| 广播目标 | `255.255.255.255:52730`、`127.0.0.1:52730`、已知设备单播 |
| 发现报文校验 | `app == "ADBTypeLink"`、`id` 非空且 ≠ 本机、`name` 非空、`port` 1–65535；`v` 向前兼容 |
| TCP | 随机端口监听；`4 字节大端长度 + UTF-8 JSON`，单帧上限 16 MiB |
| 超时 | connect 6s；已建连读写 30s（文件写有看门狗，30 秒无进展主动断开） |
| 握手 | `hello {app,v,id,name,code?}` → `hello_ok` / `pair_required` / `error` |
| 配对 | 已配对 ID 直接 `hello_ok`；否则 `code` 去空白后必须等于本机当前 6 位码 |
| 内容 | `text{text}`、`file{name,size}` + 原始字节；接收回 `ok`；结束 `bye` |
| 文件 | 256 KiB 分块、不套 JSON 帧；接收按 `name` 最后一段保存并编号 |
| 发送 | 每个发送动作（一条文字 / 一个文件）新建一条 TCP，完成后 `bye` 并关闭 |

### 接收文件保存位置

| Android 版本 | 保存方式 | 消息里记录 | 用户在哪看到 |
| --- | --- | --- | --- |
| API 29+（Android 10+） | `MediaStore.Downloads`，`RELATIVE_PATH=Download/文件互传助手/`，`IS_PENDING` 分块写入 | content URI | 系统「文件管理 / 下载」→ 文件互传助手 |
| API 28（Android 9） | 公共 `Downloads/文件互传助手` 文件（需 `WRITE_EXTERNAL_STORAGE`） | 文件绝对路径（打开/分享走 FileProvider） | 系统「文件管理 / 下载」→ 文件互传助手 |
| API 28 且拒绝存储权限 | 退回 App 专属目录 `Android/data/.../files/received` | 文件绝对路径 | 仅 App 内可打开 / 分享 |

发送文件前会先复制一份到 App 私有目录 `files/outgoing/`，避免 `content://` 选择器 URI 失效。

### 本地持久化（Android 端格式）

App 私有目录 `files/lan/`：

| 文件 | 内容 |
| --- | --- |
| `device_id.txt` | 首次启动生成的 UUID，之后不变 |
| `paired.json` | 已配对设备 ID 字符串数组，如 `["id1","id2"]` |
| `friends.json` | `[{"id","name","host","port","lastSeen","alias"?}]`，`lastSeen` 为 epoch 毫秒 |
| `chats/<设备ID>.json` | 该设备的聊天记录数组，字段 `id/direction/peerName/date/kind/text/fileName/filePath/fileUri/fileSize` |

> 电脑端用「自 2001-01-01 起的秒数」表示时间，Android 端用 epoch 毫秒；
> 两种格式各自独立，只影响本地文件，不影响网络协议互通。
> 每个设备会话最多保留 500 条（与电脑端一致）。

---

## 单元测试

`./gradlew testDebugUnitTest` 共 **78 个测试**（12 个测试类，全部通过）：

- `LanJsonTest`（8）：JSON 解析 / 序列化、中文 emoji、转义、非法输入；
- `LanFrameTest`（8）：4 字节大端长度、逐字节到达的流也能读完整帧、超 16 MiB 拒绝、文件分块拷贝；
- `LanProtocolTest`（9）：hello/text/file/ok/bye 报文形状、发现报文校验、握手响应解析；
- `PairingTest`（10）：6 位码生成 / 规范化、已配对直接通过、正确码配对、错误/缺失码请求配对、非法 hello 拒绝；
- `ProtocolFlowTest`（5）：帧 + 握手 + 配对 + 文件头/原始字节的端到端字节流验证；
- `ChatStoreTest`（9）：按设备隔离、重启恢复、清空只影响当前设备、500 条上限、content URI 持久化、损坏文件容错；
- `FileNamesTest`（9）：路径穿越拒绝、重名编号（目录 / MediaStore 两种场景）、超长文件名、大小格式化；
- `MediaTypeTest`（5）：图片 / 视频后缀识别（大小写、中文名、多点文件名）、其它文件保持文件卡片；
- `LanStoresTest`（5）：设备 ID 稳定、配对 / 好友持久化、损坏文件容错；
- `DirectoryReceivedFilePublisherTest`（5）：分块写盘与进度、重名编号、0 字节文件、中断后清理半截文件、自动建目录；
- `EngineIncomingTest`（4）：真实 socket 联调——裸 TCP 客户端走 hello/hello_ok/text/file/ok/bye，
  验证配对码放行 / 错误码 pair_required / 非法 hello 回 error、文件落盘与重命名；
- `EngineOutgoingTest`（1）：真实 socket 联调——用 UDP 通告让引擎发现假对端，
  再通过 TCP 发文字 + 文件，验证发现→连接→握手→发送→ok 整条链路。

> 两个引擎联调测试使用随机 UDP 发现端口（`LanEngine(discoveryPort = ...)`），
> 不会和本机正在运行的 App / 其它进程抢 52730。

---

## 已知限制

- 没有前台服务，App 被系统回收 / 长时间后台时收不到消息（重新打开即恢复）；
- 同一台手机上无法开两个实例做「本机回环」联调（需要两台设备，或用电脑端两个实例）；
- 明文 TCP、无加密，仅适合可信局域网；
- 大文件传输未做断点续传，中途断开需要重发；
- 已发送文件的本地副本保存在 `files/outgoing/`，暂不自动清理；
- API 28 且拒绝存储权限时，接收文件会退回 App 专属目录（不会写公共下载）；
- 旧版本（本次改动前）已收到的文件仍在 App 私有目录，不做自动迁移，打开 / 分享仍可用；
- 图片 / 视频全屏预览使用 filepicker 弹窗；content URI 首次预览会复制一份到
  `cache/media-preview`（大视频会临时占缓存，系统会按需回收）；
- 视频缩略图取首帧，超长/损坏视频可能只能显示占位图标。
