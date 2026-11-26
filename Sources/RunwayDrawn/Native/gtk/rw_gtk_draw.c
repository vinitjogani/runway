// Drawing with Cairo, text with Pango, images as Cairo surfaces: the
// rw_draw_*, rw_path_*, rw_text_* and rw_image_* calls, matching the
// Direct2D binding's semantics (DIPs, straight colours, an offset with an
// optional transform before it, clips that keep the current transform).
#if defined(__linux__) || defined(__FreeBSD__)
#include "rw_gtk.h"
#include <gdk-pixbuf/gdk-pixbuf.h>

// MARK: Passes

static void reset_pass(rw_window *w) {
    w->offset_x = w->offset_y = 0;
    w->has_transform = FALSE;
    w->alpha = 1;
    w->paint.kind = 0;
    w->paint.color = (rw_color){0, 0, 0, 1};
    if (w->paint.pattern) { cairo_pattern_destroy(w->paint.pattern); w->paint.pattern = NULL; }
    g_free(w->dashes);
    w->dashes = NULL;
    w->dash_count = 0;
    w->round_caps = FALSE;
    w->clip_depth = 0;
}

void rwg_begin_surface(rw_window *s, cairo_t *cr) {
    s->cr = cr;
    cairo_save(cr);
    cairo_get_matrix(cr, &s->base);
    reset_pass(s);
}

void rwg_end_surface(rw_window *s) {
    if (!s->cr) return;
    while (s->clip_depth > 0) rw_draw_pop_clip(s);
    cairo_restore(s->cr);
    reset_pass(s);
    s->cr = NULL;
}

void rwg_apply_matrix(rw_window *w) {
    cairo_set_matrix(w->cr, &w->base);
    cairo_translate(w->cr, w->offset_x, w->offset_y);
    if (w->has_transform) cairo_transform(w->cr, &w->transform);
}

void rw_draw_clear(rw_window *w, rw_color c) {
    if (!w->cr) return;
    cairo_save(w->cr);
    cairo_set_operator(w->cr, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_rgba(w->cr, c.r, c.g, c.b, 1);
    cairo_paint(w->cr);
    cairo_restore(w->cr);
}

void rw_draw_set_offset(rw_window *w, double x, double y) {
    if (!w->cr) return;
    w->offset_x = x;
    w->offset_y = y;
    w->has_transform = FALSE;
    rwg_apply_matrix(w);
}

void rw_draw_set_transform(rw_window *w, double a, double b, double c, double d, double tx, double ty) {
    if (!w->cr) return;
    cairo_matrix_init(&w->transform, a, b, c, d, tx, ty);
    w->has_transform = !(a == 1 && b == 0 && c == 0 && d == 1 && tx == 0 && ty == 0);
    rwg_apply_matrix(w);
}

void rw_draw_set_alpha(rw_window *w, float alpha) { w->alpha = alpha < 0 ? 0 : alpha > 1 ? 1 : alpha; }

void rw_draw_push_clip(rw_window *w, double x, double y, double width, double height) {
    if (!w->cr) return;
    cairo_save(w->cr);
    cairo_new_path(w->cr);
    cairo_rectangle(w->cr, x, y, width, height);
    cairo_clip(w->cr);
    w->clip_depth++;
}

static void append_path(cairo_t *cr, rw_path *p);

void rw_draw_push_clip_path(rw_window *w, rw_path *p) {
    if (!w->cr) return;
    cairo_save(w->cr);
    append_path(w->cr, p);
    cairo_clip(w->cr);
    w->clip_depth++;
}

void rw_draw_pop_clip(rw_window *w) {
    if (!w->cr || w->clip_depth == 0) return;
    cairo_restore(w->cr);
    w->clip_depth--;
    rwg_apply_matrix(w);   // the clip goes, the transform stays
}

void rw_draw_paint_color(rw_window *w, rw_color c) {
    w->paint.kind = 0;
    w->paint.color = c;
}

static void set_paint_pattern(rw_window *w, cairo_pattern_t *p, const rw_stop *stops, int count) {
    for (int i = 0; i < count; i++)
        cairo_pattern_add_color_stop_rgba(p, stops[i].location, stops[i].color.r, stops[i].color.g, stops[i].color.b, stops[i].color.a);
    cairo_pattern_set_extend(p, CAIRO_EXTEND_PAD);
    if (w->paint.pattern) cairo_pattern_destroy(w->paint.pattern);
    w->paint.pattern = p;
    w->paint.kind = 1;
}

void rw_draw_paint_linear(rw_window *w, double x0, double y0, double x1, double y1, const rw_stop *stops, int count) {
    set_paint_pattern(w, cairo_pattern_create_linear(x0, y0, x1, y1), stops, count);
}

void rw_draw_paint_radial(rw_window *w, double cx, double cy, double r0, double r1, const rw_stop *stops, int count) {
    set_paint_pattern(w, cairo_pattern_create_radial(cx, cy, r0, cx, cy, r1), stops, count);
}

void rw_draw_set_dash(rw_window *w, const float *dashes, int count) {
    g_free(w->dashes);
    w->dashes = NULL;
    w->dash_count = 0;
    if (count <= 0 || !dashes) return;
    w->dashes = g_new(double, count);
    for (int i = 0; i < count; i++) w->dashes[i] = dashes[i];
    w->dash_count = count;
}

void rw_draw_set_round_caps(rw_window *w, int round) { w->round_caps = round != 0; }

/// Fills (or strokes) the current path with the current paint and alpha.
static void finish(rw_window *w, int fill, double line_width) {
    cairo_t *cr = w->cr;
    if (w->paint.kind == 1 && w->paint.pattern) {
        cairo_set_source(cr, w->paint.pattern);
    } else {
        rw_color c = w->paint.color;
        cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a * w->alpha);
    }
    if (fill) {
        if (w->paint.kind == 1 && w->alpha < 1) {
            cairo_save(cr);
            cairo_clip(cr);
            cairo_paint_with_alpha(cr, w->alpha);
            cairo_restore(cr);
        } else {
            cairo_fill(cr);
        }
        return;
    }
    cairo_set_line_width(cr, line_width);
    cairo_set_line_cap(cr, w->round_caps ? CAIRO_LINE_CAP_ROUND : CAIRO_LINE_CAP_BUTT);
    cairo_set_line_join(cr, w->round_caps ? CAIRO_LINE_JOIN_ROUND : CAIRO_LINE_JOIN_MITER);
    if (w->dash_count > 0) {
        // Like Direct2D's, dashes are in units of the line width.
        double d[16];
        int n = w->dash_count < 16 ? w->dash_count : 16;
        for (int i = 0; i < n; i++) d[i] = w->dashes[i] * (line_width > 0 ? line_width : 1);
        cairo_set_dash(cr, d, n, 0);
    } else {
        cairo_set_dash(cr, NULL, 0, 0);
    }
    cairo_stroke(cr);
}

static void rounded(cairo_t *cr, double x, double y, double w, double h, double r) {
    r = fmin(r, fmin(w, h) / 2);
    if (r <= 0) { cairo_rectangle(cr, x, y, w, h); return; }
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
    cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
    cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
    cairo_close_path(cr);
}

void rw_draw_rect(rw_window *w, int fill, double x, double y, double width, double height, double radius, double line_width) {
    if (!w->cr || width <= 0 || height <= 0) return;
    cairo_new_path(w->cr);
    rounded(w->cr, x, y, width, height, radius);
    finish(w, fill, line_width);
}

void rw_draw_ellipse(rw_window *w, int fill, double x, double y, double width, double height, double line_width) {
    if (!w->cr || width <= 0 || height <= 0) return;
    cairo_new_path(w->cr);
    cairo_save(w->cr);
    cairo_translate(w->cr, x + width / 2, y + height / 2);
    cairo_scale(w->cr, width / 2, height / 2);
    cairo_arc(w->cr, 0, 0, 1, 0, 2 * M_PI);
    cairo_restore(w->cr);
    finish(w, fill, line_width);
}

void rw_draw_line(rw_window *w, double x0, double y0, double x1, double y1, double line_width) {
    if (!w->cr) return;
    cairo_new_path(w->cr);
    cairo_move_to(w->cr, x0, y0);
    cairo_line_to(w->cr, x1, y1);
    finish(w, 0, line_width);
}

// MARK: Paths

typedef struct { int kind; double v[6]; } PathOp;   // 0 move, 1 line, 2 quad, 3 cubic, 4 close

struct rw_path {
    GArray *ops;
    gboolean even_odd;
};

rw_path *rw_path_create(void) {
    rw_path *p = g_new0(rw_path, 1);
    p->ops = g_array_new(FALSE, FALSE, sizeof(PathOp));
    return p;
}

static void add_op(rw_path *p, int kind, double a, double b, double c, double d, double e, double f) {
    PathOp op = {kind, {a, b, c, d, e, f}};
    g_array_append_val(p->ops, op);
}

void rw_path_move(rw_path *p, double x, double y) { add_op(p, 0, x, y, 0, 0, 0, 0); }
void rw_path_line(rw_path *p, double x, double y) { add_op(p, 1, x, y, 0, 0, 0, 0); }
void rw_path_quad(rw_path *p, double cx, double cy, double x, double y) { add_op(p, 2, cx, cy, x, y, 0, 0); }
void rw_path_cubic(rw_path *p, double c1x, double c1y, double c2x, double c2y, double x, double y) { add_op(p, 3, c1x, c1y, c2x, c2y, x, y); }
void rw_path_close(rw_path *p) { add_op(p, 4, 0, 0, 0, 0, 0, 0); }
void rw_path_set_even_odd(rw_path *p, int on) { if (p) p->even_odd = on != 0; }

void rw_path_free(rw_path *p) {
    if (!p) return;
    g_array_free(p->ops, TRUE);
    g_free(p);
}

static void append_path(cairo_t *cr, rw_path *p) {
    cairo_new_path(cr);
    double cx = 0, cy = 0;
    gboolean open = FALSE;
    for (guint i = 0; i < p->ops->len; i++) {
        PathOp *o = &g_array_index(p->ops, PathOp, i);
        if (o->kind != 0 && o->kind != 4 && !open) { cairo_move_to(cr, cx, cy); open = TRUE; }
        switch (o->kind) {
        case 0: cairo_move_to(cr, o->v[0], o->v[1]); cx = o->v[0]; cy = o->v[1]; open = TRUE; break;
        case 1: cairo_line_to(cr, o->v[0], o->v[1]); cx = o->v[0]; cy = o->v[1]; break;
        case 2: {
            double x1 = cx + 2.0 / 3.0 * (o->v[0] - cx), y1 = cy + 2.0 / 3.0 * (o->v[1] - cy);
            double x2 = o->v[2] + 2.0 / 3.0 * (o->v[0] - o->v[2]), y2 = o->v[3] + 2.0 / 3.0 * (o->v[1] - o->v[3]);
            cairo_curve_to(cr, x1, y1, x2, y2, o->v[2], o->v[3]);
            cx = o->v[2]; cy = o->v[3];
            break;
        }
        case 3: cairo_curve_to(cr, o->v[0], o->v[1], o->v[2], o->v[3], o->v[4], o->v[5]); cx = o->v[4]; cy = o->v[5]; break;
        case 4: cairo_close_path(cr); open = FALSE; break;
        }
    }
    cairo_set_fill_rule(cr, p->even_odd ? CAIRO_FILL_RULE_EVEN_ODD : CAIRO_FILL_RULE_WINDING);
}

void rw_draw_path(rw_window *w, int fill, rw_path *p, double line_width) {
    if (!w->cr || !p || p->ops->len == 0) return;
    append_path(w->cr, p);
    finish(w, fill, line_width);
}

// MARK: Text

struct rw_text {
    char *string;
    PangoAttrList *attrs;
    int alignment, line_limit, truncation;
    PangoLayout *layout;
};

static PangoContext *measure_context(void) {
    static PangoContext *c;
    if (!c) {
        c = pango_font_map_create_context(pango_cairo_font_map_get_default());
        // Device-independent: sizes are DIPs, the metrics unhinted, as DirectWrite's.
        cairo_font_options_t *o = cairo_font_options_create();
        cairo_font_options_set_hint_metrics(o, CAIRO_HINT_METRICS_OFF);
        pango_cairo_context_set_font_options(c, o);
        cairo_font_options_destroy(o);
        pango_context_set_round_glyph_positions(c, FALSE);
    }
    return c;
}

static PangoWeight weight_of(int w) {
    if (w <= 150) return PANGO_WEIGHT_THIN;
    if (w <= 250) return PANGO_WEIGHT_ULTRALIGHT;
    if (w <= 350) return PANGO_WEIGHT_LIGHT;
    if (w <= 450) return PANGO_WEIGHT_NORMAL;
    if (w <= 550) return PANGO_WEIGHT_MEDIUM;
    if (w <= 650) return PANGO_WEIGHT_SEMIBOLD;
    if (w <= 750) return PANGO_WEIGHT_BOLD;
    if (w <= 850) return PANGO_WEIGHT_ULTRABOLD;
    return PANGO_WEIGHT_HEAVY;
}

static guint16 channel(float v) { return (guint16)lroundf((v < 0 ? 0 : v > 1 ? 1 : v) * 65535); }

rw_text *rw_text_create(const rw_text_run *runs, int count, int alignment, int line_limit, int truncation) {
    rw_text *t = g_new0(rw_text, 1);
    t->alignment = alignment;
    t->line_limit = line_limit;
    t->truncation = truncation;
    t->attrs = pango_attr_list_new();
    GString *s = g_string_new(NULL);
    for (int i = 0; i < count; i++) {
        const rw_text_run *r = &runs[i];
        guint start = (guint)s->len;
        if (r->text) g_string_append(s, r->text);
        guint end = (guint)s->len;
        if (end == start) continue;
        PangoFontDescription *d = pango_font_description_new();
        const char *family = r->family && *r->family ? r->family : (rwg.ui_family ? rwg.ui_family : "Sans");
        pango_font_description_set_family(d, family);
        pango_font_description_set_absolute_size(d, (r->size > 0 ? r->size : 13) * PANGO_SCALE);
        pango_font_description_set_weight(d, weight_of(r->weight));
        if (r->italic) pango_font_description_set_style(d, PANGO_STYLE_ITALIC);
        PangoAttribute *a = pango_attr_font_desc_new(d);
        a->start_index = start; a->end_index = end;
        pango_attr_list_insert(t->attrs, a);
        pango_font_description_free(d);
        if (r->tabular_digits) {
            a = pango_attr_font_features_new("tnum");
            a->start_index = start; a->end_index = end;
            pango_attr_list_insert(t->attrs, a);
        }
        if (r->underline) {
            a = pango_attr_underline_new(PANGO_UNDERLINE_SINGLE);
            a->start_index = start; a->end_index = end;
            pango_attr_list_insert(t->attrs, a);
        }
        if (r->strikethrough) {
            a = pango_attr_strikethrough_new(TRUE);
            a->start_index = start; a->end_index = end;
            pango_attr_list_insert(t->attrs, a);
        }
        if (r->has_color) {
            a = pango_attr_foreground_new(channel(r->color.r), channel(r->color.g), channel(r->color.b));
            a->start_index = start; a->end_index = end;
            pango_attr_list_insert(t->attrs, a);
            if (r->color.a < 1) {
                // Pango takes an alpha of 0 as "unset": the least visible alpha instead.
                a = pango_attr_foreground_alpha_new(r->color.a > 0 ? channel(r->color.a) : 1);
                a->start_index = start; a->end_index = end;
                pango_attr_list_insert(t->attrs, a);
            }
        }
    }
    t->string = g_string_free(s, FALSE);
    return t;
}

void rw_text_free(rw_text *t) {
    if (!t) return;
    if (t->layout) g_object_unref(t->layout);
    pango_attr_list_unref(t->attrs);
    g_free(t->string);
    g_free(t);
}

/// The layout wrapped to `width` (<= 0: unlimited), with the line limit and truncation.
static PangoLayout *layout_for(rw_text *t, double width) {
    if (!t->layout) {
        t->layout = pango_layout_new(measure_context());
        pango_layout_set_text(t->layout, t->string, -1);
        pango_layout_set_attributes(t->layout, t->attrs);
        pango_layout_set_alignment(t->layout, t->alignment == RW_ALIGN_CENTER ? PANGO_ALIGN_CENTER
                                            : t->alignment == RW_ALIGN_TRAILING ? PANGO_ALIGN_RIGHT : PANGO_ALIGN_LEFT);
        pango_layout_set_wrap(t->layout, PANGO_WRAP_WORD_CHAR);
    }
    PangoLayout *l = t->layout;
    pango_layout_set_width(l, width > 0 ? (int)lround(width * PANGO_SCALE) : -1);
    if (t->line_limit > 0 && width > 0) {
        PangoEllipsizeMode mode = t->truncation == RW_TRUNCATE_HEAD ? PANGO_ELLIPSIZE_START
                                : t->truncation == RW_TRUNCATE_MIDDLE ? PANGO_ELLIPSIZE_MIDDLE : PANGO_ELLIPSIZE_END;
        pango_layout_set_ellipsize(l, mode);
        pango_layout_set_height(l, -t->line_limit);
    } else {
        pango_layout_set_ellipsize(l, PANGO_ELLIPSIZE_NONE);
        pango_layout_set_height(l, -1);
    }
    return l;
}

void rw_text_measure(rw_text *t, double max_width, double *width, double *height) {
    *width = 0; *height = 0;
    if (!t) return;
    PangoLayout *l = layout_for(t, max_width > 0 ? max_width : 0);
    PangoRectangle ink, logical;
    pango_layout_get_extents(l, &ink, &logical);
    double w = (double)logical.width / PANGO_SCALE, h = (double)logical.height / PANGO_SCALE;
    if (t->line_limit > 0 && max_width <= 0 && t->line_limit < pango_layout_get_line_count(l)) {
        // Unwrapped, but limited: the first lines' height.
        PangoLayoutIter *it = pango_layout_get_iter(l);
        double bottom = 0;
        int n = 0;
        do {
            int y0, y1;
            pango_layout_iter_get_line_yrange(it, &y0, &y1);
            bottom = (double)y1 / PANGO_SCALE;
        } while (++n < t->line_limit && pango_layout_iter_next_line(it));
        pango_layout_iter_free(it);
        h = bottom;
    }
    if (max_width > 0 && w > max_width) w = max_width;
    *width = w;
    *height = h;
}

int rw_text_baselines(rw_text *t, double max_width, double *out, int max) {
    if (!t) return 0;
    PangoLayout *l = layout_for(t, max_width > 0 ? max_width : 0);
    PangoLayoutIter *it = pango_layout_get_iter(l);
    int n = 0;
    do {
        if (n >= max || (t->line_limit > 0 && n >= t->line_limit)) break;
        out[n++] = (double)pango_layout_iter_get_baseline(it) / PANGO_SCALE;
    } while (pango_layout_iter_next_line(it));
    pango_layout_iter_free(it);
    return n;
}

void rw_draw_text(rw_window *w, rw_text *t, double x, double y, double width, double height, rw_color color) {
    if (!w->cr || !t || !t->string[0]) return;
    PangoLayout *l = layout_for(t, width > 0 ? width : 0);
    cairo_t *cr = w->cr;
    cairo_save(cr);
    if (height > 0) {
        cairo_rectangle(cr, x - 2, y - 2, (width > 0 ? width : 1e5) + 4, height + 4);
        cairo_clip(cr);
    }
    cairo_move_to(cr, x, y);
    cairo_set_source_rgba(cr, color.r, color.g, color.b, color.a);
    if (w->alpha < 1) {
        cairo_push_group(cr);
        pango_cairo_show_layout(cr, l);
        cairo_pop_group_to_source(cr);
        cairo_paint_with_alpha(cr, w->alpha);
    } else {
        pango_cairo_show_layout(cr, l);
    }
    cairo_restore(cr);
}

// MARK: Images

struct rw_image {
    cairo_surface_t *surface;
    int width, height;
};

static rw_image *from_pixbuf(GdkPixbuf *pb) {
    if (!pb) return NULL;
    int w = gdk_pixbuf_get_width(pb), h = gdk_pixbuf_get_height(pb);
    rw_image *img = g_new0(rw_image, 1);
    img->width = w;
    img->height = h;
    img->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    cairo_surface_flush(img->surface);
    unsigned char *dst = cairo_image_surface_get_data(img->surface);
    int ds = cairo_image_surface_get_stride(img->surface);
    const guchar *src = gdk_pixbuf_read_pixels(pb);
    int ss = gdk_pixbuf_get_rowstride(pb), nc = gdk_pixbuf_get_n_channels(pb);
    gboolean alpha = gdk_pixbuf_get_has_alpha(pb);
    for (int y = 0; y < h; y++) {
        const guchar *s = src + y * ss;
        guint32 *d = (guint32 *)(dst + y * ds);
        for (int x = 0; x < w; x++) {
            guint a = alpha ? s[x * nc + 3] : 255;
            guint r = s[x * nc] * a / 255, g = s[x * nc + 1] * a / 255, b = s[x * nc + 2] * a / 255;
            d[x] = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }
    cairo_surface_mark_dirty(img->surface);
    return img;
}

rw_image *rw_image_load_file(const char *path) {
    GdkPixbuf *pb = gdk_pixbuf_new_from_file(path, NULL);
    if (!pb) return NULL;
    GdkPixbuf *oriented = gdk_pixbuf_apply_embedded_orientation(pb);
    rw_image *img = from_pixbuf(oriented ? oriented : pb);
    if (oriented) g_object_unref(oriented);
    g_object_unref(pb);
    return img;
}

rw_image *rw_image_from_rgba(int width, int height, const uint8_t *rgba) {
    if (width <= 0 || height <= 0 || !rgba) return NULL;
    GdkPixbuf *pb = gdk_pixbuf_new_from_data(rgba, GDK_COLORSPACE_RGB, TRUE, 8, width, height, width * 4, NULL, NULL);
    rw_image *img = from_pixbuf(pb);
    g_object_unref(pb);
    return img;
}

void rw_image_size(rw_image *img, int *width, int *height) {
    *width = img ? img->width : 0;
    *height = img ? img->height : 0;
}

void rw_image_free(rw_image *img) {
    if (!img) return;
    cairo_surface_destroy(img->surface);
    g_free(img);
}

void rw_draw_image(rw_window *w, rw_image *img, double x, double y, double width, double height) {
    if (!w->cr || !img || width <= 0 || height <= 0) return;
    cairo_t *cr = w->cr;
    cairo_save(cr);
    cairo_translate(cr, x, y);
    cairo_scale(cr, width / img->width, height / img->height);
    cairo_set_source_surface(cr, img->surface, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    cairo_pattern_set_extend(cairo_get_source(cr), CAIRO_EXTEND_PAD);
    cairo_rectangle(cr, 0, 0, img->width, img->height);
    cairo_clip(cr);
    cairo_paint_with_alpha(cr, w->alpha);
    cairo_restore(cr);
}

#endif
