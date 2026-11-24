# 轻切 Android 发布仓库

离线视频切片与本地工具箱，保存最新安卓安装包、更新清单与内置媒体引擎的对应源码。

- [下载安装页](https://yuetongdai0-glitch.github.io/video-slicer-releases/)
- [直接下载 APK](https://yuetongdai0-glitch.github.io/video-slicer-releases/releases/android/latest.apk?v=6)
- [更新清单](https://yuetongdai0-glitch.github.io/video-slicer-releases/update.json)
- 当前版本：2.0.0（6），Android 10+
- SHA-256：`74490c2363e3c6a9910fd44d9830215538441581844bf8b87728dff4341c5f0a`

应用内仅在用户主动检查或下载更新时联网。无账号、广告、统计和视频上传。源码由 `yuetongdai0-glitch/video-slicer` 单独管理。发布签名保存在源码仓库外，不公开。

应用内置的媒体引擎 `libmediaengine.so` 基于 FFmpeg，按 LGPL-3.0-or-later 分发；构建脚本、补丁、JNI 桥接代码与 LGPL 组件的上游源码包见 [sources/mediaengine](sources/mediaengine/)，可据此复现或替换该库。
