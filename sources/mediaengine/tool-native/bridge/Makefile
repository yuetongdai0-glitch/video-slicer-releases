# 由 build-mediaengine.sh 调用：编译 fftools + JNI 桥并链接 libmediaengine.so。
# 需要的变量：CC CXX OUT FFSRC FFBUILD PREFIX FFTOOLS_FLAGS BRIDGE_FLAGS LINK_LIBS EXTERNAL_LIBS
BRIDGE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

FFTOOLS_SRCS := ffmpeg.c ffmpeg_dec.c ffmpeg_demux.c ffmpeg_enc.c ffmpeg_filter.c \
                ffmpeg_hw.c ffmpeg_mux.c ffmpeg_mux_init.c ffmpeg_opt.c ffmpeg_sched.c \
                objpool.c sync_queue.c thread_queue.c cmdutils.c opt_common.c
FFTOOLS_OBJS := $(addprefix $(OUT)/fftools/,$(FFTOOLS_SRCS:.c=.o))
BRIDGE_OBJS  := $(OUT)/bridge/mediaengine_jni.o
FFMPEG_LIBS  := $(wildcard $(PREFIX)/lib/*.a)
SO           := $(OUT)/libmediaengine.so

all: $(SO)

# main 重命名后没有原型声明，FFmpeg 默认 -Werror=missing-prototypes，需单独放开
$(OUT)/fftools/ffmpeg.o: EXTRA_DEFS := -Dmain=mediaengine_ffmpeg_main -Wno-missing-prototypes

$(OUT)/fftools/%.o: $(FFSRC)/fftools/%.c $(FFBUILD)/config.h $(OUT)/fftools.flags
	@mkdir -p $(@D)
	$(CC) $(FFTOOLS_FLAGS) $(EXTRA_DEFS) -I$(FFBUILD) -I$(FFSRC) -MMD -MP -c $< -o $@

$(OUT)/bridge/%.o: $(BRIDGE_DIR)%.c $(OUT)/bridge.flags
	@mkdir -p $(@D)
	$(CC) $(BRIDGE_FLAGS) '-DME_EXTERNAL_LIBS="$(EXTERNAL_LIBS)"' -MMD -MP -c $< -o $@

$(SO): $(FFTOOLS_OBJS) $(BRIDGE_OBJS) $(FFMPEG_LIBS) $(BRIDGE_DIR)exports.map $(OUT)/link.flags
	$(CXX) -shared -o $@.unstripped -Wl,-soname,libmediaengine.so \
	  $(BRIDGE_OBJS) $(FFTOOLS_OBJS) $(LINK_LIBS) \
	  -static-libstdc++ -Wl,--version-script=$(BRIDGE_DIR)exports.map \
	  -Wl,--gc-sections -Wl,--no-undefined -Wl,--exclude-libs,ALL -Wl,--build-id=sha1 \
	  -Wl,-z,max-page-size=16384 -Wl,-z,noexecstack -Wl,-z,relro -Wl,-z,now
	$(STRIP) --strip-unneeded -o $@ $@.unstripped

# 设备冒烟测试用的可执行文件（不进入 APK）
SMOKE := $(OUT)/mediaengine-smoke
smoke: $(SMOKE)

$(OUT)/bridge/smoke_main.o: $(BRIDGE_DIR)smoke_main.c $(BRIDGE_DIR)mediaengine_jni.c $(OUT)/bridge.flags
	@mkdir -p $(@D)
	$(CC) $(BRIDGE_FLAGS) '-DME_EXTERNAL_LIBS="$(EXTERNAL_LIBS)"' -Wno-unused-function -MMD -MP -c $< -o $@

$(SMOKE): $(OUT)/bridge/smoke_main.o $(FFTOOLS_OBJS) $(FFMPEG_LIBS) $(OUT)/link.flags
	$(CXX) -pie -o $@ $(OUT)/bridge/smoke_main.o $(FFTOOLS_OBJS) $(LINK_LIBS) -static-libstdc++ \
	  -Wl,--gc-sections -Wl,-z,max-page-size=16384
	$(STRIP) --strip-unneeded $@

-include $(FFTOOLS_OBJS:.o=.d) $(BRIDGE_OBJS:.o=.d) $(OUT)/bridge/smoke_main.d

.PHONY: all smoke
