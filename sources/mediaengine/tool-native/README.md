# libmediaengine 原生媒体引擎

`libmediaengine.so` 是轻切的离线媒体引擎：单个 arm64-v8a 共享库，静态链接 FFmpeg 7.1.x、
若干外部编解码库，以及 FFmpeg 自带的 `ffmpeg` 命令行（fftools）和一个小型 JNI 桥。
Kotlin 端入口是 `com.rz.videoslicer.engine.NativeEngine`。

产物路径：`app/src/main/jniLibs/arm64-v8a/libmediaengine.so`（已加入 `.gitignore`，二进制不入库）。

## 目录

| 路径 | 说明 |
| --- | --- |
| `build-mediaengine.sh` | 一键构建脚本：下载并校验源码 → 交叉编译依赖 → 编译 FFmpeg → 编译 fftools 与 JNI 桥 → 链接、strip、复制、检查 |
| `sources.lock` | 每个组件的版本、许可证、SHA-256、下载地址；每次运行都会校验 |
| `bridge/mediaengine_jni.c` | JNI 桥：`runFfmpeg` / `probe` / `list` / `version`，`JNI_OnLoad` 中调用 `av_jni_set_java_vm` |
| `bridge/exports.map` | 链接版本脚本，只导出 `JNI_OnLoad` 与 `Java_com_rz_videoslicer_engine_NativeEngine_*` |
| `bridge/Makefile` | 由脚本调用，增量编译 fftools 与桥并链接 |
| `bridge/smoke_main.c`、`smoke-test.sh` | 冒烟测试：与 .so 同源的命令行程序 `mediaengine-smoke`，推到 adb 设备上跑一组编解码/滤镜/协议用例（不进入 APK） |

工作目录 `native-build/`（已忽略）：`downloads/` 源码包缓存，`venv/` 构建期 Python 工具，
`arm64-v8a/{build,prefix,stamps,logs,out}` 构建中间产物。

## 构建

前置条件（macOS 或 Linux x86_64 主机）：

- Android NDK `28.2.13676358`（默认取 `$ANDROID_HOME/ndk/28.2.13676358`，或设置 `ANDROID_NDK_HOME`）
- CMake（默认使用 Android SDK 的 `cmake/3.22.1`，也可用系统 cmake）
- `make`、`curl`、`tar`、`xz`、`perl`、`python3`（≥3.9）
- 不需要全局安装 meson / ninja / pkg-config / nasm：脚本会在 `native-build/venv` 中
  `pip install meson ninja pkgconf`（版本固定在脚本的 `PY_TOOLS`）。aarch64 汇编全部由 clang 处理，无需 nasm。

```bash
tool/native/build-mediaengine.sh          # 增量构建
tool/native/build-mediaengine.sh --clean  # 清掉中间产物后完整重建（保留下载缓存与 venv）
tool/native/build-mediaengine.sh --smoke  # 构建后在已连接的 arm64 设备/模拟器上跑冒烟测试（多设备用 ANDROID_SERIAL 指定）
```

可选环境变量：`MEDIAENGINE_JOBS`（并行度）、`MEDIAENGINE_WORK`（工作目录）、
`MEDIAENGINE_DOWNLOAD_CACHE`（源码包缓存目录，CI 可指向缓存卷）。

增量规则：每个依赖的 stamp 由「锁定行 + 构建函数体 + 编译器与公共参数 + 上游依赖 stamp」计算，
不变即跳过；FFmpeg 的 configure 参数或任一依赖变化时重新 configure，否则只跑增量 `make`；
fftools / JNI 桥由 `bridge/Makefile` 按时间戳与 `-MMD` 依赖增量编译。未改动时重跑只需数秒。

脚本结尾会自动检查：

- `llvm-readelf -d`：NEEDED 只能是 `libc.so libm.so libdl.so liblog.so libandroid.so libmediandk.so libz.so`，否则失败；
- `llvm-nm -D`：必须导出 4 个 JNI 函数和 `JNI_OnLoad`；
- 打印产物大小、已启用的编码器数量、MediaCodec 编码器、外部库编码器与协议清单。

日志位于 `native-build/arm64-v8a/logs/<组件>.log`，失败时脚本会输出日志末尾 60 行。

## 组件与许可证

FFmpeg 不启用 `--enable-gpl` / `--enable-nonfree`，启用 `--enable-version3`（为了 Apache-2.0 的
opencore-amr 与 vo-amrwbenc），**整体按 LGPL-3.0-or-later 分发**。未包含 x264、x265、xvid、
rubberband、vidstab、postproc 等任何 GPL 组件，也没有 openssl / gnutls。

| 组件 | 版本 | 许可证 | 用途 |
| --- | --- | --- | --- |
| FFmpeg | 7.1.5 | LGPL-2.1+（version3 → LGPL-3.0+） | 核心 |
| LAME (libmp3lame) | 3.100 | LGPL-2.0+ | MP3 编码 |
| Opus | 1.6.1 | BSD-3-Clause | Opus 编码（解码 FFmpeg 自带） |
| libogg / libvorbis | 1.3.6 / 1.3.7 | BSD-3-Clause | Vorbis 编码 |
| libtheora | 1.2.0 | BSD-3-Clause | Theora 编码 |
| libvpx | 1.17.0 | BSD-3-Clause | VP8/VP9 编解码 |
| libwebp | 1.6.0 | BSD-3-Clause | WebP（含动图）编码 |
| opencore-amr | 0.1.6 | Apache-2.0 | AMR-NB 编解码、AMR-WB 解码 |
| vo-amrwbenc | 0.1.3 | Apache-2.0 | AMR-WB 编码 |
| Speex | 1.2.1 | BSD-3-Clause | Speex 编解码 |
| SoX Resampler (libsoxr) | 0.1.3 | LGPL-2.1+ | 高质量重采样（`aresample=resampler=soxr`） |
| dav1d | 1.5.5 | BSD-2-Clause | AV1 软解 |
| OpenH264 | 2.7.0 | BSD-2-Clause | H.264 软件编码兜底（`libopenh264`） |
| FreeType | 2.14.3 | FTL（BSD 风格） | `drawtext` 与 libass 字体渲染 |
| FriBidi | 1.0.18 | LGPL-2.1+ | 双向文字 |
| HarfBuzz | 15.2.0 | MIT | 文字塑形 |
| libass | 0.17.5 | ISC | `subtitles` / `ass` 字幕烧录 |
| zlib | NDK 系统库 | zlib | 动态链接系统 `libz.so` |
| LLVM libc++ | NDK r28 | Apache-2.0 WITH LLVM-exception | 静态链接（OpenH264、HarfBuzz 为 C++） |

LGPL 义务提示：应用分发时需附带上述许可证文本与 FFmpeg 源码获取方式；由于本仓库提供完整、
可复现的构建脚本与锁定的源码地址，用户可以替换并重新链接该库（满足 LGPL 对可替换性的要求）。
OpenH264 为源码自行编译，不享受 Cisco 预编译二进制的 H.264 专利授权；如需规避，可在业务上优先使用
`h264_mediacodec`，仅在设备不支持时回退 `libopenh264`。

## 离线配置

FFmpeg 以纯离线方式配置：

- `--disable-network`：不编译任何网络代码，`avformat_network_init()` 为空操作；
- `--disable-protocols --enable-protocol=file,pipe,fd,concat,concatf,subfile,data,crypto`：
  只保留本地协议，没有 http / https / tcp / udp / rtmp / rtp / tls / hls 网络拉流等；
- `--disable-devices --enable-indev=lavfi`：不含任何采集/播放设备，只保留虚拟输入 `lavfi`
  （方便 `-f lavfi -i anullsrc` / `color` 这类生成静音、黑场的常见命令）；
- `--disable-autodetect`：不自动探测任何主机库，所有外部依赖都显式列出。

本地 m3u8 仍可通过 `hls` demuxer 读取（分片也必须是本地 `file:` 路径）。

## FFmpeg configure 参数

见 `build-mediaengine.sh` 的 `ffmpeg_configure_args`，要点：

```
--target-os=android --arch=aarch64 --cpu=armv8-a --enable-cross-compile
--enable-pic --enable-static --disable-shared --disable-programs --disable-doc --disable-debug
--enable-optimizations --enable-asm --enable-inline-asm --enable-neon -O3
--enable-version3 --disable-autodetect --disable-network
--disable-protocols --enable-protocol=file,pipe,fd,concat,concatf,subfile,data,crypto
--disable-devices --enable-indev=lavfi --enable-jni --enable-mediacodec
--enable-zlib --enable-iconv --enable-pthreads
--enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libtheora --enable-libvpx --enable-libwebp
--enable-libopencore-amrnb --enable-libopencore-amrwb --enable-libvo-amrwbenc --enable-libspeex --enable-libsoxr
--enable-libdav1d --enable-libopenh264 --enable-libass --enable-libfreetype --enable-libfribidi --enable-libharfbuzz
```

所有内置编解码器、封装/解封装器、滤镜、解析器、bsf 保持默认全部启用。

## fftools 集成

直接编译 FFmpeg 7.1 源码中的 `fftools/ffmpeg*.c`、`cmdutils.c`、`opt_common.c`、`objpool.c`、
`sync_queue.c`、`thread_queue.c`，**未修改任何 fftools 源码**，仅在编译 `ffmpeg.c` 时加
`-Dmain=mediaengine_ffmpeg_main`。全局状态不复位，因此约定每个任务在独立进程中只调用一次
`runFfmpeg`，进程结束即回收。

## Kotlin 端注意事项

- 只有 arm64-v8a；需在 Gradle 中限制 `abiFilters += "arm64-v8a"`，否则其他 ABI 设备装上后加载失败。
- 库已按 16 KB 页对齐（`-z max-page-size=16384`），`useLegacyPackaging` 可保持默认 `false`（不压缩、直接 mmap）。
- 只依赖系统库：`libc libm libdl liblog libandroid libmediandk libz`，无需随包附带 `libc++_shared.so`。
- `runFfmpeg` 的返回值就是 fftools `main` 的返回值：0 成功；失败可能是 1 或负的 AVERROR（如 -22）。
  收到 SIGINT/SIGTERM 时 ffmpeg 会尽量收尾并返回 255。
- 建议始终传 `-nostdin -hide_banner -y`（或 `-n`）；日志写到 `logFd`（会 `dup2` 到 stderr）；
  需要进度时用 `-progress pipe:2` 或 `-stats_period`，在日志 fd 中解析。
- MediaCodec 编码器（`h264_mediacodec`、`hevc_mediacodec`、`vp8_mediacodec`、`vp9_mediacodec`、
  `av1_mediacodec`、`mpeg4_mediacodec`）在设置了 JavaVM 时走 Java MediaCodec（通过 JNI），
  接收 `nv12` 或 `yuv420p` 缓冲帧（不同设备支持不同，`nv12` 兼容性最好），必须显式指定码率
  （`-b:v`），关键帧间隔用 `-g`；部分设备不支持 B 帧或特定 profile，失败时回退 `libopenh264`。
  MediaCodec 解码器（`h264_mediacodec` 等）需要用 `-c:v h264_mediacodec` 显式选择，否则默认走软解。
- libass 未接入 fontconfig：烧录字幕时用 `subtitles=file.srt:fontsdir=/system/fonts`（或应用私有字体目录）
  指定字体；`drawtext` 需显式给 `fontfile=`。
- 输入可以是 `/proc/self/fd/N`、`fd:` 协议或私有文件路径；`pipe:`、`fd:` 输出不可 seek，MP4 需 `-movflags frag_keyframe` 等。

## CI

```yaml
- uses: actions/cache@v4
  with:
    path: native-build/downloads
    key: mediaengine-src-${{ hashFiles('tool/native/sources.lock') }}
- run: sudo apt-get install -y gnupg   # 可选：启用 FFmpeg 签名校验
- run: tool/native/build-mediaengine.sh
  env:
    ANDROID_NDK_HOME: ${{ env.ANDROID_HOME }}/ndk/28.2.13676358
```

Linux runner 需要安装 NDK 28.2.13676358（`sdkmanager "ndk;28.2.13676358" "cmake;3.22.1"`）。
产物在 Gradle 构建前生成即可；也可把 `native-build/arm64-v8a` 整体缓存（key 加上脚本与 bridge 目录的哈希）以加速。
