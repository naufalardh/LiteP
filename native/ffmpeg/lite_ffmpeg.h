#ifndef LITE_FFMPEG_H
#define LITE_FFMPEG_H

#include <stddef.h>

/// Returns non-zero when the running command should stop.
typedef int (*lite_ffmpeg_cancelled)(void *opaque);

/// Runs an audio-only, stream-copy subset of the ffmpeg command line in-process:
/// `[-hide_banner] [-nostdin] [-v level] [-decryption_key K] [-f fmt] -i IN
///  [-map 0[:a[:N]]] [-vn] [-c[:a] copy] [-map_metadata -1] [-f fmt] [-y] OUT`.
/// Returns 0 on success, -2 when cancelled, otherwise -1 with `message` set.
int lite_ffmpeg_run(int argc, const char *const *argv, lite_ffmpeg_cancelled cancelled,
                    void *opaque, char *message, size_t message_size);

#endif
