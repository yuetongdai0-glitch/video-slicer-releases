#!/usr/bin/env bash
# 在已连接的 arm64 设备/模拟器上冒烟测试 mediaengine-smoke（与 libmediaengine.so 同源的命令行版本）。
# 用法：tool/native/smoke-test.sh <mediaengine-smoke 路径> [libmediaengine.so 路径]；多设备时用 ANDROID_SERIAL 指定。
# 给出 .so 且主机有 javac 与 build-tools d8 时，还会用 app_process 通过真实 JNI 调用 .so（含 Java MediaCodec 路径）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${1:?需要 mediaengine-smoke 路径}"
SO="${2:-}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="${ADB:-$(command -v adb || echo "$SDK/platform-tools/adb")}"
[[ -x "$ADB" ]] || { echo "[smoke] 找不到 adb，跳过冒烟测试" >&2; exit 0; }
if [[ -z "${ANDROID_SERIAL:-}" ]]; then
  ANDROID_SERIAL=$("$ADB" devices </dev/null | awk 'NR > 1 && $2 == "device" {print $1; exit}')
  [[ -n "$ANDROID_SERIAL" ]] || { echo "[smoke] 没有已连接的设备，跳过冒烟测试" >&2; exit 0; }
  export ANDROID_SERIAL
fi
abi=$("$ADB" shell getprop ro.product.cpu.abi </dev/null | tr -d '\r')
[[ "$abi" == arm64-v8a ]] || { echo "[smoke] 设备 ABI 为 $abi，需要 arm64-v8a，跳过" >&2; exit 0; }

D=/data/local/tmp/mediaengine-smoke
PASS=0
FAIL=0
FAILED=""
sh_dev() { "$ADB" shell "cd $D && $1" </dev/null; }
check() { # 名称 命令（在设备上执行）
  local name=$1 cmd=$2
  if sh_dev "$cmd" > /dev/null 2>"$TMP_LOG"; then
    PASS=$((PASS + 1)); echo "[smoke] 通过  $name" >&2
  else
    FAIL=$((FAIL + 1)); FAILED+=" $name"; echo "[smoke] 失败  $name" >&2
    sh_dev "cat last.log 2>/dev/null | tail -n 15" >&2 || true
  fi
}
TMP_LOG=$(mktemp)
trap 'rm -f "$TMP_LOG"; "$ADB" shell rm -rf "$D" </dev/null >/dev/null 2>&1 || true' EXIT

echo "[smoke] 设备 $ANDROID_SERIAL（$abi，SDK $("$ADB" shell getprop ro.build.version.sdk </dev/null | tr -d '\r')）" >&2
"$ADB" shell "rm -rf $D && mkdir -p $D" </dev/null
"$ADB" push "$BIN" "$D/me" >/dev/null
"$ADB" shell chmod 755 "$D/me" </dev/null

echo "[smoke] $(sh_dev './me version')" >&2
enc=$(sh_dev './me list encoders')
dec=$(sh_dev './me list decoders')
proto=$(sh_dev './me list protocols')
echo "[smoke] 协议：$proto" >&2
for e in libmp3lame libopus libvorbis libtheora libvpx libvpx-vp9 libwebp libwebp_anim libopencore_amrnb \
         libvo_amrwbenc libspeex libopenh264 h264_mediacodec hevc_mediacodec aac flac alac gif apng mpeg4 ac3 eac3 mp2; do
  if [[ ",$enc," == *",$e,"* ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILED+=" encoder:$e"; fi
done
for d in libdav1d libopencore_amrnb libopencore_amrwb h264_mediacodec hevc_mediacodec ape tak wmav2 h264 hevc vp9 av1; do
  if [[ ",$dec," == *",$d,"* ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILED+=" decoder:$d"; fi
done
for p in http https tcp udp rtmp rtp tls; do
  if [[ ",$proto," == *",$p,"* ]]; then FAIL=$((FAIL + 1)); FAILED+=" 不应存在协议:$p"; fi
done

FF='./me ffmpeg -nostdin -hide_banner -loglevel error -y'
V='-f lavfi -i testsrc2=size=640x360:rate=30:duration=2'
A='-f lavfi -i sine=frequency=440:duration=2:sample_rate=48000'
check "libopenh264+aac → mp4"     "$FF $V $A -c:v libopenh264 -b:v 1M -c:a aac -shortest h264.mp4 2>last.log"
check "probe mp4"                  "./me probe h264.mp4 | grep -q '\"codec\":\"h264\"'"
check "关键帧原包复制切段"            "$FF -ss 0.5 -i h264.mp4 -t 1 -c copy -avoid_negative_ts make_zero copy.mkv 2>last.log"
check "libvpx-vp9+libopus → webm"  "$FF $V $A -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 500k -c:a libopus -shortest vp9.webm 2>last.log"
check "libvpx-vp8+libvorbis → webm" "$FF $V $A -c:v libvpx -deadline good -cpu-used 5 -b:v 500k -c:a libvorbis -shortest vp8.webm 2>last.log"
check "libtheora+libvorbis → ogv"  "$FF $V $A -c:v libtheora -q:v 5 -c:a libvorbis -shortest th.ogv 2>last.log"
check "libmp3lame → mp3"           "$FF $A -c:a libmp3lame -b:a 128k a.mp3 2>last.log"
check "libopencore_amrnb → amr"    "$FF $A -ar 8000 -ac 1 -c:a libopencore_amrnb -b:a 12.2k a.amr 2>last.log"
check "libvo_amrwbenc → amr-wb"    "$FF $A -ar 16000 -ac 1 -c:a libvo_amrwbenc -b:a 23.85k awb.amr 2>last.log"
check "amr 解码"                    "$FF -i a.amr -i awb.amr -map 0 -f null - -map 1 -f null - 2>last.log"
check "libspeex → ogg"             "$FF $A -ar 16000 -ac 1 -c:a libspeex sp.ogg 2>last.log"
check "soxr 重采样 → flac"          "$FF $A -af aresample=resampler=soxr -ar 44100 a.flac 2>last.log"
check "libwebp 动图"                "$FF $V -t 1 -vf scale=320:-2 -c:v libwebp_anim -loop 0 a.webp 2>last.log"
check "gif"                        "$FF $V -t 1 -vf scale=320:-2 a.gif 2>last.log"
check "drawtext(freetype+harfbuzz)" "$FF $V -t 1 -vf \"drawtext=fontfile=/system/fonts/Roboto-Regular.ttf:text='Hello 123':fontsize=40:x=10:y=10\" -c:v mpeg4 dt.mp4 2>last.log"
check "subtitles 烧录(libass)"      "printf '1\\n00:00:00,000 --> 00:00:02,000\\nHello 字幕 test\\n' > s.srt && $FF $V -t 1 -vf subtitles=s.srt:fontsdir=/system/fonts -c:v mpeg4 sub.mp4 2>last.log"
check "h264_mediacodec 编码"        "$FF $V -pix_fmt nv12 -c:v h264_mediacodec -b:v 2M mc.mp4 2>last.log"
check "h264_mediacodec 解码"        "$FF -c:v h264_mediacodec -i h264.mp4 -f null - 2>last.log"
check "file/concat 协议"            "printf \"file 'h264.mp4'\\nfile 'h264.mp4'\\n\" > l.txt && $FF -f concat -safe 0 -i l.txt -c copy cat.mp4 2>last.log"
check "网络协议已禁用"               "./me ffmpeg -nostdin -hide_banner -i http://127.0.0.1/x.mp4 -f null - 2>&1 | grep -q 'Protocol not found'"

# ---------- JNI 层：app_process 加载 .so，调用 NativeEngine 的 4 个 native 方法 ----------
jni_smoke() {
  local bt android_jar work out
  bt=$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -n1)
  android_jar=$(ls -d "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -n1)
  if [[ -z "$SO" || -z "$bt" || ! -x "$bt/d8" || -z "$android_jar" ]] || ! command -v javac >/dev/null; then
    echo "[smoke] 缺少 .so / javac / d8 / android.jar，跳过 JNI 冒烟测试" >&2
    return 0
  fi
  work=$(mktemp -d)
  javac --release 11 -nowarn -cp "$android_jar" -d "$work/classes" \
    "$SCRIPT_DIR"/jni-smoke/com/rz/videoslicer/engine/*.java 2>/dev/null
  "$bt/d8" --release --min-api 29 --lib "$android_jar" --output "$work/smoke.jar" \
    $(find "$work/classes" -name '*.class')
  "$ADB" push "$SO" "$D/libmediaengine.so" >/dev/null
  "$ADB" push "$work/smoke.jar" "$D/smoke.jar" >/dev/null
  rm -rf "$work"
  out=$("$ADB" shell "CLASSPATH=$D/smoke.jar app_process / com.rz.videoslicer.engine.SmokeMain $D" </dev/null 2>&1 | tr -d '\r')
  echo "$out" | sed 's/^/[smoke][jni] /' >&2
  local ok=1
  grep -q '^version=.*mediaengine' <<<"$out" || ok=0
  grep -q '^encoders.h264_mediacodec=true' <<<"$out" || ok=0
  grep -q '^runFfmpeg.rc=0' <<<"$out" || ok=0
  grep -q '^probe={"format":{"name":"mov,mp4' <<<"$out" || ok=0
  grep -q '^probe.missing={"error":' <<<"$out" || ok=0
  if [[ $ok == 1 ]]; then
    PASS=$((PASS + 1)); echo "[smoke] 通过  JNI（app_process + Java MediaCodec 编码 + 中文/emoji 路径）" >&2
  else
    FAIL=$((FAIL + 1)); FAILED+=" JNI"; echo "[smoke] 失败  JNI" >&2
    sh_dev "tail -n 20 jni.log" >&2 || true
  fi
}
jni_smoke

echo "[smoke] 通过 $PASS 项，失败 $FAIL 项${FAILED:+：$FAILED}" >&2
[[ $FAIL == 0 ]]
