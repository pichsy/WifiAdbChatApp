# 文件互传助手 2.2.0 发布说明

发布日期：2026-11-05

## 版本

| 平台 | 版本 | 安装包 |
| --- | --- | --- |
| macOS | 2.2.0 | `文件互传助手-2.2.0.dmg` |
| Android | 2.2.0 | `文件互传助手-Android-2.2.0.apk` |
| iOS | 2.2.0 | `文件互传助手-iOS-2.2.0.ipa` |
| Windows | 2.1.0 | `文件互传助手-2.1.0-安装包.exe`（本轮未重打） |

## macOS

- 「移动设备」页新增手机截屏：设备卡片点「截屏」，通过 `adb exec-out screencap -p` 抓取当前屏幕；
- 截屏窗口可拖四角/四边缩放，支持刷新、保存、选择保存目录（默认系统「下载」）；
- 预览支持触控板捏合缩放、放大后拖拽平移、双击缩放、1:1 恢复适应窗口；
- 缩放百分比显示在 1:1 按钮上方；保存成功显示「截屏已保存」toast。

## Android

- 版本号同步到 2.2.0（versionCode 13）；
- 接收文件保存在公共 `Download/文件互传助手/`，图片/视频消息有 120×90 缩略图和全屏预览；
- APK 为 debug 签名，可直接侧载；正式分发请换 release keystore。

## iOS

- 版本号同步到 2.2.0（build 13）；
- 接收文件在「文件」App › 我的 iPhone › 文件互传助手 › Downloads，图片/视频另存系统相册；
- 图片/视频消息有固定缩略图，点击全屏缩放/AVKit 播放；
- IPA 未签名，需要自己的 Apple Developer Team 重签后才能装真机。

## 升级说明

- macOS 直接下载 dmg，拖进「应用程序」覆盖旧版；
- Android 使用 `adb install -r 文件互传助手-Android-2.2.0.apk` 或直接侧载；
- iOS 用 Xcode 重签 IPA 后安装；
- Windows 暂仍使用 2.1.0 安装包，待下一轮重新构建。

校验值见 [`release/SHA256SUMS.txt`](../release/SHA256SUMS.txt)。
