/*
 * libmediaengine JNI 桥：对应 Kotlin 端 com.rz.videoslicer.engine.NativeEngine。
 * 每个任务在独立进程中运行，进程结束即回收 ffmpeg 的全局状态。
 */
#include <errno.h>
#include <jni.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavcodec/jni.h>
#include <libavfilter/avfilter.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/pixdesc.h>

#ifndef ME_EXTERNAL_LIBS
#define ME_EXTERNAL_LIBS ""
#endif

/* fftools/ffmpeg.c 的 main 在编译时被重命名为此符号。 */
int mediaengine_ffmpeg_main(int argc, char **argv);

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    av_jni_set_java_vm(vm, NULL);
    return JNI_VERSION_1_6;
}

/* ---------- 简单的可增长字符串缓冲 ---------- */

typedef struct {
    char *data;
    size_t len;
    size_t cap;
    int oom;
} Buf;

static void buf_reserve(Buf *b, size_t extra) {
    if (b->oom) return;
    if (b->len + extra + 1 <= b->cap) return;
    size_t cap = b->cap ? b->cap : 1024;
    while (cap < b->len + extra + 1) cap *= 2;
    char *p = realloc(b->data, cap);
    if (!p) {
        b->oom = 1;
        return;
    }
    b->data = p;
    b->cap = cap;
}

static void buf_append(Buf *b, const char *s, size_t n) {
    buf_reserve(b, n);
    if (b->oom) return;
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
}

static void buf_puts(Buf *b, const char *s) { buf_append(b, s, strlen(s)); }

static void buf_printf(Buf *b, const char *fmt, ...) {
    char tmp[256];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n < sizeof(tmp)) {
        buf_append(b, tmp, (size_t)n);
        return;
    }
    buf_reserve(b, (size_t)n);
    if (b->oom) return;
    va_start(ap, fmt);
    vsnprintf(b->data + b->len, (size_t)n + 1, fmt, ap);
    va_end(ap);
    b->len += (size_t)n;
}

/* JSON 字符串转义；非法 UTF-8 在 new_jstring 中统一替换。 */
static void buf_json_str(Buf *b, const char *s) {
    if (!s) {
        buf_puts(b, "null");
        return;
    }
    buf_puts(b, "\"");
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"': buf_puts(b, "\\\""); break;
        case '\\': buf_puts(b, "\\\\"); break;
        case '\n': buf_puts(b, "\\n"); break;
        case '\r': buf_puts(b, "\\r"); break;
        case '\t': buf_puts(b, "\\t"); break;
        default:
            if (*p < 0x20) buf_printf(b, "\\u%04x", *p);
            else buf_append(b, (const char *)p, 1);
        }
    }
    buf_puts(b, "\"");
}

static void json_key(Buf *b, int *first, const char *key) {
    if (!*first) buf_puts(b, ",");
    *first = 0;
    buf_json_str(b, key);
    buf_puts(b, ":");
}

static void json_kv_str(Buf *b, int *first, const char *key, const char *val) {
    json_key(b, first, key);
    buf_json_str(b, val);
}

static void json_kv_i64(Buf *b, int *first, const char *key, int64_t val) {
    json_key(b, first, key);
    buf_printf(b, "%lld", (long long)val);
}

static void json_kv_null(Buf *b, int *first, const char *key) {
    json_key(b, first, key);
    buf_puts(b, "null");
}

static void json_kv_double(Buf *b, int *first, const char *key, double val) {
    json_key(b, first, key);
    buf_printf(b, "%.6g", val);
}

static void json_kv_bool(Buf *b, int *first, const char *key, int val) {
    json_key(b, first, key);
    buf_puts(b, val ? "true" : "false");
}

/*
 * NewStringUTF 只接受 Modified UTF-8：把非法 UTF-8 字节替换为 '?'，
 * 并把 4 字节序列（补充平面）编码为代理对的 Modified UTF-8 形式。
 */
static char *to_modified_utf8(const char *in) {
    size_t n = strlen(in);
    char *out = malloc(n * 2 + 1);
    if (!out) return NULL;
    size_t o = 0;
    const unsigned char *p = (const unsigned char *)in;
    while (*p) {
        unsigned c = *p;
        if (c < 0x80) {
            out[o++] = (char)c;
            p++;
        } else if ((c & 0xE0) == 0xC0 && (p[1] & 0xC0) == 0x80 && c >= 0xC2) {
            out[o++] = (char)p[0];
            out[o++] = (char)p[1];
            p += 2;
        } else if ((c & 0xF0) == 0xE0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80) {
            out[o++] = (char)p[0];
            out[o++] = (char)p[1];
            out[o++] = (char)p[2];
            p += 3;
        } else if ((c & 0xF8) == 0xF0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80 &&
                   (p[3] & 0xC0) == 0x80) {
            uint32_t cp = ((c & 0x07u) << 18) | ((p[1] & 0x3Fu) << 12) | ((p[2] & 0x3Fu) << 6) |
                          (p[3] & 0x3Fu);
            if (cp < 0x10000 || cp > 0x10FFFF) {
                out[o++] = '?';
            } else {
                cp -= 0x10000;
                uint32_t hi = 0xD800 + (cp >> 10), lo = 0xDC00 + (cp & 0x3FF);
                uint32_t sur[2] = {hi, lo};
                for (int i = 0; i < 2; i++) {
                    out[o++] = (char)(0xE0 | (sur[i] >> 12));
                    out[o++] = (char)(0x80 | ((sur[i] >> 6) & 0x3F));
                    out[o++] = (char)(0x80 | (sur[i] & 0x3F));
                }
            }
            p += 4;
        } else {
            out[o++] = '?';
            p++;
        }
    }
    out[o] = '\0';
    return out;
}

static jstring new_jstring(JNIEnv *env, const char *s) {
    char *m = to_modified_utf8(s ? s : "");
    if (!m) return (*env)->NewStringUTF(env, "{\"error\":\"out of memory\"}");
    jstring r = (*env)->NewStringUTF(env, m);
    free(m);
    return r;
}

/*
 * jstring → 标准 UTF-8。GetStringUTFChars 返回 Modified UTF-8，补充平面字符（如文件名里的 emoji）
 * 会被编码成代理对，传给文件系统会找不到文件，因此从 UTF-16 自行转换。
 */
static char *jstring_to_utf8(JNIEnv *env, jstring js) {
    if (!js) return strdup("");
    jsize n = (*env)->GetStringLength(env, js);
    const jchar *u = (*env)->GetStringChars(env, js, NULL);
    if (!u) return NULL;
    char *out = malloc((size_t)n * 3 + 1);
    if (!out) {
        (*env)->ReleaseStringChars(env, js, u);
        return NULL;
    }
    size_t o = 0;
    for (jsize i = 0; i < n; i++) {
        uint32_t c = u[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n && u[i + 1] >= 0xDC00 && u[i + 1] <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + (u[i + 1] - 0xDC00);
            i++;
        } else if (c >= 0xD800 && c <= 0xDFFF) {
            c = 0xFFFD; /* 孤立代理 */
        }
        if (c < 0x80) {
            out[o++] = (char)c;
        } else if (c < 0x800) {
            out[o++] = (char)(0xC0 | (c >> 6));
            out[o++] = (char)(0x80 | (c & 0x3F));
        } else if (c < 0x10000) {
            out[o++] = (char)(0xE0 | (c >> 12));
            out[o++] = (char)(0x80 | ((c >> 6) & 0x3F));
            out[o++] = (char)(0x80 | (c & 0x3F));
        } else {
            out[o++] = (char)(0xF0 | (c >> 18));
            out[o++] = (char)(0x80 | ((c >> 12) & 0x3F));
            out[o++] = (char)(0x80 | ((c >> 6) & 0x3F));
            out[o++] = (char)(0x80 | (c & 0x3F));
        }
    }
    out[o] = '\0';
    (*env)->ReleaseStringChars(env, js, u);
    return out;
}

/* ---------- runFfmpeg ---------- */

JNIEXPORT jint JNICALL Java_com_rz_videoslicer_engine_NativeEngine_runFfmpeg(
    JNIEnv *env, jclass clazz, jobjectArray args, jint logFd) {
    (void)clazz;
    jsize n = args ? (*env)->GetArrayLength(env, args) : 0;
    char **argv = calloc((size_t)n + 2, sizeof(char *));
    if (!argv) return -ENOMEM;
    argv[0] = strdup("ffmpeg");
    int argc = 1;
    for (jsize i = 0; i < n; i++) {
        jstring js = (jstring)(*env)->GetObjectArrayElement(env, args, i);
        char *s = jstring_to_utf8(env, js);
        if (js) (*env)->DeleteLocalRef(env, js);
        if (!s) return -ENOMEM;
        argv[argc++] = s;
    }
    argv[argc] = NULL;

    if (logFd >= 0 && logFd != STDERR_FILENO) {
        dup2(logFd, STDERR_FILENO);
    }
    setvbuf(stderr, NULL, _IONBF, 0);

    int ret = mediaengine_ffmpeg_main(argc, argv);
    fflush(stdout);
    fflush(stderr);
    /* ffmpeg 可能持有 argv 中字符串的指针，进程结束前不释放。 */
    return ret;
}

/* ---------- probe ---------- */

static const char *media_type_name(enum AVMediaType t) {
    switch (t) {
    case AVMEDIA_TYPE_VIDEO: return "video";
    case AVMEDIA_TYPE_AUDIO: return "audio";
    case AVMEDIA_TYPE_SUBTITLE: return "subtitle";
    case AVMEDIA_TYPE_ATTACHMENT: return "attachment";
    default: return "data";
    }
}

static int64_t ts_to_ms(int64_t ts, AVRational tb) {
    if (ts == AV_NOPTS_VALUE) return -1;
    return av_rescale_q(ts, tb, (AVRational){1, 1000});
}

static void probe_stream(Buf *b, const AVStream *st) {
    const AVCodecParameters *par = st->codecpar;
    int first = 1;
    buf_puts(b, "{");
    json_kv_i64(b, &first, "index", st->index);
    json_kv_str(b, &first, "type", media_type_name(par->codec_type));
    const AVCodecDescriptor *desc = avcodec_descriptor_get(par->codec_id);
    json_kv_str(b, &first, "codec", desc ? desc->name : avcodec_get_name(par->codec_id));
    const char *profile = par->profile != AV_PROFILE_UNKNOWN
                              ? avcodec_profile_name(par->codec_id, par->profile)
                              : NULL;
    if (profile) json_kv_str(b, &first, "profile", profile);
    else json_kv_null(b, &first, "profile");

    if (par->codec_type == AVMEDIA_TYPE_VIDEO) {
        json_kv_i64(b, &first, "width", par->width);
        json_kv_i64(b, &first, "height", par->height);
        double rotation = 0;
        const AVPacketSideData *sd = av_packet_side_data_get(
            par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
        if (sd && sd->size >= 9 * sizeof(int32_t)) {
            double r = av_display_rotation_get((const int32_t *)sd->data);
            if (r == r) { /* 排除 NaN */
                /* av_display_rotation_get 返回逆时针角度；转换成 0~359 的顺时针显示旋转。 */
                long rr = lround(-r) % 360;
                if (rr < 0) rr += 360;
                rotation = (double)rr;
            }
        }
        json_kv_i64(b, &first, "rotation", (int64_t)rotation);
        AVRational fr = st->avg_frame_rate;
        if (fr.num <= 0 || fr.den <= 0) fr = st->r_frame_rate;
        if (fr.num > 0 && fr.den > 0) json_kv_double(b, &first, "fps", av_q2d(fr));
        else json_kv_null(b, &first, "fps");
        const char *pf = par->format >= 0 ? av_get_pix_fmt_name((enum AVPixelFormat)par->format) : NULL;
        if (pf) json_kv_str(b, &first, "pixFmt", pf);
        else json_kv_null(b, &first, "pixFmt");
    }
    if (par->codec_type == AVMEDIA_TYPE_AUDIO) {
        json_kv_i64(b, &first, "sampleRate", par->sample_rate);
        json_kv_i64(b, &first, "channels", par->ch_layout.nb_channels);
        char layout[128];
        if (par->ch_layout.nb_channels > 0 &&
            av_channel_layout_describe(&par->ch_layout, layout, sizeof(layout)) >= 0)
            json_kv_str(b, &first, "channelLayout", layout);
        else json_kv_null(b, &first, "channelLayout");
    }
    if (par->bit_rate > 0) json_kv_i64(b, &first, "bitRate", par->bit_rate);
    else json_kv_null(b, &first, "bitRate");
    int64_t dms = ts_to_ms(st->duration, st->time_base);
    if (dms >= 0) json_kv_i64(b, &first, "durationMs", dms);
    else json_kv_null(b, &first, "durationMs");
    const AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);
    if (lang && lang->value[0]) json_kv_str(b, &first, "language", lang->value);
    else json_kv_null(b, &first, "language");
    json_kv_bool(b, &first, "isAttachedPic", (st->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0);
    buf_puts(b, "}");
}

/*
 * 裸码流（ADTS AAC、AC3、AMR 等）没有时长字段，FFmpeg 按开头几帧的码率估算；
 * 开头是静音的 VBR 文件会偏差数倍。这类文件逐包读一遍求真实时长：只解封装不解码，几 MB 的音频很快。
 */
static void refine_estimated_duration(AVFormatContext *fmt) {
    if (fmt->duration_estimation_method != AVFMT_DURATION_FROM_BITRATE || !fmt->pb) return;
    int64_t size = avio_size(fmt->pb);
    if (size <= 0 || size > (int64_t)1 << 30) return;
    /* find_stream_info 读过的包仍在内部缓冲里，接着读即从头覆盖整个文件，无需回绕。 */
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return;
    int64_t start = INT64_MAX, end = INT64_MIN;
    for (int n = 0; n < 4000000 && av_read_frame(fmt, pkt) >= 0; n++) {
        const AVStream *st = fmt->streams[pkt->stream_index];
        int64_t ts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
        if (ts != AV_NOPTS_VALUE) {
            int64_t a = av_rescale_q(ts, st->time_base, AV_TIME_BASE_Q);
            int64_t z = av_rescale_q(ts + FFMAX(pkt->duration, 0), st->time_base, AV_TIME_BASE_Q);
            if (a < start) start = a;
            if (z > end) end = z;
        }
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    if (start != INT64_MAX && end > start) fmt->duration = end - start;
}

static char *probe_json(const char *path) {
    Buf b = {0};
    AVFormatContext *fmt = NULL;
    char err[AV_ERROR_MAX_STRING_SIZE];
    /* "fd:N"：经 fd 协议直接复用描述符；系统描述符常指向底层存储，按 /proc 路径重新打开会被拒绝。 */
    AVDictionary *opts = NULL;
    const char *url = path;
    if (strncmp(path, "fd:", 3) == 0 && path[3] >= '0' && path[3] <= '9') {
        av_dict_set(&opts, "fd", path + 3, 0);
        url = "fd:";
    }
    int ret = avformat_open_input(&fmt, url, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        av_strerror(ret, err, sizeof(err));
        buf_puts(&b, "{\"error\":");
        buf_json_str(&b, err);
        buf_puts(&b, "}");
        return b.data;
    }
    ret = avformat_find_stream_info(fmt, NULL);
    if (ret < 0) {
        av_strerror(ret, err, sizeof(err));
        avformat_close_input(&fmt);
        b.len = 0;
        buf_puts(&b, "{\"error\":");
        buf_json_str(&b, err);
        buf_puts(&b, "}");
        return b.data;
    }
    refine_estimated_duration(fmt);
    int first = 1;
    buf_puts(&b, "{\"format\":{");
    json_kv_str(&b, &first, "name", fmt->iformat ? fmt->iformat->name : NULL);
    if (fmt->duration != AV_NOPTS_VALUE && fmt->duration >= 0)
        json_kv_i64(&b, &first, "durationMs", fmt->duration / 1000);
    else json_kv_null(&b, &first, "durationMs");
    if (fmt->bit_rate > 0) json_kv_i64(&b, &first, "bitRate", fmt->bit_rate);
    else json_kv_null(&b, &first, "bitRate");
    if (fmt->start_time != AV_NOPTS_VALUE) json_kv_i64(&b, &first, "startMs", fmt->start_time / 1000);
    else json_kv_null(&b, &first, "startMs");
    buf_puts(&b, "},\"streams\":[");
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        if (i) buf_puts(&b, ",");
        probe_stream(&b, fmt->streams[i]);
    }
    buf_puts(&b, "]}");
    avformat_close_input(&fmt);
    if (b.oom) {
        free(b.data);
        return NULL;
    }
    return b.data;
}

JNIEXPORT jstring JNICALL Java_com_rz_videoslicer_engine_NativeEngine_probe(
    JNIEnv *env, jclass clazz, jstring jpath) {
    (void)clazz;
    if (!jpath) return new_jstring(env, "{\"error\":\"path is null\"}");
    char *path = jstring_to_utf8(env, jpath);
    if (!path) return new_jstring(env, "{\"error\":\"out of memory\"}");
    char *json = probe_json(path);
    free(path);
    jstring r = new_jstring(env, json ? json : "{\"error\":\"out of memory\"}");
    free(json);
    return r;
}

/* ---------- list ---------- */

static void list_add(Buf *b, const char *name) {
    if (!name) return;
    if (b->len) buf_puts(b, ",");
    buf_puts(b, name);
}

/* 协议同时出现在输入和输出列表中，按名字去重。 */
static int list_contains(const Buf *b, const char *name) {
    if (!b->data) return 0;
    size_t n = strlen(name);
    const char *p = b->data;
    while (p && *p) {
        const char *e = strchr(p, ',');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        if (len == n && memcmp(p, name, n) == 0) return 1;
        p = e ? e + 1 : NULL;
    }
    return 0;
}

JNIEXPORT jstring JNICALL Java_com_rz_videoslicer_engine_NativeEngine_list(
    JNIEnv *env, jclass clazz, jstring jkind) {
    (void)clazz;
    if (!jkind) return new_jstring(env, "");
    const char *kind = (*env)->GetStringUTFChars(env, jkind, NULL);
    if (!kind) return NULL;
    Buf b = {0};
    void *it = NULL;
    if (!strcmp(kind, "encoders") || !strcmp(kind, "decoders")) {
        int enc = !strcmp(kind, "encoders");
        const AVCodec *c;
        while ((c = av_codec_iterate(&it))) {
            if (enc ? av_codec_is_encoder(c) : av_codec_is_decoder(c)) list_add(&b, c->name);
        }
    } else if (!strcmp(kind, "muxers")) {
        const AVOutputFormat *f;
        while ((f = av_muxer_iterate(&it))) list_add(&b, f->name);
    } else if (!strcmp(kind, "demuxers")) {
        const AVInputFormat *f;
        while ((f = av_demuxer_iterate(&it))) list_add(&b, f->name);
    } else if (!strcmp(kind, "filters")) {
        const AVFilter *f;
        while ((f = av_filter_iterate(&it))) list_add(&b, f->name);
    } else if (!strcmp(kind, "protocols")) {
        for (int output = 0; output <= 1; output++) {
            const char *name;
            it = NULL;
            while ((name = avio_enum_protocols(&it, output))) {
                if (!list_contains(&b, name)) list_add(&b, name);
            }
        }
    }
    (*env)->ReleaseStringUTFChars(env, jkind, kind);
    jstring r = new_jstring(env, b.data && !b.oom ? b.data : "");
    free(b.data);
    return r;
}

/* ---------- version ---------- */

JNIEXPORT jstring JNICALL Java_com_rz_videoslicer_engine_NativeEngine_version(
    JNIEnv *env, jclass clazz) {
    (void)clazz;
    Buf b = {0};
    buf_puts(&b, av_version_info());
    buf_puts(&b, " mediaengine");
    if (ME_EXTERNAL_LIBS[0]) {
        buf_puts(&b, " ");
        buf_puts(&b, ME_EXTERNAL_LIBS);
    }
    jstring r = new_jstring(env, b.data && !b.oom ? b.data : "mediaengine");
    free(b.data);
    return r;
}
