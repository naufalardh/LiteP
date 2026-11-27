// Minimal in-process replacement for the ffmpeg CLI, limited to what Mornye
// extensions ask for on LiteP: remuxing audio with `-c copy`, optionally
// decrypting MOV/MP4 input with `-decryption_key`.
#include "lite_ffmpeg.h"

#include <libavformat/avformat.h>
#include <libavutil/avstring.h>
#include <libavutil/opt.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <stdlib.h>

typedef struct {
    lite_ffmpeg_cancelled cancelled;
    void *opaque;
} Interrupt;

static _Thread_local char last_log[512];

static void log_callback(void *avcl, int level, const char *fmt, va_list args) {
    if (level > AV_LOG_ERROR) return;
    char line[512];
    vsnprintf(line, sizeof line, fmt, args);
    size_t length = strlen(line);
    while (length && (line[length - 1] == '\n' || line[length - 1] == '\r')) line[--length] = 0;
    if (length) av_strlcpy(last_log, line, sizeof last_log);
}

static void install_log(void) {
    av_log_set_level(AV_LOG_ERROR);
    av_log_set_callback(log_callback);
}

static int interrupted(void *opaque) {
    Interrupt *interrupt = opaque;
    return interrupt->cancelled && interrupt->cancelled(interrupt->opaque);
}

static int fail(char *message, size_t size, const char *what, int error) {
    if (!message || !size) return -1;
    char reason[AV_ERROR_MAX_STRING_SIZE] = {0};
    if (error) av_strerror(error, reason, sizeof reason);
    if (last_log[0] && error)
        snprintf(message, size, "%s: %s (%s)", what, reason, last_log);
    else if (error)
        snprintf(message, size, "%s: %s", what, reason);
    else
        snprintf(message, size, "%s", what);
    return -1;
}

typedef struct {
    char dir[PATH_MAX];
    int (*open)(AVFormatContext *, AVIOContext **, const char *, int, AVDictionary **);
} Guard;

// Only lets the input (and, for HLS, its segments) be read from the input's own directory tree.
static int guarded_open(AVFormatContext *s, AVIOContext **pb, const char *url, int flags, AVDictionary **options) {
    Guard *guard = s->opaque;
    const char *path = url;
    if (!strncmp(path, "file:", 5)) path += 5;
    if (!strncmp(path, "//", 2)) path += 2;
    char resolved[PATH_MAX];
    if (!realpath(path, resolved)) return AVERROR(ENOENT);
    size_t length = strlen(guard->dir);
    if (strncmp(resolved, guard->dir, length) || (resolved[length] != '/' && length > 1)) return AVERROR(EACCES);
    return guard->open(s, pb, url, flags, options);
}

static int is(const char *a, const char *b) { return strcmp(a, b) == 0; }

static int is_codec_flag(const char *arg) {
    return is(arg, "-c") || is(arg, "-c:a") || is(arg, "-codec") || is(arg, "-codec:a") ||
           is(arg, "-acodec") || is(arg, "-c:a:0");
}

int lite_ffmpeg_run(int argc, const char *const *argv, lite_ffmpeg_cancelled cancelled,
                    void *opaque, char *message, size_t message_size) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, install_log);
    last_log[0] = 0;
    if (message && message_size) message[0] = 0;

    const char *input = NULL, *output = NULL, *input_format = NULL, *output_format = NULL;
    const char *key = NULL;
    int all_audio = 0, audio_index = -1, strip_metadata = 0;
    for (int i = 0; i < argc; i++) {
        const char *arg = argv[i];
        const char *value = i + 1 < argc ? argv[i + 1] : NULL;
        if (is(arg, "-hide_banner") || is(arg, "-nostdin") || is(arg, "-y") || is(arg, "-vn") ||
            is(arg, "-sn") || is(arg, "-dn") || is(arg, "-nostats")) {
            continue;
        }
        if (arg[0] != '-' || !arg[1]) {
            if (output) return fail(message, message_size, "FFmpeg: only one output file is supported", 0);
            output = arg;
            continue;
        }
        if (!value) return fail(message, message_size, "FFmpeg: option is missing its value", 0);
        i++;
        if (is(arg, "-v") || is(arg, "-loglevel")) {
            continue;
        } else if (is(arg, "-i")) {
            if (input) return fail(message, message_size, "FFmpeg: only one input file is supported", 0);
            input = value;
        } else if (is(arg, "-decryption_key")) {
            if (input) return fail(message, message_size, "FFmpeg: -decryption_key must precede -i", 0);
            key = value;
        } else if (is(arg, "-f")) {
            if (input) output_format = value; else input_format = value;
        } else if (is_codec_flag(arg)) {
            if (!is(value, "copy"))
                return fail(message, message_size,
                            "FFmpeg in LiteP only supports remuxing (-c copy), not re-encoding", 0);
        } else if (is(arg, "-c:v") || is(arg, "-vcodec") || is(arg, "-c:s") || is(arg, "-movflags") ||
                   is(arg, "-b:a") || is(arg, "-ab")) {
            // Irrelevant for audio stream copy.
            continue;
        } else if (is(arg, "-map")) {
            if (is(value, "0") || is(value, "0:a") || is(value, "0:a?")) all_audio = 1;
            else if (!strncmp(value, "0:a:", 4) && value[4] >= '0' && value[4] <= '9') audio_index = atoi(value + 4);
            else return fail(message, message_size, "FFmpeg: unsupported -map", 0);
        } else if (is(arg, "-map_metadata")) {
            strip_metadata = is(value, "-1");
        } else {
            char text[160];
            snprintf(text, sizeof text, "FFmpeg in LiteP does not support option %s", arg);
            return fail(message, message_size, text, 0);
        }
    }
    if (!input || !output || is(input, output))
        return fail(message, message_size, "FFmpeg: need one input (-i) and a different output file", 0);

    Interrupt interrupt = {cancelled, opaque};
    AVFormatContext *in = NULL, *out = NULL;
    AVDictionary *options = NULL;
    AVPacket *packet = NULL;
    int *mapping = NULL, mapping_count = 0, result = -1, error = 0;
    const char *stage = "open input";

    in = avformat_alloc_context();
    if (!in) { error = AVERROR(ENOMEM); goto end; }
    in->interrupt_callback = (AVIOInterruptCB){interrupted, &interrupt};
    Guard guard;
    char *slash;
    if (!realpath(input, guard.dir) || !(slash = strrchr(guard.dir, '/'))) {
        error = AVERROR(ENOENT);
        goto end;
    }
    if (slash == guard.dir) slash[1] = 0; else *slash = 0;
    guard.open = in->io_open;
    in->opaque = &guard;
    in->io_open = guarded_open;
    const AVInputFormat *forced = NULL;
    if (input_format && !(forced = av_find_input_format(input_format))) {
        error = AVERROR_DEMUXER_NOT_FOUND;
        goto end;
    }
    if (key) av_dict_set(&options, "decryption_key", key, 0);
    // HLS playlists may only reference local files.
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    if ((error = avformat_open_input(&in, input, forced, &options)) < 0) goto end;
    av_dict_free(&options);
    stage = "read input";
    if ((error = avformat_find_stream_info(in, NULL)) < 0) goto end;

    stage = "choose audio";
    int best = av_find_best_stream(in, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (best < 0) { error = best; goto end; }
    stage = "create output";
    if ((error = avformat_alloc_output_context2(&out, NULL, output_format, output)) < 0) goto end;
    out->interrupt_callback = in->interrupt_callback;
    mapping = av_malloc_array(in->nb_streams, sizeof *mapping);
    if (!mapping) { error = AVERROR(ENOMEM); goto end; }
    mapping_count = in->nb_streams;
    int audio_seen = 0, mapped = 0;
    for (unsigned i = 0; i < in->nb_streams; i++) {
        AVStream *stream = in->streams[i];
        mapping[i] = -1;
        if (stream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        int nth = audio_seen++;
        int take = all_audio || (audio_index >= 0 ? nth == audio_index : (int)i == best);
        if (!take) continue;
        AVStream *copy = avformat_new_stream(out, NULL);
        if (!copy) { error = AVERROR(ENOMEM); goto end; }
        if ((error = avcodec_parameters_copy(copy->codecpar, stream->codecpar)) < 0) goto end;
        copy->codecpar->codec_tag = 0;
        copy->time_base = stream->time_base;
        copy->disposition = stream->disposition;
        if (!strip_metadata) av_dict_copy(&copy->metadata, stream->metadata, 0);
        mapping[i] = mapped++;
    }
    if (!mapped) { error = AVERROR_STREAM_NOT_FOUND; goto end; }
    if (!strip_metadata) av_dict_copy(&out->metadata, in->metadata, 0);

    stage = "open output";
    if (!(out->oformat->flags & AVFMT_NOFILE) &&
        (error = avio_open2(&out->pb, output, AVIO_FLAG_WRITE, &out->interrupt_callback, NULL)) < 0)
        goto end;
    stage = "write header";
    if ((error = avformat_write_header(out, NULL)) < 0) goto end;

    packet = av_packet_alloc();
    if (!packet) { error = AVERROR(ENOMEM); goto end; }
    int64_t start = in->start_time == AV_NOPTS_VALUE ? 0 : in->start_time;
    for (;;) {
        if (interrupted(&interrupt)) { error = AVERROR_EXIT; break; }
        stage = "read packet";
        error = av_read_frame(in, packet);
        if (error == AVERROR_EOF) { error = 0; break; }
        if (error < 0) break;
        int target = packet->stream_index < mapping_count ? mapping[packet->stream_index] : -1;
        if (target < 0) { av_packet_unref(packet); continue; }
        AVStream *source = in->streams[packet->stream_index];
        int64_t offset = av_rescale_q(start, AV_TIME_BASE_Q, source->time_base);
        if (packet->pts != AV_NOPTS_VALUE) packet->pts -= offset;
        if (packet->dts != AV_NOPTS_VALUE) packet->dts -= offset;
        packet->stream_index = target;
        av_packet_rescale_ts(packet, source->time_base, out->streams[target]->time_base);
        packet->pos = -1;
        stage = "write packet";
        error = av_interleaved_write_frame(out, packet);
        if (error < 0) break;
    }
    if (error == 0) {
        stage = "finish output";
        error = av_write_trailer(out);
        if (error == 0 && out->pb) error = out->pb->error;
    }

end:
    if (error == AVERROR_EXIT || interrupted(&interrupt)) {
        result = -2;
        if (message && message_size) snprintf(message, message_size, "cancelled");
    } else if (error < 0) {
        char text[64];
        snprintf(text, sizeof text, "FFmpeg could not %s", stage);
        result = fail(message, message_size, text, error);
    } else {
        result = 0;
    }
    av_dict_free(&options);
    av_packet_free(&packet);
    av_free(mapping);
    avformat_close_input(&in);
    if (out) {
        if (!(out->oformat->flags & AVFMT_NOFILE)) avio_closep(&out->pb);
        avformat_free_context(out);
    }
    return result;
}
