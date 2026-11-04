# 文件互传助手 2.1.0

局域网直连的电脑互传 + 手机 App。不登录、不传云、没有服务器。

## 本次更新

- **版本号统一**：macOS / Android / iOS / Windows 全部为 **2.1.0**；四端使用同一套局域网协议
  （UDP 52730 发现 + TCP 传输）与缓存格式，可以混用。
- **新增 Android 原生 App**（Kotlin + Jetpack Compose，Android 8.0+）：和同一 Wi-Fi 下的
  macOS / Windows 电脑发现、配对、互发文字和文件；图片 / 视频有缩略图，点击可查看。
- **新增 iOS 原生 App**（SwiftUI + AVKit，iOS 17+）：同样的发现 / 配对 / 互传，
  图片支持全屏查看、视频支持播放。
- **Windows 2.1.0**：功能与 2.0.1 一致（关闭窗口收进托盘、后台继续收发），版本号同步为 2.1.0，
  安装包和主程序的文件版本均为 `2.1.0.0`。
- **macOS 2.1.0**：功能与 2.0.1 一致，仅统一版本号。

## 下载

- macOS 13+（arm64 + x86_64）：`文件互传助手-2.1.0.dmg`
- Windows 10 1809+ / 11 x64：`文件互传助手-2.1.0-安装包.exe`
- Android 8.0+（API 28）：`文件互传助手-Android-2.1.0.apk`（debug 签名，可直接侧载）
- iOS 17+：`文件互传助手-iOS-2.1.0.ipa`（**未签名**，需用自己的 Apple Developer Team 重签）

## 校验值

| 文件 | SHA-256 |
| --- | --- |
| 文件互传助手-2.1.0.dmg | `cdc924a929f12ddf4c5e5b7a41edf4c4e8bd2eb0a01cc98aa06ad99632eb549c` |
| 文件互传助手-2.1.0-安装包.exe | `a6ea8ae0e4bbf0c7e6b5905d52332ce2ba8bac83736d0ef5dfbd23654f10570c` |
| 文件互传助手-Android-2.1.0.apk | `a36f221f682a52f589594b54b532904e1857523cfd8e24e6476df380b79505f0` |
| 文件互传助手-iOS-2.1.0.ipa | `f05e37d5a3c324f8c3139ec09bbff0bd1cbe7889fd6d4115f9bb4f09d2bd3bf7` |

macOS / Windows / iOS 均未做代码签名 / 公证（Android 为 debug 签名），首次打开可能被
Gatekeeper / SmartScreen 拦截，按 [安装说明](../release/安装说明.md) 放行或重新签名。

完整产品能力与核心技术见：[docs/product-and-tech.md](product-and-tech.md)
