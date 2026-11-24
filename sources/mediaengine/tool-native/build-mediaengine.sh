#!/usr/bin/env bash
# 可复现地构建 libmediaengine.so（arm64-v8a）：FFmpeg 7.1 + 外部编解码库 + fftools + JNI 桥。
# 用法：tool/native/build-mediaengine.sh [--clean] [--smoke]
#   --clean  删除中间产物后完整重建（保留下载缓存与 venv）
#   --smoke  额外构建 mediaengine-smoke 命令行，并在已连接的 adb 设备上做冒烟测试
# 环境变量：
#   ANDROID_NDK_HOME / ANDROID_NDK_ROOT  NDK 路径（默认 $ANDROID_HOME/ndk/28.2.13676358）
#   MEDIAENGINE_WORK                     工作目录（默认 <repo>/native-build）
#   MEDIAENGINE_JOBS                     并行度
#   MEDIAENGINE_DOWNLOAD_CACHE           源码包缓存目录（默认 $MEDIAENGINE_WORK/downloads）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCK_FILE="$SCRIPT_DIR/sources.lock"
BRIDGE_DIR="$SCRIPT_DIR/bridge"

ABI=arm64-v8a
API=29
TRIPLE=aarch64-linux-android
NDK_VERSION=28.2.13676358
# 构建期 Python 工具（仅装在工作目录的 venv 中）
PY_TOOLS="meson==1.12.1 ninja==1.13.2 pkgconf==3.0.7.post0"

WORK="${MEDIAENGINE_WORK:-$REPO_ROOT/native-build}"
DL="${MEDIAENGINE_DOWNLOAD_CACHE:-$WORK/downloads}"
VENV="$WORK/venv"
ROOT="$WORK/$ABI"
BUILD="$ROOT/build"
PREFIX="$ROOT/prefix"
STAMPS="$ROOT/stamps"
OUT="$ROOT/out"
JNI_DEST="$REPO_ROOT/app/src/main/jniLibs/$ABI"

log() { printf '\033[1;34m[mediaengine]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[mediaengine] 错误:\033[0m %s\n' "$*" >&2; exit 1; }

DO_CLEAN=0
DO_SMOKE=0
for arg in "$@"; do
  case "$arg" in
    --clean) DO_CLEAN=1 ;;
    --smoke) DO_SMOKE=1 ;;
    -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "未知参数 $arg" ;;
  esac
done
if [[ $DO_CLEAN == 1 ]]; then
  log "清理 $ROOT（保留下载缓存与 venv）"
  rm -rf "$ROOT"
fi

# ---------- 主机环境 ----------
case "$(uname -s)" in
  Darwin) HOST_TAG=darwin-x86_64; NCPU=$(sysctl -n hw.ncpu) ;;
  Linux) HOST_TAG=linux-x86_64; NCPU=$(nproc) ;;
  *) die "不支持的主机系统 $(uname -s)" ;;
esac
JOBS="${MEDIAENGINE_JOBS:-$NCPU}"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
hash_str() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -c1-16
  else printf '%s' "$1" | shasum -a 256 | cut -c1-16; fi
}

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}/ndk/$NDK_VERSION}}"
[[ -d "$NDK/toolchains/llvm/prebuilt/$HOST_TAG" ]] || die "找不到 NDK：$NDK（需要 $NDK_VERSION）"
grep -q "Pkg.Revision = $NDK_VERSION" "$NDK/source.properties" ||
  log "警告：NDK 版本不是 $NDK_VERSION，结果可能与锁定环境不同"
TC="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
SYSROOT="$TC/sysroot"
export CC="$TC/bin/${TRIPLE}${API}-clang"
export CXX="$TC/bin/${TRIPLE}${API}-clang++"
export AR="$TC/bin/llvm-ar"
export NM="$TC/bin/llvm-nm"
export RANLIB="$TC/bin/llvm-ranlib"
export STRIP="$TC/bin/llvm-strip"
export READELF="$TC/bin/llvm-readelf"
export AS="$CC"
export LD="$TC/bin/ld.lld"
COMMON_CFLAGS="-O3 -fPIC -ffunction-sections -fdata-sections -DANDROID"
export CFLAGS="$COMMON_CFLAGS"
export CXXFLAGS="$COMMON_CFLAGS"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib -Wl,-z,max-page-size=16384"

CMAKE_BIN="${CMAKE:-}"
if [[ -z "$CMAKE_BIN" ]]; then
  for c in "${ANDROID_HOME:-$HOME/Library/Android/sdk}/cmake/3.22.1/bin/cmake" "$(command -v cmake || true)"; do
    if [[ -n "$c" && -x "$c" ]]; then CMAKE_BIN="$c"; break; fi
  done
fi
[[ -n "$CMAKE_BIN" ]] || die "找不到 cmake（Android SDK cmake 3.22.1 或系统 cmake）"
command -v make >/dev/null || die "需要 make"
command -v python3 >/dev/null || die "需要 python3"

mkdir -p "$DL" "$BUILD" "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$STAMPS" "$OUT"

# 构建期工具 venv（meson / ninja / pkgconf），不污染全局环境
if [[ ! -f "$VENV/.tools" || "$(cat "$VENV/.tools")" != "$PY_TOOLS" ]]; then
  log "准备 Python venv：$PY_TOOLS"
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  # shellcheck disable=SC2086
  "$VENV/bin/pip" install -q --disable-pip-version-check $PY_TOOLS
  echo "$PY_TOOLS" > "$VENV/.tools"
fi
MESON="$VENV/bin/meson"
NINJA="$VENV/bin/ninja"
export PKG_CONFIG="$VENV/bin/pkgconf"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PATH="$VENV/bin:$PATH"

# ---------- 源码锁定与下载 ----------
# sources.lock 每行：name|version|license|sha256|url
lock_field() { # name field_index(1..5)
  local line
  line=$(grep -E "^$1\|" "$LOCK_FILE" | head -n1) || die "sources.lock 中没有 $1"
  printf '%s' "$line" | cut -d'|' -f"$2"
}
lock_line() { grep -E "^$1\|" "$LOCK_FILE" | head -n1; }

fetch() { # name -> 打印本地文件路径
  local name=$1 version sha url file
  version=$(lock_field "$name" 2); sha=$(lock_field "$name" 4); url=$(lock_field "$name" 5)
  file="$DL/${name}-${version}.tar.${url##*.tar.}"
  if [[ ! -f "$file" ]] || [[ "$(sha256_of "$file")" != "$sha" ]]; then
    log "下载 $name $version"
    rm -f "$file"
    # 网络不稳定：低速超时后断点续传重试
    local i rc ok=0
    for i in 1 2 3 4 5 6 7 8; do
      rc=0
      curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 --speed-limit 2048 --speed-time 60 \
        --max-time 1200 -C - -o "$file.part" "$url" || rc=$?
      if [[ $rc == 0 ]]; then ok=1; break; fi
      # 33：服务器不支持断点续传（如 GitHub 归档），只能从头下载
      if [[ $rc == 33 ]]; then rm -f "$file.part"; fi
      log "下载 $name 中断（curl $rc），第 $i 次重试"
      sleep 3
    done
    [[ $ok == 1 ]] || die "下载 $name 失败：$url"
    mv "$file.part" "$file"
  fi
  local got; got=$(sha256_of "$file")
  [[ "$got" == "$sha" ]] || { rm -f "$file"; die "$name 校验失败：期望 $sha，实际 $got"; }
  printf '%s' "$file"
}

verify_ffmpeg_signature() {
  local tarball=$1 version asc_url asc
  version=$(lock_field ffmpeg 2)
  asc_url="$(lock_field ffmpeg 5).asc"
  if ! command -v gpg >/dev/null 2>&1; then
    log "警告：主机没有 gpg，跳过 FFmpeg .asc 签名校验（已校验 SHA-256）"
    return 0
  fi
  asc="$DL/ffmpeg-$version.tar.xz.asc"
  [[ -s "$asc" ]] || curl -fsSL --retry 5 --retry-delay 3 --max-time 120 -o "$asc" "$asc_url"
  local gh; gh=$(mktemp -d)
  curl -fsSL --retry 5 --retry-delay 3 --max-time 120 -o "$gh/key.asc" https://ffmpeg.org/ffmpeg-devel.asc
  GNUPGHOME="$gh" gpg --batch --quiet --import "$gh/key.asc"
  # FFmpeg release signing key 指纹（ffmpeg.org/download.html 公布）
  GNUPGHOME="$gh" gpg --batch --with-colons --fingerprint 2>/dev/null |
    grep -q "FCF986EA15E6E293A5644F10B4322F04D67658D8" || { rm -rf "$gh"; die "FFmpeg 签名公钥指纹不匹配"; }
  GNUPGHOME="$gh" gpg --batch --verify "$asc" "$tarball" || { rm -rf "$gh"; die "FFmpeg 签名校验失败"; }
  rm -rf "$gh"
  log "FFmpeg 签名校验通过"
}

# 解压到全新目录并进入；打印源码目录
unpack() { # name -> 设置 SRC
  local name=$1 file dir
  file=$(fetch "$name")
  dir="$BUILD/$name"
  rm -rf "$dir"; mkdir -p "$dir"
  tar -xf "$file" -C "$dir" --strip-components=1
  SRC="$dir"
}

# 在子 shell 中运行并记录日志；不能写成 "( ... ) || ..."，那样子 shell 内的 set -e 会失效
run_logged() { # logfile command...
  local logfile=$1 rc; shift
  set +e
  ( set -euo pipefail; "$@" ) > "$logfile" 2>&1
  rc=$?
  set -e
  if [[ $rc != 0 ]]; then tail -n 60 "$logfile" >&2; fi
  return $rc
}

# 增量：配方（函数体）+ 锁定行 + 公共参数 + 依赖的 stamp 不变时跳过
run_step() { # name [deps...]
  local name=$1; shift
  # 调试用：MEDIAENGINE_ONLY="ogg vorbis" 只构建列出的依赖（列出 ffmpeg 时继续构建 FFmpeg 与链接）
  if [[ -n "${MEDIAENGINE_ONLY:-}" && " $MEDIAENGINE_ONLY " != *" $name "* ]]; then return 0; fi
  local key dep
  key="$(lock_line "$name" || true)|$(declare -f "build_$name")|$CC|$COMMON_CFLAGS|$API|$(cat "$MESON_CROSS")"
  for dep in "$@"; do key+="|$(cat "$STAMPS/$dep" 2>/dev/null || echo none)"; done
  local h; h=$(hash_str "$key")
  if [[ -f "$STAMPS/$name" && "$(cat "$STAMPS/$name")" == "$h" ]]; then
    log "跳过 $name（未变化）"
    return 0
  fi
  log "构建 $name"
  local t0=$SECONDS
  run_logged "$ROOT/logs/$name.log" "build_$name" || die "$name 构建失败，完整日志：$ROOT/logs/$name.log"
  echo "$h" > "$STAMPS/$name"
  log "完成 $name（$((SECONDS - t0))s）"
}
mkdir -p "$ROOT/logs"

AUTOCONF_ARGS=(--host="$TRIPLE" --prefix="$PREFIX" --enable-static --disable-shared --with-pic)

MESON_CROSS="$ROOT/android-cross.ini"
cat > "$MESON_CROSS.tmp" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
nm = '$NM'
strip = '$STRIP'
ranlib = '$RANLIB'
pkg-config = '$PKG_CONFIG'
pkgconfig = '$PKG_CONFIG'

[built-in options]
c_args = ['-O3', '-fPIC', '-ffunction-sections', '-fdata-sections', '-DANDROID', '-I$PREFIX/include']
cpp_args = ['-O3', '-fPIC', '-ffunction-sections', '-fdata-sections', '-DANDROID', '-I$PREFIX/include']
c_link_args = ['-L$PREFIX/lib', '-Wl,-z,max-page-size=16384']
cpp_link_args = ['-L$PREFIX/lib', '-Wl,-z,max-page-size=16384']

[properties]
pkg_config_libdir = '$PREFIX/lib/pkgconfig'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
EOF
cmp -s "$MESON_CROSS.tmp" "$MESON_CROSS" || mv "$MESON_CROSS.tmp" "$MESON_CROSS"
rm -f "$MESON_CROSS.tmp"

meson_build() { # srcdir [meson options...]
  local src=$1; shift
  # 不让 meson 读取主机的 pkg-config 环境
  env -u CC -u CXX -u AR -u NM -u RANLIB -u STRIP -u AS -u LD -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
    "$MESON" setup "$src/_build" "$src" --cross-file "$MESON_CROSS" \
      --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
      -Db_staticpic=true -Db_ndebug=true --wrap-mode=nodownload "$@"
  "$NINJA" -C "$src/_build" -j "$JOBS"
  "$NINJA" -C "$src/_build" install
}

# 合成 zlib.pc：使用 NDK sysroot 中的系统 libz.so
build_zlib_pc() {
  local ver
  ver=$(sed -n 's/^#define ZLIB_VERSION "\([^"]*\)".*/\1/p' "$SYSROOT/usr/include/zlib.h" | head -n1)
  cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<EOF
Name: zlib
Description: zlib from Android NDK sysroot (system libz.so)
Version: ${ver%%-*}
Libs: -lz
Cflags:
EOF
}

# ---------- 各依赖的构建配方 ----------
build_lame() {
  unpack lame; cd "$SRC"
  # lame 3.100 的符号表含已删除的 lame_init_old，静态构建时无影响；去掉以免 libtool 告警
  sed -i.bak '/lame_init_old/d' include/libmp3lame.sym
  # 发行构建关闭断言：psymodel.c 的 assert 遇到非有限采样会直接 abort 整个引擎进程
  CFLAGS="$COMMON_CFLAGS -DNDEBUG" ./configure "${AUTOCONF_ARGS[@]}" --disable-frontend --disable-decoder --disable-gtktest --disable-analyzer-hooks
  make -j"$JOBS" && make install
}

build_ogg() {
  unpack ogg; cd "$SRC"
  ./configure "${AUTOCONF_ARGS[@]}"
  make -j"$JOBS" && make install
}

build_vorbis() {
  unpack vorbis; cd "$SRC"
  ./configure "${AUTOCONF_ARGS[@]}" --with-ogg="$PREFIX" --disable-oggtest --disable-docs --disable-examples
  make -j"$JOBS" && make install
}

build_theora() {
  unpack theora; cd "$SRC"
  ./configure "${AUTOCONF_ARGS[@]}" --with-ogg="$PREFIX" --disable-oggtest --disable-vorbistest \
    --disable-examples --disable-spec --disable-doc --disable-sdltest
  make -j"$JOBS" && make install
}

build_opus() {
  unpack opus; cd "$SRC"
  ./configure "${AUTOCONF_ARGS[@]}" --disable-doc --disable-extra-programs
  make -j"$JOBS" && make install
}

build_speex() {
  unpack speex; cd "$SRC"
  ./configure "${AUTOCONF_ARGS[@]}" --disable-binaries
  make -j"$JOBS" && make install
}

build_opencore_amr() {
  unpack opencore_amr; cd "$SRC"
  ./configure "${AUTOCONF_ARGS[@]}" --disable-examples
  make -j"$JOBS" && make install
}

build_vo_amrwbenc() {
  unpack vo_amrwbenc; cd "$SRC"
  ./configure "${AUTOCONF_ARGS[@]}"
  make -j"$JOBS" && make install
}

build_webp() {
  unpack webp; cd "$SRC"
  ./configure "${AUTOCONF_ARGS[@]}" --enable-libwebpmux --enable-libwebpdemux \
    --disable-libwebpdecoder --disable-libwebpextras --disable-png --disable-jpeg --disable-tiff \
    --disable-gif --disable-gl --disable-sdl --disable-wic
  make -j"$JOBS" && make install
}

build_soxr() {
  unpack soxr; cd "$SRC"
  "$CMAKE_BIN" -S . -B _build -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=$ABI -DANDROID_PLATFORM=android-$API \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" -DCMAKE_POLICY_DEFAULT_CMP0057=NEW \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_OPENMP=OFF \
    -DWITH_LSR_BINDINGS=OFF -DWITH_AVFFT=OFF
  "$NINJA" -C _build -j "$JOBS"
  "$NINJA" -C _build install
}

build_vpx() {
  unpack vpx; cd "$SRC"
  # libvpx 的 android 目标默认只开实时编码；这里保留 good/best 质量档位
  ./configure --target=arm64-android-gcc --prefix="$PREFIX" --enable-pic --enable-static --disable-shared \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests --disable-install-bins \
    --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth --enable-runtime-cpu-detect \
    --disable-realtime-only --enable-multithread --extra-cflags="$COMMON_CFLAGS"
  make -j"$JOBS" && make install
}

build_dav1d() {
  unpack dav1d
  meson_build "$SRC" -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false
}

build_openh264() {
  unpack openh264
  meson_build "$SRC" -Dtests=disabled
  # openh264 是 C++；静态链接时由最终链接统一提供 libc++，避免 pkg-config 引入 -lstdc++
  sed -i.bak -e 's/-lstdc++//g' -e 's/-lc++//g' "$PREFIX/lib/pkgconfig/openh264.pc"
}

build_freetype() {
  unpack freetype
  meson_build "$SRC" -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled \
    -Dzlib=system -Dtests=disabled
}

build_fribidi() {
  unpack fribidi
  meson_build "$SRC" -Ddocs=false -Dbin=false -Dtests=false -Ddeprecated=false
}

build_harfbuzz() {
  unpack harfbuzz
  meson_build "$SRC" -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
    -Dchafa=disabled -Dicu=disabled -Dgraphite2=disabled -Dtests=disabled -Ddocs=disabled \
    -Dutilities=disabled -Dintrospection=disabled -Dbenchmark=disabled -Dcoretext=disabled \
    -Dpng=disabled -Dzlib=disabled -Draster=disabled -Dvector=disabled -Dgpu=disabled \
    -Dgpu_demo=disabled -Dsubset=disabled -Dwasm=disabled
}

build_libass() {
  unpack libass; cd "$SRC"
  # Android 无 fontconfig：字体通过 subtitles 滤镜的 fontsdir 或容器附件提供
  ./configure "${AUTOCONF_ARGS[@]}" --disable-fontconfig --disable-require-system-font-provider \
    --disable-libunibreak --disable-test --disable-compare --disable-profile --disable-fuzz
  make -j"$JOBS" && make install
}

FFMPEG_EXTERNAL=(
  libmp3lame libopus libvorbis libtheora libvpx libwebp
  libopencore-amrnb libopencore-amrwb libvo-amrwbenc libspeex libsoxr
  libdav1d libopenh264 libass libfreetype libfribidi libharfbuzz
)

# 设置全局数组 FF_ARGS（兼容 macOS 自带 bash 3.2，不用 mapfile）
ffmpeg_configure_args() {
  FF_ARGS=(
    --prefix="$PREFIX"
    --target-os=android --arch=aarch64 --cpu=armv8-a --enable-cross-compile
    --cc="$CC" --cxx="$CXX" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP"
    --sysroot="$SYSROOT"
    --pkg-config="$PKG_CONFIG" --pkg-config-flags=--static
    --extra-cflags="-O3 -fPIC -DANDROID -I$PREFIX/include"
    --extra-ldflags="-L$PREFIX/lib -Wl,-z,max-page-size=16384"
    --extra-libs="-lc++_static -lc++abi -lm"
    --enable-pic --enable-static --disable-shared
    --disable-programs --disable-doc --disable-debug --enable-optimizations
    --enable-asm --enable-inline-asm --enable-neon
    --enable-version3
    --disable-autodetect
    --disable-network
    --disable-protocols --enable-protocol=file,pipe,fd,concat,concatf,subfile,data,crypto
    --disable-devices --enable-indev=lavfi
    --enable-jni --enable-mediacodec
    --enable-zlib --enable-iconv --enable-pthreads
  )
  local l
  for l in "${FFMPEG_EXTERNAL[@]}"; do FF_ARGS+=("--enable-$l"); done
}

build_ffmpeg() {
  local file version src bdir
  file=$(fetch ffmpeg)
  verify_ffmpeg_signature "$file"
  version=$(lock_field ffmpeg 2)
  src="$BUILD/ffmpeg-src"
  bdir="$BUILD/ffmpeg"
  # 源码标记 = 版本 + 补丁内容哈希；任一变化都重新解压、打补丁并全量重建
  local marker="$version" p
  for p in "$SCRIPT_DIR"/patches/ffmpeg-*.patch; do marker+=" $(sha256_of "$p")"; done
  if [[ "$(cat "$src/.version" 2>/dev/null || true)" != "$marker" ]]; then
    rm -rf "$src" "$bdir"; mkdir -p "$src"
    tar -xf "$file" -C "$src" --strip-components=1
    for p in "$SCRIPT_DIR"/patches/ffmpeg-*.patch; do
      echo "应用补丁 ${p##*/}"
      patch -d "$src" -p1 --forward < "$p"
    done
    echo "$marker" > "$src/.version"
  fi
  mkdir -p "$bdir"; cd "$bdir"
  ffmpeg_configure_args
  local want; want=$(printf '%s\n' "${FF_ARGS[@]}")
  if [[ ! -f ffbuild/config.mak || "$(cat .configure-args 2>/dev/null || true)" != "$want" ]]; then
    "$src/configure" "${FF_ARGS[@]}"
    printf '%s' "$want" > .configure-args
  fi
  make -j"$JOBS"
  # make install 会重新 ranlib 改动时间戳，导致每次都重新链接；只在库确实更新时安装
  local l need=0
  for l in libavdevice libavcodec libavformat libavfilter libavutil libswresample libswscale; do
    if [[ "$bdir/$l/$l.a" -nt "$PREFIX/lib/$l.a" ]]; then need=1; fi
  done
  if [[ $need == 1 ]]; then make install; fi
}

# ---------- 执行 ----------
T_START=$SECONDS
run_step zlib_pc
run_step lame
run_step ogg
run_step vorbis ogg
run_step theora ogg
run_step opus
run_step speex
run_step opencore_amr
run_step vo_amrwbenc
run_step webp
run_step soxr
run_step vpx
run_step dav1d
run_step openh264
run_step freetype zlib_pc
run_step fribidi
run_step harfbuzz freetype
run_step libass freetype fribidi harfbuzz

if [[ -n "${MEDIAENGINE_ONLY:-}" && " $MEDIAENGINE_ONLY " != *" ffmpeg "* ]]; then
  log "MEDIAENGINE_ONLY 已设置，跳过 FFmpeg 与链接"; exit 0
fi

# FFmpeg 每次都进入 make（自身增量）；配置参数或依赖变化时重新 configure
ffmpeg_key="$(declare -f build_ffmpeg ffmpeg_configure_args)|$(lock_line ffmpeg)|$(cat "$SCRIPT_DIR"/patches/ffmpeg-*.patch)|$(for f in "$STAMPS"/*; do [[ "${f##*/}" == ffmpeg ]] || cat "$f"; done | tr '\n' ' ')"
ffmpeg_h=$(hash_str "$ffmpeg_key")
if [[ "$(cat "$STAMPS/ffmpeg" 2>/dev/null || true)" != "$ffmpeg_h" || ! -f "$PREFIX/lib/libavcodec.a" ]]; then
  rm -f "$BUILD/ffmpeg/.configure-args"
  run_step ffmpeg
  echo "$ffmpeg_h" > "$STAMPS/ffmpeg"
else
  log "FFmpeg 增量 make"
  run_logged "$ROOT/logs/ffmpeg-incremental.log" build_ffmpeg || die "FFmpeg 增量构建失败"
fi

# ---------- fftools + JNI 桥 + 链接 ----------
FFSRC="$BUILD/ffmpeg-src"
FFBUILD="$BUILD/ffmpeg"
# 复用 FFmpeg 自己的 CPPFLAGS/CFLAGS；SRC_PATH 在 config.mak 中是相对路径，这里改成绝对路径
FFTOOLS_FLAGS=$(make -s -f - SRC_PATH="$FFSRC" <<EOF
include $FFBUILD/ffbuild/config.mak
all: ; @echo \$(CPPFLAGS) \$(CFLAGS)
EOF
)
BRIDGE_FLAGS="-O2 -fPIC -std=c11 -Wall -Wextra -Wno-unused-parameter -ffunction-sections -fdata-sections -I$PREFIX/include"
LINK_LIBS="-L$PREFIX/lib $("$PKG_CONFIG" --static --libs libavdevice libavfilter libavformat libavcodec libswresample libswscale libavutil)"
EXTERNAL_LIBS="${FFMPEG_EXTERNAL[*]} mediacodec"

write_if_changed() { # file content
  if [[ ! -f "$1" || "$(cat "$1")" != "$2" ]]; then printf '%s' "$2" > "$1"; fi
}
write_if_changed "$OUT/fftools.flags" "$FFTOOLS_FLAGS"
write_if_changed "$OUT/bridge.flags" "$BRIDGE_FLAGS|$EXTERNAL_LIBS"
write_if_changed "$OUT/link.flags" "$LINK_LIBS"

log "编译 fftools 与 JNI 桥并链接"
make -s -f "$BRIDGE_DIR/Makefile" -j"$JOBS" \
  CC="$CC" CXX="$CXX" STRIP="$STRIP" OUT="$OUT" FFSRC="$FFSRC" FFBUILD="$FFBUILD" PREFIX="$PREFIX" \
  FFTOOLS_FLAGS="$FFTOOLS_FLAGS" BRIDGE_FLAGS="$BRIDGE_FLAGS" LINK_LIBS="$LINK_LIBS" \
  EXTERNAL_LIBS="$EXTERNAL_LIBS" > "$ROOT/logs/link.log" 2>&1 || {
  tail -n 60 "$ROOT/logs/link.log" >&2; die "链接失败，日志：$ROOT/logs/link.log"; }

SO="$OUT/libmediaengine.so"
mkdir -p "$JNI_DEST"
cmp -s "$SO" "$JNI_DEST/libmediaengine.so" || cp "$SO" "$JNI_DEST/libmediaengine.so"

# ---------- 产物检查 ----------
log "产物：$JNI_DEST/libmediaengine.so"
size_bytes=$(wc -c < "$JNI_DEST/libmediaengine.so" | tr -d ' ')
log "大小：$size_bytes 字节（$((size_bytes / 1024 / 1024)) MiB）"

needed=$("$READELF" -d "$SO" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' | tr '\n' ' ')
log "NEEDED：$needed"
for n in $needed; do
  case "$n" in
    libc.so|libm.so|libdl.so|liblog.so|libandroid.so|libmediandk.so|libz.so) ;;
    *) die "出现非系统依赖 $n" ;;
  esac
done

exports=$("$NM" -D --defined-only "$SO" | awk '{print $3}' | grep -E '^(JNI_OnLoad|Java_)' | sort)
printf '%s\n' "$exports" >&2
for s in JNI_OnLoad Java_com_rz_videoslicer_engine_NativeEngine_runFfmpeg \
         Java_com_rz_videoslicer_engine_NativeEngine_probe \
         Java_com_rz_videoslicer_engine_NativeEngine_list \
         Java_com_rz_videoslicer_engine_NativeEngine_version; do
  grep -qx "$s" <<<"$exports" || die "缺少导出符号 $s"
done
other=$("$NM" -D --defined-only "$SO" | awk '{print $3}' | grep -Ev '^(JNI_OnLoad|Java_)' || true)
[[ -z "$other" ]] || log "警告：额外导出的符号：$(echo "$other" | tr '\n' ' ')"

# 编进来的编码器/外部库概览（从 FFmpeg 生成的组件表读取）
log "已启用编码器 $(grep -c '_encoder,' "$FFBUILD/libavcodec/codec_list.c") 个，解码器 $(grep -c '_decoder,' "$FFBUILD/libavcodec/codec_list.c") 个，muxer $(grep -c '_muxer,' "$FFBUILD/libavformat/muxer_list.c") 个，demuxer $(grep -c '_demuxer,' "$FFBUILD/libavformat/demuxer_list.c") 个，滤镜 $(grep -c '&ff_' "$FFBUILD/libavfilter/filter_list.c") 个"
log "MediaCodec 编码器：$(sed -n 's/.*&ff_\(.*_mediacodec\)_encoder,/\1/p' "$FFBUILD/libavcodec/codec_list.c" | tr '\n' ' ')"
log "外部库编码器：$(sed -n 's/.*&ff_\(lib[a-z0-9_]*\)_encoder,/\1/p' "$FFBUILD/libavcodec/codec_list.c" | tr '\n' ' ')"
log "协议：$(sed -n 's/.*&ff_\(.*\)_protocol,/\1/p' "$FFBUILD/libavformat/protocol_list.c" | tr '\n' ' ')"
log "总耗时 $((SECONDS - T_START))s"

# ---------- 可选：设备冒烟测试 ----------
if [[ $DO_SMOKE == 1 ]]; then
  make -s -f "$BRIDGE_DIR/Makefile" -j"$JOBS" smoke \
    CC="$CC" CXX="$CXX" STRIP="$STRIP" OUT="$OUT" FFSRC="$FFSRC" FFBUILD="$FFBUILD" PREFIX="$PREFIX" \
    FFTOOLS_FLAGS="$FFTOOLS_FLAGS" BRIDGE_FLAGS="$BRIDGE_FLAGS" LINK_LIBS="$LINK_LIBS" \
    EXTERNAL_LIBS="$EXTERNAL_LIBS" > "$ROOT/logs/smoke-build.log" 2>&1 || {
    tail -n 60 "$ROOT/logs/smoke-build.log" >&2; die "冒烟测试程序构建失败"; }
  "$SCRIPT_DIR/smoke-test.sh" "$OUT/mediaengine-smoke" "$JNI_DEST/libmediaengine.so"
fi
