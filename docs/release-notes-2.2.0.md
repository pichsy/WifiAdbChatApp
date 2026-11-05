# 文件互传助手 2.2.0 发布说明

发布日期：2026-11-05

## 版本

| 平台 | 版本 | 安装包 |
| --- | --- | --- |
| macOS | 2.2.0 | `文件互传助手-2.2.0.dmg` |
| Android | 2.2.0 | `文件互传助手-Android-2.2.0.apk` |
| iOS | 2.2.0 | `文件互传助手-iOS-2.2.0.ipa` |
| Windows | 2.2.0 | `文件互传助手-2.2.0-安装包.exe` |

## Windows

- 「移动设备」页新增 **ADB 截屏**：设备卡片点「截屏」，通过 `adb exec-out screencap -p` 抓取手机当前屏幕；
- 截屏在独立窗口预览，可拖四角 / 四边缩放；支持刷新重截、保存、选择保存目录（默认系统「下载」），
  保存成功弹 toast；左下角「保存到：…」后面有**文件夹按钮**，一点就在资源管理器里定位最近保存的
  截屏（还没保存过就打开保存目录）；
- 预览支持滚轮缩放、放大后拖拽平移、1:1 恢复适应窗口，缩放百分比显示在按钮上方；
- 顶部「移动设备 / 电脑设备」改成 macOS 风格的居中胶囊页签；主窗口和截屏窗口在 Windows 11
  使用 DWM 圆角，Windows 10 自动退回圆角窗口区域；
- 与 2.1.0 协议、缓存格式完全一致，**覆盖安装即可升级**，聊天记录 / 配对关系 / 收到的文件不受影响。

## macOS

- 「移动设备」页新增手机截屏：设备卡片点「截屏」，通过 `adb exec-out screencap -p` 抓取当前屏幕；
- 截屏窗口可拖四角/四边缩放，支持刷新、保存、选择保存目录（默认系统「下载」）；
- 预览支持触控板捏合缩放、放大后拖拽平移、双击缩放、1:1 恢复适应窗口；
- 缩放百分比显示在 1:1 按钮上方；保存成功显示「截屏已保存」toast。

## Android

- 版本号同步到 2.2.0（versionCode 13）；
- 接收文件保存在公共 `Download/文件互传助手/`，图片/视频消息有 120×90 缩略图和全屏预览；
- APK 已用项目 release key 签名，可直接侧载；与之前 debug 签名版本不兼容，首次安装需先卸载旧版。
- keystore / 密码保留在本地 `mobile/android/keystore/`，不提交仓库；后续升级请继续使用同一密钥。

## iOS

- 版本号同步到 2.2.0（build 13）；
- 接收文件在「文件」App › 我的 iPhone › 文件互传助手 › Downloads，图片/视频另存系统相册；
- 图片/视频消息有固定缩略图，点击全屏缩放/AVKit 播放；
- IPA 未签名，需要自己的 Apple Developer Team 重签后才能装真机。

## 升级说明

- Windows：直接运行 `文件互传助手-2.2.0-安装包.exe`，选原来的安装目录覆盖安装即可；
- macOS：直接下载 dmg，拖进「应用程序」覆盖旧版；
- Android：使用 `adb install -r 文件互传助手-Android-2.2.0.apk` 或直接侧载；
- iOS：用 Xcode 重签 IPA 后安装。

## 校验值

| 文件 | SHA-256 |
| --- | --- |
| 文件互传助手-2.2.0.dmg | `c2e3bbc4a50b2d61ddba242e0d510532da61203841bfba1f0a4a3a04ccd30c86` |
| 文件互传助手-2.2.0-安装包.exe | `60ce64db9c6c253c7e398d683ea5dbfeee34f75a060e7da2ded513549b832ac2` |
| 文件互传助手-Android-2.2.0.apk | `0bcbeccbe83978f1ec2ba4532f10d6d2932da8b3cd1f3f43ce158099d8e470eb` |
| 文件互传助手-iOS-2.2.0.ipa | `84a9122d811cc6c403d6ddb37fedfb9f84892456c723c67f12ffc45f0ec58d81` |

Windows / macOS / iOS 均未做代码签名 / 公证（Android 为项目 release key 签名），首次打开可能被
SmartScreen / Gatekeeper 拦截，按 [安装说明](../release/安装说明.md) 放行或重新签名。

校验值也可在 [`release/SHA256SUMS.txt`](../release/SHA256SUMS.txt) 里查到。

完整产品能力与核心技术见：[docs/product-and-tech.md](product-and-tech.md)
