# 轻切媒体引擎源码

`libmediaengine.so` 静态链接 FFmpeg 7.1.5 与若干编解码库，整体按 LGPL-3.0-or-later 分发，未启用 GPL / nonfree 组件，并关闭全部网络协议。

- `tool-native/`：一键构建脚本、锁定的组件版本与 SHA-256（`sources.lock`）、FFmpeg 补丁、JNI 桥接与冒烟测试。
- `upstream/`：LGPL 组件（FFmpeg、LAME、SoX Resampler、FriBidi）的官方源码包；其他组件按 `sources.lock` 中的官方地址与校验值获取。

按 `tool-native/README.md` 运行 `build-mediaengine.sh` 即可从源码复现该库；用自行修改并重新编译的库替换 APK 中 `lib/arm64-v8a/libmediaengine.so` 后重新签名即可运行。
