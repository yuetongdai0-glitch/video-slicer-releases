/*
 * 仅用于设备冒烟测试的命令行入口（不进入 APK）：复用 JNI 桥的内部实现，
 * 在 adb shell 中直接验证 ffmpeg / probe / list / version。
 *   mediaengine-smoke ffmpeg <args...>
 *   mediaengine-smoke probe <path>
 *   mediaengine-smoke list <kind>
 *   mediaengine-smoke version
 */
#include "mediaengine_jni.c"

static void print_list(const char *kind) {
    Buf b = {0};
    void *it = NULL;
    if (!strcmp(kind, "encoders") || !strcmp(kind, "decoders")) {
        int enc = !strcmp(kind, "encoders");
        const AVCodec *c;
        while ((c = av_codec_iterate(&it)))
            if (enc ? av_codec_is_encoder(c) : av_codec_is_decoder(c)) list_add(&b, c->name);
    } else if (!strcmp(kind, "protocols")) {
        for (int output = 0; output <= 1; output++) {
            const char *name;
            it = NULL;
            while ((name = avio_enum_protocols(&it, output)))
                if (!list_contains(&b, name)) list_add(&b, name);
        }
    } else if (!strcmp(kind, "filters")) {
        const AVFilter *f;
        while ((f = av_filter_iterate(&it))) list_add(&b, f->name);
    }
    printf("%s\n", b.data ? b.data : "");
    free(b.data);
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "ffmpeg")) {
        argv[1] = "ffmpeg";
        return mediaengine_ffmpeg_main(argc - 1, argv + 1);
    }
    if (argc >= 3 && !strcmp(argv[1], "probe")) {
        char *json = probe_json(argv[2]);
        printf("%s\n", json ? json : "null");
        free(json);
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "list")) {
        print_list(argv[2]);
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "version")) {
        printf("%s mediaengine %s\n", av_version_info(), ME_EXTERNAL_LIBS);
        return 0;
    }
    fprintf(stderr, "usage: %s ffmpeg <args>|probe <path>|list <kind>|version\n", argv[0]);
    return 2;
}
