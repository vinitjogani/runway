// A small C surface over GStreamer for Runway's media frameworks: pipelines
// from launch descriptions, appsink pulls, appsrc pushes, discovery and the
// device monitor. Everything that would need GObject varargs, macros or
// GstMapInfo lifetimes lives here; Swift sees plain functions and structs.
// On platforms without GStreamer every function reports failure.
#ifndef RUNWAY_GST_H
#define RUNWAY_GST_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when Runway was built with GStreamer and it initialised.
int rg_init(void);
/// 1 when an element factory of that name is installed.
int rg_has_element(const char *name);

typedef struct RGDiscovery {
    int64_t duration_ns;
    int video_count, audio_count;
    int width, height;
    int fps_n, fps_d;
    /// Clockwise rotation from the image-orientation tag (0, 90, 180, 270); 1 when flipped.
    int rotation, flipped;
    int channels, rate;
    int seekable;
    char video_codec[96], audio_codec[96], container[96];
    int64_t video_bitrate, audio_bitrate;
} RGDiscovery;

/// Synchronous GstDiscoverer run; 1 on success, else 0 with `err` set.
int rg_discover(const char *uri, int64_t timeout_ns, RGDiscovery *out, char *err, int errlen);

typedef struct RGPipeline RGPipeline;

/// A pipeline from a gst-launch description; NULL with `err` set on failure.
RGPipeline *rg_pipeline_new(const char *description, char *err, int errlen);
void rg_pipeline_free(RGPipeline *p);

int rg_pipeline_set_string(RGPipeline *p, const char *element, const char *property, const char *value);
int rg_pipeline_set_int(RGPipeline *p, const char *element, const char *property, int64_t value);
int rg_pipeline_set_double(RGPipeline *p, const char *element, const char *property, double value);
int rg_pipeline_set_bool(RGPipeline *p, const char *element, const char *property, int value);
/// Sets an element-valued property (playbin's video-sink…) to a bin made from `description`.
int rg_pipeline_set_bin(RGPipeline *p, const char *element, const char *property, const char *description, char *err, int errlen);
/// The root element (a playbin) gets the property when `element` is NULL.

enum { RG_NULL = 1, RG_READY = 2, RG_PAUSED = 3, RG_PLAYING = 4 };
/// Changes state and waits up to `timeout_ns` for it to complete; 1 ok, 0 failed (err set).
int rg_pipeline_set_state(RGPipeline *p, int state, int64_t timeout_ns, char *err, int errlen);
/// Starts a state change without waiting.
void rg_pipeline_set_state_async(RGPipeline *p, int state);
int rg_pipeline_get_state(RGPipeline *p);

enum { RG_SEEK_ACCURATE = 1, RG_SEEK_KEY = 2, RG_SEEK_SNAP_BEFORE = 4, RG_SEEK_SNAP_AFTER = 8 };
int rg_pipeline_seek(RGPipeline *p, int64_t ns, double rate, int flags);
int64_t rg_pipeline_position(RGPipeline *p);
int64_t rg_pipeline_duration(RGPipeline *p);

typedef struct RGFrame {
    void *priv;
    const uint8_t *data;
    size_t size;
    int64_t pts, duration;
    /// Video: size, first plane's stride, plane offsets/strides; audio: rate, channels.
    int width, height, stride;
    int planes;
    int plane_offset[4], plane_stride[4];
    int rate, channels;
    char format[16];
} RGFrame;

enum { RG_PULL_SAMPLE = 1, RG_PULL_EOS = 0, RG_PULL_TIMEOUT = 2, RG_PULL_ERROR = -1 };
/// The next sample from appsink `sink` (preroll when `preroll` and paused).
int rg_pipeline_pull(RGPipeline *p, const char *sink, int64_t timeout_ns, int preroll, RGFrame *out);
void rg_frame_release(RGFrame *f);

/// Pushes a copy of `data` into appsrc `src`; 1 ok, 0 flushing/eos/error.
int rg_pipeline_push(RGPipeline *p, const char *src, const void *data, size_t size, int64_t pts, int64_t duration);
int rg_pipeline_end_of_stream(RGPipeline *p, const char *src);

enum { RG_BUS_EOS = 1, RG_BUS_ERROR = 2, RG_BUS_STATE = 4 };
/// Pops pending bus messages without blocking: RG_BUS_* flags; the first error goes into `err`.
int rg_pipeline_poll(RGPipeline *p, char *err, int errlen);
/// Waits for EOS or an error; 1 on EOS, 0 on error/timeout.
int rg_pipeline_wait_eos(RGPipeline *p, int64_t timeout_ns, char *err, int errlen);

/// Device monitor: calls `cb` for each device of `klass` ("Video/Source", "Audio/Source").
typedef void (*rg_device_cb)(void *ctx, const char *name, const char *id, const char *api, int is_default);
int rg_list_devices(const char *klass, rg_device_cb cb, void *ctx);

/// A GLib timeout on the default main context (0 = stopped). `cb` returns 1 to continue.
typedef int (*rg_timeout_cb)(void *ctx);
unsigned rg_timeout_add(unsigned interval_ms, rg_timeout_cb cb, void *ctx);
void rg_source_remove(unsigned id);

#ifdef __cplusplus
}
#endif
#endif
