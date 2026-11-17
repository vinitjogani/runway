#include "runway_gst.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(__linux__) && __has_include(<gst/gst.h>)
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <gst/video/video.h>
#include <gst/audio/audio.h>
#include <gst/pbutils/pbutils.h>

static void set_err(char *err, int errlen, const char *msg) {
    if (err && errlen > 0) {
        snprintf(err, (size_t)errlen, "%s", msg ? msg : "unknown error");
    }
}

static int initialised = -1;

int rg_init(void) {
    if (initialised < 0) {
        GError *e = NULL;
        initialised = gst_init_check(NULL, NULL, &e) ? 1 : 0;
        if (e) g_error_free(e);
    }
    return initialised;
}

int rg_has_element(const char *name) {
    if (!rg_init()) return 0;
    GstElementFactory *f = gst_element_factory_find(name);
    if (!f) return 0;
    gst_object_unref(f);
    return 1;
}

// MARK: Discovery

static void codec_name(GstDiscovererStreamInfo *s, char *out, size_t n) {
    GstCaps *caps = gst_discoverer_stream_info_get_caps(s);
    if (!caps) return;
    if (gst_caps_get_size(caps) > 0) {
        snprintf(out, n, "%s", gst_structure_get_name(gst_caps_get_structure(caps, 0)));
    }
    gst_caps_unref(caps);
}

static void orientation(const GstTagList *tags, RGDiscovery *out) {
    gchar *o = NULL;
    if (!tags || !gst_tag_list_get_string(tags, GST_TAG_IMAGE_ORIENTATION, &o) || !o) return;
    if (g_str_has_prefix(o, "flip-")) {
        out->flipped = 1;
        out->rotation = atoi(o + strlen("flip-rotate-"));
    } else if (g_str_has_prefix(o, "rotate-")) {
        out->rotation = atoi(o + strlen("rotate-"));
    }
    g_free(o);
}

int rg_discover(const char *uri, int64_t timeout_ns, RGDiscovery *out, char *err, int errlen) {
    memset(out, 0, sizeof(*out));
    if (!rg_init()) { set_err(err, errlen, "GStreamer is not available"); return 0; }
    GError *e = NULL;
    GstDiscoverer *d = gst_discoverer_new(timeout_ns > 0 ? (GstClockTime)timeout_ns : 10 * GST_SECOND, &e);
    if (!d) { set_err(err, errlen, e ? e->message : "no discoverer"); if (e) g_error_free(e); return 0; }
    GstDiscovererInfo *info = gst_discoverer_discover_uri(d, uri, &e);
    int ok = 0;
    if (info) {
        GstDiscovererResult r = gst_discoverer_info_get_result(info);
        if (r == GST_DISCOVERER_OK) {
            ok = 1;
            GstClockTime dur = gst_discoverer_info_get_duration(info);
            out->duration_ns = GST_CLOCK_TIME_IS_VALID(dur) ? (int64_t)dur : -1;
            out->seekable = gst_discoverer_info_get_seekable(info);
            GstDiscovererStreamInfo *top = gst_discoverer_info_get_stream_info(info);
            if (top) {
                if (GST_IS_DISCOVERER_CONTAINER_INFO(top)) codec_name(top, out->container, sizeof(out->container));
                gst_discoverer_stream_info_unref(top);
            }
            GList *videos = gst_discoverer_info_get_video_streams(info);
            out->video_count = (int)g_list_length(videos);
            if (videos) {
                GstDiscovererVideoInfo *v = (GstDiscovererVideoInfo *)videos->data;
                out->width = (int)gst_discoverer_video_info_get_width(v);
                out->height = (int)gst_discoverer_video_info_get_height(v);
                out->fps_n = (int)gst_discoverer_video_info_get_framerate_num(v);
                out->fps_d = (int)gst_discoverer_video_info_get_framerate_denom(v);
                out->video_bitrate = gst_discoverer_video_info_get_bitrate(v);
                codec_name((GstDiscovererStreamInfo *)v, out->video_codec, sizeof(out->video_codec));
                orientation(gst_discoverer_stream_info_get_tags((GstDiscovererStreamInfo *)v), out);
                if (out->rotation == 0 && !out->flipped) orientation(gst_discoverer_info_get_tags(info), out);
            }
            gst_discoverer_stream_info_list_free(videos);
            GList *audios = gst_discoverer_info_get_audio_streams(info);
            out->audio_count = (int)g_list_length(audios);
            if (audios) {
                GstDiscovererAudioInfo *a = (GstDiscovererAudioInfo *)audios->data;
                out->channels = (int)gst_discoverer_audio_info_get_channels(a);
                out->rate = (int)gst_discoverer_audio_info_get_sample_rate(a);
                out->audio_bitrate = gst_discoverer_audio_info_get_bitrate(a);
                codec_name((GstDiscovererStreamInfo *)a, out->audio_codec, sizeof(out->audio_codec));
            }
            gst_discoverer_stream_info_list_free(audios);
        } else {
            switch (r) {
            case GST_DISCOVERER_URI_INVALID: set_err(err, errlen, "invalid URI"); break;
            case GST_DISCOVERER_TIMEOUT: set_err(err, errlen, "timed out reading the file"); break;
            case GST_DISCOVERER_MISSING_PLUGINS: set_err(err, errlen, "no GStreamer plugin decodes this format"); break;
            default: set_err(err, errlen, e ? e->message : "the file could not be read"); break;
            }
        }
        gst_discoverer_info_unref(info);
    } else {
        set_err(err, errlen, e ? e->message : "the file could not be read");
    }
    if (e) g_error_free(e);
    g_object_unref(d);
    return ok;
}

// MARK: Pipelines

struct RGPipeline {
    GstElement *pipeline;
    GstBus *bus;
    int eos;
};

RGPipeline *rg_pipeline_new(const char *description, char *err, int errlen) {
    if (!rg_init()) { set_err(err, errlen, "GStreamer is not available"); return NULL; }
    GError *e = NULL;
    GstElement *el = gst_parse_launch_full(description, NULL, GST_PARSE_FLAG_FATAL_ERRORS, &e);
    if (!el) {
        set_err(err, errlen, e ? e->message : "could not build the pipeline");
        if (e) g_error_free(e);
        return NULL;
    }
    if (e) g_error_free(e);
    RGPipeline *p = g_new0(RGPipeline, 1);
    p->pipeline = el;
    p->bus = gst_element_get_bus(el);
    return p;
}

void rg_pipeline_free(RGPipeline *p) {
    if (!p) return;
    gst_element_set_state(p->pipeline, GST_STATE_NULL);
    gst_object_unref(p->bus);
    gst_object_unref(p->pipeline);
    g_free(p);
}

static GstElement *find(RGPipeline *p, const char *name) {
    if (!name) return GST_ELEMENT(gst_object_ref(p->pipeline));
    if (GST_IS_BIN(p->pipeline)) return gst_bin_get_by_name(GST_BIN(p->pipeline), name);
    return NULL;
}

static GParamSpec *prop(GstElement *el, const char *property) {
    return g_object_class_find_property(G_OBJECT_GET_CLASS(el), property);
}

int rg_pipeline_set_string(RGPipeline *p, const char *element, const char *property, const char *value) {
    GstElement *el = find(p, element);
    if (!el) return 0;
    int ok = 0;
    GParamSpec *ps = prop(el, property);
    if (ps) {
        if (G_PARAM_SPEC_VALUE_TYPE(ps) == G_TYPE_STRING) {
            g_object_set(el, property, value, NULL);
        } else if (G_PARAM_SPEC_VALUE_TYPE(ps) == GST_TYPE_CAPS) {
            GstCaps *caps = gst_caps_from_string(value);
            g_object_set(el, property, caps, NULL);
            if (caps) gst_caps_unref(caps);
        } else {
            gst_util_set_object_arg(G_OBJECT(el), property, value);
        }
        ok = 1;
    }
    gst_object_unref(el);
    return ok;
}

int rg_pipeline_set_int(RGPipeline *p, const char *element, const char *property, int64_t value) {
    GstElement *el = find(p, element);
    if (!el) return 0;
    GParamSpec *ps = prop(el, property);
    int ok = ps != NULL;
    if (ps) {
        GValue v = G_VALUE_INIT;
        g_value_init(&v, G_PARAM_SPEC_VALUE_TYPE(ps));
        GType t = G_PARAM_SPEC_VALUE_TYPE(ps);
        if (t == G_TYPE_INT) g_value_set_int(&v, (gint)value);
        else if (t == G_TYPE_UINT) g_value_set_uint(&v, (guint)value);
        else if (t == G_TYPE_INT64) g_value_set_int64(&v, value);
        else if (t == G_TYPE_UINT64) g_value_set_uint64(&v, (guint64)value);
        else if (t == G_TYPE_LONG) g_value_set_long(&v, (glong)value);
        else if (t == G_TYPE_ULONG) g_value_set_ulong(&v, (gulong)value);
        else if (G_TYPE_IS_ENUM(t)) g_value_set_enum(&v, (gint)value);
        else if (G_TYPE_IS_FLAGS(t)) g_value_set_flags(&v, (guint)value);
        else if (t == G_TYPE_BOOLEAN) g_value_set_boolean(&v, value != 0);
        else if (t == G_TYPE_DOUBLE) g_value_set_double(&v, (double)value);
        else if (t == G_TYPE_FLOAT) g_value_set_float(&v, (float)value);
        else ok = 0;
        if (ok) g_object_set_property(G_OBJECT(el), property, &v);
        g_value_unset(&v);
    }
    gst_object_unref(el);
    return ok;
}

int rg_pipeline_set_double(RGPipeline *p, const char *element, const char *property, double value) {
    GstElement *el = find(p, element);
    if (!el) return 0;
    GParamSpec *ps = prop(el, property);
    int ok = 0;
    if (ps && G_PARAM_SPEC_VALUE_TYPE(ps) == G_TYPE_DOUBLE) { g_object_set(el, property, value, NULL); ok = 1; }
    else if (ps && G_PARAM_SPEC_VALUE_TYPE(ps) == G_TYPE_FLOAT) { g_object_set(el, property, (float)value, NULL); ok = 1; }
    gst_object_unref(el);
    return ok;
}

int rg_pipeline_set_bool(RGPipeline *p, const char *element, const char *property, int value) {
    GstElement *el = find(p, element);
    if (!el) return 0;
    int ok = prop(el, property) != NULL;
    if (ok) g_object_set(el, property, value ? TRUE : FALSE, NULL);
    gst_object_unref(el);
    return ok;
}

int rg_pipeline_set_bin(RGPipeline *p, const char *element, const char *property, const char *description, char *err, int errlen) {
    GstElement *el = find(p, element);
    if (!el) { set_err(err, errlen, "no such element"); return 0; }
    GError *e = NULL;
    GstElement *bin = gst_parse_bin_from_description(description, TRUE, &e);
    int ok = 0;
    if (bin) {
        g_object_set(el, property, bin, NULL);
        ok = 1;
    } else {
        set_err(err, errlen, e ? e->message : "could not build the bin");
    }
    if (e) g_error_free(e);
    gst_object_unref(el);
    return ok;
}

static GstState gst_state(int s) {
    switch (s) {
    case RG_READY: return GST_STATE_READY;
    case RG_PAUSED: return GST_STATE_PAUSED;
    case RG_PLAYING: return GST_STATE_PLAYING;
    default: return GST_STATE_NULL;
    }
}

/// The first error on the bus, if any (consumed).
static int pop_error(RGPipeline *p, char *err, int errlen) {
    GstMessage *m = gst_bus_pop_filtered(p->bus, GST_MESSAGE_ERROR);
    if (!m) return 0;
    GError *e = NULL;
    gchar *dbg = NULL;
    gst_message_parse_error(m, &e, &dbg);
    set_err(err, errlen, e ? e->message : "pipeline error");
    if (e) g_error_free(e);
    g_free(dbg);
    gst_message_unref(m);
    return 1;
}

int rg_pipeline_set_state(RGPipeline *p, int state, int64_t timeout_ns, char *err, int errlen) {
    GstStateChangeReturn r = gst_element_set_state(p->pipeline, gst_state(state));
    if (r == GST_STATE_CHANGE_ASYNC) {
        r = gst_element_get_state(p->pipeline, NULL, NULL, timeout_ns >= 0 ? (GstClockTime)timeout_ns : GST_CLOCK_TIME_NONE);
    }
    if (r == GST_STATE_CHANGE_FAILURE) {
        if (!pop_error(p, err, errlen)) set_err(err, errlen, "the pipeline could not start");
        return 0;
    }
    if (r == GST_STATE_CHANGE_ASYNC) {
        if (!pop_error(p, err, errlen)) set_err(err, errlen, "timed out starting the pipeline");
        return 0;
    }
    return 1;
}

void rg_pipeline_set_state_async(RGPipeline *p, int state) { gst_element_set_state(p->pipeline, gst_state(state)); }

int rg_pipeline_get_state(RGPipeline *p) {
    GstState s = GST_STATE_NULL, pending = GST_STATE_VOID_PENDING;
    gst_element_get_state(p->pipeline, &s, &pending, 0);
    GstState v = pending != GST_STATE_VOID_PENDING ? pending : s;
    switch (v) {
    case GST_STATE_READY: return RG_READY;
    case GST_STATE_PAUSED: return RG_PAUSED;
    case GST_STATE_PLAYING: return RG_PLAYING;
    default: return RG_NULL;
    }
}

int rg_pipeline_seek(RGPipeline *p, int64_t ns, double rate, int flags) {
    GstSeekFlags f = GST_SEEK_FLAG_FLUSH;
    if (flags & RG_SEEK_ACCURATE) f |= GST_SEEK_FLAG_ACCURATE;
    if (flags & RG_SEEK_KEY) f |= GST_SEEK_FLAG_KEY_UNIT;
    if (flags & RG_SEEK_SNAP_BEFORE) f |= GST_SEEK_FLAG_SNAP_BEFORE;
    if (flags & RG_SEEK_SNAP_AFTER) f |= GST_SEEK_FLAG_SNAP_AFTER;
    p->eos = 0;
    if (rate <= 0) rate = 1.0;
    return gst_element_seek(p->pipeline, rate, GST_FORMAT_TIME, f, GST_SEEK_TYPE_SET, ns < 0 ? 0 : ns,
                            GST_SEEK_TYPE_NONE, GST_CLOCK_TIME_NONE) ? 1 : 0;
}

int64_t rg_pipeline_position(RGPipeline *p) {
    gint64 pos = -1;
    if (!gst_element_query_position(p->pipeline, GST_FORMAT_TIME, &pos)) return -1;
    return pos;
}

int64_t rg_pipeline_duration(RGPipeline *p) {
    gint64 d = -1;
    if (!gst_element_query_duration(p->pipeline, GST_FORMAT_TIME, &d)) return -1;
    return d;
}

typedef struct FramePriv {
    GstSample *sample;
    GstBuffer *buffer;
    GstMapInfo map;
} FramePriv;

int rg_pipeline_pull(RGPipeline *p, const char *sink, int64_t timeout_ns, int preroll, RGFrame *out) {
    memset(out, 0, sizeof(*out));
    GstElement *el = find(p, sink);
    if (!el) return RG_PULL_ERROR;
    if (!GST_IS_APP_SINK(el)) { gst_object_unref(el); return RG_PULL_ERROR; }
    GstAppSink *s = GST_APP_SINK(el);
    GstClockTime t = timeout_ns < 0 ? GST_CLOCK_TIME_NONE : (GstClockTime)timeout_ns;
    GstSample *sample = preroll ? gst_app_sink_try_pull_preroll(s, t) : gst_app_sink_try_pull_sample(s, t);
    int result;
    if (!sample) {
        result = gst_app_sink_is_eos(s) ? RG_PULL_EOS : RG_PULL_TIMEOUT;
        GstMessage *m = gst_bus_pop_filtered(p->bus, GST_MESSAGE_ERROR);
        if (m) { gst_message_unref(m); result = RG_PULL_ERROR; }
        gst_object_unref(el);
        return result;
    }
    gst_object_unref(el);
    GstBuffer *b = gst_sample_get_buffer(sample);
    FramePriv *fp = g_new0(FramePriv, 1);
    fp->sample = sample;
    fp->buffer = b;
    if (!b || !gst_buffer_map(b, &fp->map, GST_MAP_READ)) {
        gst_sample_unref(sample);
        g_free(fp);
        return RG_PULL_ERROR;
    }
    out->priv = fp;
    out->data = fp->map.data;
    out->size = fp->map.size;
    GstSegment *seg = gst_sample_get_segment(sample);
    GstClockTime pts = GST_BUFFER_PTS(b);
    if (seg && GST_CLOCK_TIME_IS_VALID(pts)) {
        guint64 st = gst_segment_to_stream_time(seg, GST_FORMAT_TIME, pts);
        if (st != (guint64)-1) pts = st;
    }
    out->pts = GST_CLOCK_TIME_IS_VALID(pts) ? (int64_t)pts : -1;
    out->duration = GST_BUFFER_DURATION_IS_VALID(b) ? (int64_t)GST_BUFFER_DURATION(b) : -1;
    GstCaps *caps = gst_sample_get_caps(sample);
    if (caps && gst_caps_get_size(caps) > 0) {
        GstStructure *st = gst_caps_get_structure(caps, 0);
        const char *name = gst_structure_get_name(st);
        if (g_str_has_prefix(name, "video/x-raw")) {
            GstVideoInfo vi;
            if (gst_video_info_from_caps(&vi, caps)) {
                out->width = GST_VIDEO_INFO_WIDTH(&vi);
                out->height = GST_VIDEO_INFO_HEIGHT(&vi);
                out->planes = (int)GST_VIDEO_INFO_N_PLANES(&vi);
                GstVideoMeta *vm = gst_buffer_get_video_meta(b);
                for (int i = 0; i < out->planes && i < 4; i++) {
                    out->plane_offset[i] = vm ? (int)vm->offset[i] : (int)GST_VIDEO_INFO_PLANE_OFFSET(&vi, i);
                    out->plane_stride[i] = vm ? vm->stride[i] : GST_VIDEO_INFO_PLANE_STRIDE(&vi, i);
                }
                out->stride = out->plane_stride[0];
                snprintf(out->format, sizeof(out->format), "%s", gst_video_format_to_string(GST_VIDEO_INFO_FORMAT(&vi)));
            }
        } else if (g_str_has_prefix(name, "audio/x-raw")) {
            gst_structure_get_int(st, "rate", &out->rate);
            gst_structure_get_int(st, "channels", &out->channels);
            const char *f = gst_structure_get_string(st, "format");
            if (f) snprintf(out->format, sizeof(out->format), "%s", f);
        }
    }
    return RG_PULL_SAMPLE;
}

void rg_frame_release(RGFrame *f) {
    if (!f || !f->priv) return;
    FramePriv *fp = (FramePriv *)f->priv;
    gst_buffer_unmap(fp->buffer, &fp->map);
    gst_sample_unref(fp->sample);
    g_free(fp);
    f->priv = NULL;
    f->data = NULL;
}

int rg_pipeline_push(RGPipeline *p, const char *src, const void *data, size_t size, int64_t pts, int64_t duration) {
    GstElement *el = find(p, src);
    if (!el || !GST_IS_APP_SRC(el)) { if (el) gst_object_unref(el); return 0; }
    GstBuffer *b = gst_buffer_new_memdup(data, size);
    GST_BUFFER_PTS(b) = pts >= 0 ? (GstClockTime)pts : GST_CLOCK_TIME_NONE;
    GST_BUFFER_DTS(b) = GST_CLOCK_TIME_NONE;
    GST_BUFFER_DURATION(b) = duration >= 0 ? (GstClockTime)duration : GST_CLOCK_TIME_NONE;
    GstFlowReturn r = gst_app_src_push_buffer(GST_APP_SRC(el), b);
    gst_object_unref(el);
    return r == GST_FLOW_OK ? 1 : 0;
}

int rg_pipeline_end_of_stream(RGPipeline *p, const char *src) {
    GstElement *el = find(p, src);
    if (!el || !GST_IS_APP_SRC(el)) { if (el) gst_object_unref(el); return 0; }
    GstFlowReturn r = gst_app_src_end_of_stream(GST_APP_SRC(el));
    gst_object_unref(el);
    return r == GST_FLOW_OK ? 1 : 0;
}

int rg_pipeline_poll(RGPipeline *p, char *err, int errlen) {
    int flags = 0;
    GstMessage *m;
    while ((m = gst_bus_pop_filtered(p->bus, GST_MESSAGE_EOS | GST_MESSAGE_ERROR | GST_MESSAGE_STATE_CHANGED))) {
        switch (GST_MESSAGE_TYPE(m)) {
        case GST_MESSAGE_EOS: flags |= RG_BUS_EOS; p->eos = 1; break;
        case GST_MESSAGE_ERROR:
            if (!(flags & RG_BUS_ERROR)) {
                GError *e = NULL;
                gchar *dbg = NULL;
                gst_message_parse_error(m, &e, &dbg);
                set_err(err, errlen, e ? e->message : "pipeline error");
                if (e) g_error_free(e);
                g_free(dbg);
            }
            flags |= RG_BUS_ERROR;
            break;
        default:
            if (GST_MESSAGE_SRC(m) == GST_OBJECT(p->pipeline)) flags |= RG_BUS_STATE;
            break;
        }
        gst_message_unref(m);
    }
    return flags;
}

int rg_pipeline_wait_eos(RGPipeline *p, int64_t timeout_ns, char *err, int errlen) {
    if (p->eos) return 1;
    GstMessage *m = gst_bus_timed_pop_filtered(p->bus, timeout_ns < 0 ? GST_CLOCK_TIME_NONE : (GstClockTime)timeout_ns,
                                               GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
    if (!m) { set_err(err, errlen, "timed out finishing the file"); return 0; }
    int ok = GST_MESSAGE_TYPE(m) == GST_MESSAGE_EOS;
    if (!ok) {
        GError *e = NULL;
        gchar *dbg = NULL;
        gst_message_parse_error(m, &e, &dbg);
        set_err(err, errlen, e ? e->message : "pipeline error");
        if (e) g_error_free(e);
        g_free(dbg);
    } else {
        p->eos = 1;
    }
    gst_message_unref(m);
    return ok;
}

// MARK: Devices

int rg_list_devices(const char *klass, rg_device_cb cb, void *ctx) {
    if (!rg_init()) return 0;
    GstDeviceMonitor *mon = gst_device_monitor_new();
    gst_device_monitor_add_filter(mon, klass, NULL);
    if (!gst_device_monitor_start(mon)) { gst_object_unref(mon); return 0; }
    GList *devs = gst_device_monitor_get_devices(mon);
    int n = 0;
    for (GList *l = devs; l; l = l->next) {
        GstDevice *d = GST_DEVICE(l->data);
        gchar *name = gst_device_get_display_name(d);
        GstStructure *props = gst_device_get_properties(d);
        const char *id = NULL, *api = NULL;
        gboolean is_default = FALSE;
        if (props) {
            const char *keys[] = {"api.v4l2.path", "device.path", "node.name", "device.name", "object.path", NULL};
            for (int i = 0; keys[i] && !id; i++) id = gst_structure_get_string(props, keys[i]);
            api = gst_structure_get_string(props, "device.api");
            gst_structure_get_boolean(props, "is-default", &is_default);
        }
        cb(ctx, name ? name : "Device", id ? id : (name ? name : ""), api ? api : "", is_default ? 1 : 0);
        n++;
        if (props) gst_structure_free(props);
        g_free(name);
    }
    g_list_free_full(devs, gst_object_unref);
    gst_device_monitor_stop(mon);
    gst_object_unref(mon);
    return n;
}

// MARK: Main-loop timeouts

typedef struct TimeoutCtx { rg_timeout_cb cb; void *ctx; } TimeoutCtx;

static gboolean timeout_trampoline(gpointer data) {
    TimeoutCtx *t = (TimeoutCtx *)data;
    return t->cb(t->ctx) ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
}

unsigned rg_timeout_add(unsigned interval_ms, rg_timeout_cb cb, void *ctx) {
    TimeoutCtx *t = g_new0(TimeoutCtx, 1);
    t->cb = cb;
    t->ctx = ctx;
    return g_timeout_add_full(G_PRIORITY_DEFAULT, interval_ms, timeout_trampoline, t, g_free);
}

void rg_source_remove(unsigned id) { if (id) g_source_remove(id); }

#else

// No GStreamer on this platform: every call fails honestly.
int rg_init(void) { return 0; }
int rg_has_element(const char *name) { (void)name; return 0; }
int rg_discover(const char *uri, int64_t timeout_ns, RGDiscovery *out, char *err, int errlen) {
    (void)uri; (void)timeout_ns;
    memset(out, 0, sizeof(*out));
    if (err && errlen > 0) snprintf(err, (size_t)errlen, "media decoding is not available on this platform");
    return 0;
}
RGPipeline *rg_pipeline_new(const char *d, char *err, int errlen) {
    (void)d;
    if (err && errlen > 0) snprintf(err, (size_t)errlen, "media pipelines are not available on this platform");
    return NULL;
}
void rg_pipeline_free(RGPipeline *p) { (void)p; }
int rg_pipeline_set_string(RGPipeline *p, const char *e, const char *k, const char *v) { (void)p; (void)e; (void)k; (void)v; return 0; }
int rg_pipeline_set_int(RGPipeline *p, const char *e, const char *k, int64_t v) { (void)p; (void)e; (void)k; (void)v; return 0; }
int rg_pipeline_set_double(RGPipeline *p, const char *e, const char *k, double v) { (void)p; (void)e; (void)k; (void)v; return 0; }
int rg_pipeline_set_bool(RGPipeline *p, const char *e, const char *k, int v) { (void)p; (void)e; (void)k; (void)v; return 0; }
int rg_pipeline_set_bin(RGPipeline *p, const char *e, const char *k, const char *d, char *err, int errlen) { (void)p; (void)e; (void)k; (void)d; (void)err; (void)errlen; return 0; }
int rg_pipeline_set_state(RGPipeline *p, int s, int64_t t, char *err, int errlen) { (void)p; (void)s; (void)t; (void)err; (void)errlen; return 0; }
void rg_pipeline_set_state_async(RGPipeline *p, int s) { (void)p; (void)s; }
int rg_pipeline_get_state(RGPipeline *p) { (void)p; return RG_NULL; }
int rg_pipeline_seek(RGPipeline *p, int64_t ns, double r, int f) { (void)p; (void)ns; (void)r; (void)f; return 0; }
int64_t rg_pipeline_position(RGPipeline *p) { (void)p; return -1; }
int64_t rg_pipeline_duration(RGPipeline *p) { (void)p; return -1; }
int rg_pipeline_pull(RGPipeline *p, const char *s, int64_t t, int pr, RGFrame *out) { (void)p; (void)s; (void)t; (void)pr; memset(out, 0, sizeof(*out)); return RG_PULL_ERROR; }
void rg_frame_release(RGFrame *f) { (void)f; }
int rg_pipeline_push(RGPipeline *p, const char *s, const void *d, size_t n, int64_t a, int64_t b) { (void)p; (void)s; (void)d; (void)n; (void)a; (void)b; return 0; }
int rg_pipeline_end_of_stream(RGPipeline *p, const char *s) { (void)p; (void)s; return 0; }
int rg_pipeline_poll(RGPipeline *p, char *err, int errlen) { (void)p; (void)err; (void)errlen; return 0; }
int rg_pipeline_wait_eos(RGPipeline *p, int64_t t, char *err, int errlen) { (void)p; (void)t; (void)err; (void)errlen; return 0; }
int rg_list_devices(const char *k, rg_device_cb cb, void *ctx) { (void)k; (void)cb; (void)ctx; return 0; }
unsigned rg_timeout_add(unsigned i, rg_timeout_cb cb, void *ctx) { (void)i; (void)cb; (void)ctx; return 0; }
void rg_source_remove(unsigned id) { (void)id; }

#endif
