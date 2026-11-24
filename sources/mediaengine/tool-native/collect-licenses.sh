#!/usr/bin/env bash
# 从已校验的源码包中汇总第三方许可证，生成应用内“开源许可”页使用的文本。
# 用法：tool/native/collect-licenses.sh（需先运行过 build-mediaengine.sh，源码包在下载缓存中）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DL="${MEDIAENGINE_DOWNLOAD_CACHE:-${MEDIAENGINE_WORK:-$ROOT/native-build}/downloads}"
OUT="$ROOT/app/src/main/assets/licenses/third_party.txt"

# 组件名|源码包|包内许可证文件（空格分隔）|许可证
COMPONENTS=(
  "FFmpeg 7.1.5|ffmpeg-7.1.5.tar.xz|LICENSE.md COPYING.LGPLv3 COPYING.GPLv3|LGPL-3.0-or-later"
  "LAME 3.100|lame-3.100.tar.gz|COPYING|LGPL-2.0-or-later"
  "SoX Resampler 0.1.3|soxr-0.1.3.tar.xz|LICENCE|LGPL-2.1-or-later"
  "FriBidi 1.0.18|fribidi-1.0.18.tar.xz|COPYING|LGPL-2.1-or-later"
  "Opus 1.6.1|opus-1.6.1.tar.gz|COPYING|BSD-3-Clause"
  "libogg 1.3.6|ogg-1.3.6.tar.xz|COPYING|BSD-3-Clause"
  "libvorbis 1.3.7|vorbis-1.3.7.tar.xz|COPYING|BSD-3-Clause"
  "libtheora 1.2.0|theora-1.2.0.tar.xz|COPYING|BSD-3-Clause"
  "Speex 1.2.1|speex-1.2.1.tar.gz|COPYING|BSD-3-Clause"
  "libvpx 1.17.0|vpx-1.17.0.tar.gz|LICENSE PATENTS|BSD-3-Clause"
  "libwebp 1.6.0|webp-1.6.0.tar.gz|COPYING PATENTS|BSD-3-Clause"
  "dav1d 1.5.5|dav1d-1.5.5.tar.xz|COPYING|BSD-2-Clause"
  "OpenH264 2.7.0|openh264-2.7.0.tar.gz|LICENSE|BSD-2-Clause"
  "FreeType 2.14.3|freetype-2.14.3.tar.xz|LICENSE.TXT docs/FTL.TXT|FTL"
  "HarfBuzz 15.2.0|harfbuzz-15.2.0.tar.xz|COPYING|MIT"
  "libass 0.17.5|libass-0.17.5.tar.xz|COPYING|ISC"
  "opencore-amr 0.1.6|opencore_amr-0.1.6.tar.gz|LICENSE|Apache-2.0"
  "vo-amrwbenc 0.1.3|vo_amrwbenc-0.1.3.tar.gz|NOTICE COPYING|Apache-2.0"
)

extract() { # 源码包 包内相对路径 → 输出文件内容（包的顶层目录名不固定）
  local archive="$DL/$1" rel="$2" member
  member=$(tar -tf "$archive" | awk -v r="$rel" -F/ '{ p=$0; sub(/^[^\/]*\//, "", p); if (p == r) { print $0; exit } }')
  [[ -n "$member" ]] || { echo "缺少 $1 中的 $rel" >&2; exit 1; }
  tar -xOf "$archive" "$member"
}

mkdir -p "$(dirname "$OUT")"
{
  cat <<'EOF'
轻切使用的开源组件与许可证

轻切自身代码采用 MIT 许可。音视频处理由应用内置的媒体引擎 libmediaengine.so 完成，该库静态链接 FFmpeg 及下列组件，整体按 GNU 宽通用公共许可证第 3 版或更高版本（LGPL-3.0-or-later）分发，未启用任何 GPL 或 nonfree 组件，并且编译时关闭了全部网络协议。

源码获取与替换：引擎的构建脚本、锁定的源码地址与校验值、FFmpeg 补丁、JNI 桥接代码，以及 LGPL 组件的上游源码包，公开在 https://github.com/yuetongdai0-glitch/video-slicer-releases/tree/main/sources/mediaengine 。按其中说明可从官方源码复现该库，也可以用自行修改、重新编译的版本替换 APK 中的 libmediaengine.so。

其他组件：
- PdfBox-Android 2.0.27.0（Tom Roush，基于 Apache PDFBox，Apache Software Foundation）：Apache-2.0
- LiteRT 1.4.2（Google）：Apache-2.0
- AndroidX（含 Media3、HeifWriter，Google / The Android Open Source Project）：Apache-2.0
- Kotlin 标准库（JetBrains）：Apache-2.0
- Guava（Google）：Apache-2.0
- 人像分割模型 selfie_segmenter（Google MediaPipe）：Apache-2.0
- 超分辨率模型 ESRGAN x4（captain-pool/esrgan-tf2）：Apache-2.0
- 人声伴奏分离模型（由 Deezer Spleeter 2stems 权重转换）：MIT，Copyright (c) 2019-present Deezer SA
- LLVM libc++（随 Android NDK 静态链接）：Apache-2.0 WITH LLVM-exception
Apache-2.0 全文见下方 opencore-amr 一节。

EOF
  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r name archive files license <<<"$entry"
    printf '\n========================================\n'
    printf '%s（%s）\n' "$name" "$license"
    printf '========================================\n'
    for f in $files; do
      printf '\n--- %s ---\n\n' "$f"
      extract "$archive" "$f"
    done
  done
} > "$OUT"
echo "已生成 ${OUT#$ROOT/}（$(wc -c < "$OUT" | tr -d ' ') 字节）"
