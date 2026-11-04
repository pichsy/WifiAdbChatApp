# 文件互传助手 · iOS（SwiftUI）

同一 Wi-Fi 下与 macOS / Windows 版「文件互传助手」发现、配对、互发文字和文件的
**原生 iOS App**。只做「电脑设备」功能：设备列表 + 聊天窗口；不包含 ADB、手机输入、
移动设备页（这些是电脑端功能）。

- Bundle ID：`dev.local.adbtype.mobile`
- 最低系统版本：iOS 17.0
- 工程生成：XcodeGen（`project.yml` → `ADBTypeMobile.xcodeproj`，不提交 DerivedData）
- 协议：严格按 [`docs/LAN-transfer-spec.md`](../../docs/LAN-transfer-spec.md) 实现，
  与 macOS（`macos/Sources/LANTransfer.swift`）、Windows（`windows/src/ADBTypeLink.Core`）互通

## 已实现功能

- **发现**：UDP 52730 每 2 秒广播 `{app,v,id,name,port}`；监听 `0.0.0.0:52730`
  （`SO_REUSEADDR + SO_REUSEPORT`）；额外广播到 `127.0.0.1` 并给已知设备单播心跳；
  8 秒无心跳标离线，已配对好友永久保留在「已配对」列表，历史随时可看。
- **配对**：本机大号显示 6 位配对码（可复制 / 换一个）；首次发送自动弹配对框，
  也可在聊天页点「配对…」主动配对；已配对设备 ID 持久化（`paired.json`）。
  配对码错误提示「配对码不对，再看一眼对方屏幕上显示的数字」；配对成功后自动重发刚才的内容。
- **文字**：中文 / emoji，左收右发气泡 + 时间；长按复制；空文字不建连接。
- **文件**：系统文件选择器（`.fileImporter`，支持多选），发送前以 chips 展示、可移除；
  256 KiB 分块发送、总进度和「3/5 文件名」；接收保存到 **`Documents/Downloads/`**
  （「文件」App › 我的 iPhone › 文件互传助手 › Downloads 可见），
  重名自动 ` (2)` 编号、路径穿越文件名会被清洗、失败清理半截文件；收到后可 Quick Look
  打开 / 分享；同一文件消息会显示「已保存 / 已发送 / 文件已不存在」。
- **相册**：收到的图片 / 视频（jpg / png / heic / gif / mp4 / mov 等）在获得
  「仅添加照片」权限后额外存入系统相册；相册保存失败 / 未授权不影响 Downloads 里的文件。
- **图片 / 视频消息**：图片和视频在聊天气泡里显示固定 120×90pt 圆角缩略图，视频叠加播放图标；
  缩略图由 ImageIO（图片）和 AVAssetImageGenerator（视频首帧）在后台生成并做 NSCache 缓存，
  生成失败显示占位；点击图片进入全屏查看器（双指缩放 / 双击放大缩小 / 关闭），
  点击视频用 AVKit AVPlayerViewController 全屏播放（播放 / 暂停 / 进度）。
  其他文件仍显示原来的文件卡片。
- **旧目录迁移**：升级后启动时自动把旧 `Documents/Received/` 里的文件迁移到
  `Documents/Downloads/`（重名自动编号），并把聊天记录里的旧 filePath 改成新位置。
- **持久化**：设备 ID（UserDefaults `lanDeviceID`）、`paired.json`、`friends.json`、
  `chats/<设备ID>.json`（每台电脑独立会话，最多 500 条，字段与电脑端一致）。
- **错误处理**：TCP 连接 6 秒超时、连接上读写 30 秒超时、单帧 16 MiB 上限；
  对方退出 / Wi-Fi 断开 / 端口占用 / 本地网络权限被拒都有中文提示，不崩溃；
  回到前台自动补发心跳并在网络切换后重建套接字。
- **UI**：设备列表（本机配对码、已配对、附近设备、状态条）、聊天页
  （连接状态 / 配对按钮 / 消息列表 / 底部输入框 / 附件 / 发送按钮 / 进度条）、
  配对弹窗（数字键盘、自动过滤非数字、粘贴、错误提示、配对并发送）。

## 环境要求

| 工具 | 版本（本机验证） |
| --- | --- |
| Xcode | 26.6（Build 17F113） |
| XcodeGen | 2.46.0 |
| 模拟器 | **iPhone 17 · iOS 26.5**（本次验收） |
| 部署目标 | iOS 17.0+ |

> 开发时也可以选用任意 iOS 17+ 的模拟器或真机。本次构建与测试均使用
> iPhone 17 / iOS 26.5 模拟器（UDID `34CBAC34-40A0-4318-A9B1-2DB088AD2FF8`）。

## 构建

在 `mobile/ios/` 目录下：

```bash
# 1. 生成 Xcode 工程（修改 project.yml 或增删文件后需要重新执行）
xcodegen generate

# 2. 构建（iPhone 17 / iOS 26.5 模拟器）
xcodebuild -project ADBTypeMobile.xcodeproj \
  -scheme ADBTypeMobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath build/DerivedData \
  build

# 产物
# build/DerivedData/Build/Products/Debug-iphonesimulator/ADBTypeMobile.app
```

用 Xcode 打开 `ADBTypeMobile.xcodeproj`，选择 iPhone 17 模拟器或真机直接运行也可以。

### 安装到模拟器 / 真机

```bash
xcrun simctl boot 'iPhone 17'
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/ADBTypeMobile.app
xcrun simctl launch booted dev.local.adbtype.mobile
```

真机：在 Xcode 的 Signing & Capabilities 选择自己的 Team（或在 `project.yml` 的
`DEVELOPMENT_TEAM` 填 Team ID），第一次运行时在 iPhone 上到
「设置 → 通用 → VPN 与设备管理」信任开发者证书。

## 测试

```bash
xcodebuild -project ADBTypeMobile.xcodeproj \
  -scheme ADBTypeMobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath build/DerivedData \
  test
```

测试分两类：

1. **单元测试**（`ADBTypeMobileTests/`）：帧编码（4 字节大端长度、16 MiB 上限、
   中文/emoji JSON）、发现报文校验（app/id/name/port、忽略自己、非法报文）、
   文件名清洗与重名编号、路径穿越拒绝、聊天记录 / 配对 / 好友持久化（500 条上限、
   JSON 字段与 Date 默认编码）、配对码与设备 ID、协议常量、旧 Received → Downloads
   迁移（重名编号 / 空目录清理）、图片视频类型识别、缩略图生成与缓存
   （ImageIO 图片 + fixture 视频首帧）、全屏图片解码尺寸。
2. **回环集成测试**（`LANModelIntegrationTests.swift`）：
   - App 作为服务端：错误配对码 → `pair_required`；正确配对码 → `hello_ok`；
     收文字 / 收文件到 Downloads / 重名编号 / `..` 文件名拒绝；消息与配对关系落盘。
   - App 作为客户端：首次发送收到 `pair_required` → 弹配对框 → 码错提示 →
     配对成功自动重发文字 → 发送文件，对端收到字节一致。
   - 旧 Received 文件与聊天记录路径的启动迁移。
3. **可选 UI 联调测试**（`ADBTypeMobileUITests`，不在默认 scheme 里跑）：
   需要先用真实电脑发好图片 / 视频，再执行
   `xcodebuild ... -scheme ADBTypeMobileUITests -destination '...iPhone 17...' test`。
   它会打开与 pichs 的聊天、点击图片缩略图验证全屏查看器、双击缩放、关闭，
   再点击视频缩略图验证 AVKit 播放器并截图附件。

## 工程结构

```
mobile/ios/
├─ project.yml                  # XcodeGen 工程定义
├─ ADBTypeMobile.xcodeproj/     # xcodegen generate 生成（可重新生成，勿手改）
├─ ADBTypeMobile/
│  ├─ App/                      # App 入口、根导航、设备列表
│  ├─ Models/                   # LANPeer / LANMessage / PairingPrompt / 状态
│  ├─ Protocol/                 # 帧编解码、消息构造、发现报文、BSD socket 读写
│  ├─ Stores/                   # 目录/迁移、设备身份、配对/好友、聊天、文件名、相册保存
│  ├─ ViewModels/               # LANModel（发现/收发/配对/持久化）
│  ├─ Views/                    # 本机卡片、设备行、聊天页、气泡、缩略图、图片查看器、
│  │                            #   视频播放器、配对弹窗、Quick Look
│  ├─ Support/                  # 格式化、状态配色、缩略图缓存 / 全屏图片解码
│  ├─ Assets.xcassets/          # AppIcon（来自 mobile/assets/app-icon.png）、强调色
│  └─ Info.plist                # NSLocalNetworkUsageDescription、相册权限、文件共享
├─ ADBTypeMobileTests/          # XCTest（单元 + 回环集成，含视频缩略图 fixture）
└─ ADBTypeMobileUITests/        # 可选 UI 联调：缩略图点击 / 全屏查看 / 视频播放
```

### 本地数据位置

在 iPhone 容器内：

| 内容 | 路径 |
| --- | --- |
| 设备 ID | UserDefaults `lanDeviceID` |
| 已配对 ID | `Library/Application Support/ADBTypeMobile/paired.json` |
| 好友名册 | `Library/Application Support/ADBTypeMobile/friends.json` |
| 聊天记录 | `Library/Application Support/ADBTypeMobile/chats/<设备ID>.json` |
| 接收文件 | **`Documents/Downloads/`**（文件 App › 我的 iPhone › 文件互传助手 › Downloads 可见） |

## 接收目录与相册

- **不需要越狱 / 不需要「App 文件」越权**：Info.plist 打开 `UIFileSharingEnabled` 与
  `LSSupportsOpeningDocumentsInPlace`，App 的 Documents 会以「文件互传助手」出现在
  系统「文件」App 的「我的 iPhone」下；收到的文件统一放在 `Downloads` 子目录，
  用户可以直接用「文件」App 打开、拷贝、分享。App 内用 Quick Look 打开后同样带分享按钮。
- **旧目录兼容**：旧版本把文件放在 `Documents/Received/`；新版本启动时自动迁移到
  `Documents/Downloads/`（重名时编号，不覆盖已有文件），并修正聊天记录里指向旧目录的
  路径；旧 `Received` 目录为空后会被删除。已经打开过旧文件的界面/历史消息不会丢。
- **图片 / 视频额外存相册**：收到图片 / 视频后，除正常保存到 Downloads 外，还会调用
  `PHPhotoLibrary`（`.addOnly`）额外保存一份到系统「照片」App。Info.plist 已写
  `NSPhotoLibraryAddUsageDescription`；首次会弹「仅添加照片」权限。
  用户拒绝 / 相册写入失败时**不会影响** Downloads 里的文件，聊天记录照常出现，
  状态提示只显示「已保存到文件互传助手/Downloads」；成功时会追加「已存入系统相册」。
- **改名 / 重名**：同名文件自动 ` (2)`、` (3)`……编号；路径穿越（`..`、绝对路径、
  反斜杠路径）在保存前会被清洗到最后一段，非法名字直接拒绝。
- **打开 / 分享**：收到的文件可在聊天里点击用 Quick Look 打开，长按可「分享」；
  文件被删除 / 移动后聊天里会显示「文件已不存在」。

## 本地网络与真机注意事项

1. **权限**：iOS 14+ 访问局域网（UDP 广播 / 连接局域网 IP）会弹「本地网络」权限。
   Info.plist 已写 `NSLocalNetworkUsageDescription`。若用户点了「不允许」，
   设备列表会提示「本地网络权限未开启」，并给出「打开设置」按钮：
   设置 → 隐私与安全性 → 本地网络 → 打开「文件互传助手」。改完回到 App 会自动重连，
   也可以点右上角刷新按钮重新搜索。
2. **同一 Wi-Fi**：手机和电脑必须在同一网段；公司网络 / 酒店 Wi-Fi 常开 AP 隔离或过滤
   广播，此时电脑端可能在列表里但连不上。可让电脑端和手机连同一个路由器，或改连手机热点。
3. **后台限制**：iOS 会在 App 进入后台后挂起进程，**收不到消息是正常的**。
   本 App 不需要后台常驻：回到前台会立刻补发心跳并重建套接字；聊天记录 / 配对关系都在本地。
4. **模拟器差异**：iOS 模拟器共用 Mac 的网络栈，不会弹「本地网络」权限，
   也可能同时看到 Mac 上的电脑端 App 和其他模拟器。模拟器之间 / 模拟器与 Mac 端联调时，
   广播与 `127.0.0.1` 回环均可工作；但用 `SO_REUSEPORT` 共用 52730 时，
   发往 `127.0.0.1` 的单播报文只投递给其中一个 socket，跨设备互通仍以广播为准。
   真机验收请以真机为准。
5. **明文协议**：局域网明文 TCP，无加密、无账号，仅适合可信的家庭 / 办公网络。
6. **配对码**：每次启动会生成新的 6 位配对码（与 macOS 端行为一致），配对成功后
   双方持久化设备 ID，之后不再需要配对码；也可以手动「换一个」。
7. **相册权限**：模拟器上可直接用 `xcrun simctl privacy booted grant photos-add
   dev.local.adbtype.mobile` 预授权，避免自动化测试被系统弹窗打断；真机首次收到
   图片 / 视频时按提示允许「仅添加照片」即可，拒绝只影响相册副本，不影响文件保存。

## 与电脑端联调（可选）

仓库的 `mobile/tests/` 提供了 Python 参考对端，可当作「电脑」验证协议：

```bash
cd mobile/tests
# 启动一个模拟电脑端（会广播、打印本机配对码）
python3 run_reference_peer.py --name "iOS 联调电脑"
```

在 iPhone / 模拟器 App 里应该能看到这台电脑；首次发送时把它打印的 6 位码输入即可。
本次开发已用它实际验证：错误配对码回 `pair_required`、正确配对码配对成功、
收到中文文字与中文文件名文件（字节一致）并落盘；反方向的发送路径由
`LANModelIntegrationTests` 覆盖。

## 本次验收记录（2026-11-04）

| 项 | 命令 / 结果 |
| --- | --- |
| 工程生成 | `xcodegen generate`（XcodeGen 2.46.0）→ 成功生成 `ADBTypeMobile.xcodeproj` |
| 模拟器构建 | `xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build` → **BUILD SUCCEEDED**（exit 0） |
| 测试 | `xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' test` → **TEST SUCCEEDED**（exit 0），49 个测试 0 失败（46 单元 + 3 回环集成） |
| 真机编译 | `xcodebuild ... -destination 'generic/platform=iOS' -configuration Release CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**（exit 0） |
| 产物 | `build/DerivedData/Build/Products/Debug-iphonesimulator/ADBTypeMobile.app` |
| 参考对端互通 | 用 `mobile/tests/reference_peer.py` 当「电脑」：错误配对码 → `pair_required`；正确配对码配对成功；收到中文文字 + 中文文件名文件（字节一致）；`paired.json` / `friends.json` / `chats/<id>.json` 落盘 |
| 真实 Mac 落盘校验 | 用真实 macOS「文件互传助手」（本机 pichs）配对后发送 `Mac互传测试图片.png`（5025 B，sha256 `92793a84…`）和 `Mac互传测试视频.mp4`（412552 B，sha256 `db3ea359…`）：两份文件都落在 iPhone 17 容器 `Documents/Downloads/`，sha256 与 Mac 源文件完全一致；UI 显示「已保存到『文件』App 的『文件互传助手/Downloads』，并已存入系统相册」；系统「照片」App 新增该图片 |
| 旧目录迁移 | 在 iPhone 17 容器预置 `Documents/Received/旧版本遗留.txt` 后启动新版本 → 自动移动到 `Documents/Downloads/`，旧目录被清理，聊天记录里的旧路径同步修正 |
| 媒体预览 UI 测试 | `xcodebuild ... -scheme ADBTypeMobileUITests -destination '...iPhone 17...' test` → **TEST SUCCEEDED**（exit 0）：聊天气泡里图片 / 视频缩略图为 120×90pt，视频带播放图标；点击图片进入全屏查看器并双击放大、关闭；点击视频进入 AVKit 播放器（截图可见 00:00:03/00:00:04 播放进度与关闭按钮） |

验收设备：**iPhone 17 · iOS 26.5 模拟器**（UDID `34CBAC34-40A0-4318-A9B1-2DB088AD2FF8`）。
开发过程中的互通截图在 `build/screenshots/`（构建产物目录，不提交）。

## 未做 / 已知限制

- 不做 ADB / 手机输入 / 移动设备页（产品范围外）。
- 不支持后台常驻接收、iOS 端不监听 52730 以外的固定端口。
- 别名（alias）字段已按协议读写，但界面暂未提供改名入口。
- 一次发送只支持多选文件，不支持拖拽 / 文件夹；单文件大文件传输受前台状态限制。
- 相册副本只在用户授权「仅添加照片」时写入；拒绝 / 失败不影响 Downloads。
- 旧 `Documents/Received/` 自动迁移只处理顶层文件（子目录原样保留）。
- 仅 IPv4（与电脑端一致），无 TLS / 加密，不处理公网穿透。
