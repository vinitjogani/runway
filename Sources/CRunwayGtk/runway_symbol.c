// SF Symbols as GTK symbolic paintables: an SVG drawn in the foreground
// colour GTK hands it (the widget's CSS `color`), so tints, hover, disabled
// dimming and dark mode follow the theme as with icon-theme icons. The SVG
// comes from RunwayCore's SymbolArt with `currentColor` for the ink or from
// a local template whose alpha masks the tint. GdkPixbuf rasterises the SVG
// at device pixels and the paintable keeps the last texture for redraws.

#include "runway_gtk.h"
#include <string.h>
#include <math.h>

struct _RunwaySymbol {
    GObject parent;
    char *svg;          // with "currentColor" for the ink
    int size;           // logical px (intrinsic size)
    GdkTexture *cache;
    GdkRGBA cache_color;
    int cache_px;
    gboolean is_template;
};

static void runway_symbol_paintable_init(GdkPaintableInterface *iface);
static void runway_symbol_symbolic_init(GtkSymbolicPaintableInterface *iface);

G_DEFINE_TYPE_WITH_CODE(RunwaySymbol, runway_symbol, G_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(GDK_TYPE_PAINTABLE, runway_symbol_paintable_init)
    G_IMPLEMENT_INTERFACE(GTK_TYPE_SYMBOLIC_PAINTABLE, runway_symbol_symbolic_init))

static void runway_symbol_finalize(GObject *o) {
    RunwaySymbol *s = (RunwaySymbol *)o;
    g_free(s->svg);
    g_clear_object(&s->cache);
    G_OBJECT_CLASS(runway_symbol_parent_class)->finalize(o);
}

static void runway_symbol_class_init(RunwaySymbolClass *c) { G_OBJECT_CLASS(c)->finalize = runway_symbol_finalize; }
static void runway_symbol_init(RunwaySymbol *s) { (void)s; }

static char *with_color(const char *svg, const GdkRGBA *c) {
    char hex[32];
    g_snprintf(hex, sizeof hex, "#%02x%02x%02x", (int)lround(c->red * 255), (int)lround(c->green * 255), (int)lround(c->blue * 255));
    GString *out = g_string_new(NULL);
    const char *p = svg, *hit;
    while ((hit = strstr(p, "currentColor"))) {
        g_string_append_len(out, p, hit - p);
        g_string_append(out, hex);
        p = hit + strlen("currentColor");
    }
    g_string_append(out, p);
    // The colour's alpha applies to the whole glyph (overlapping strokes don't darken).
    if (c->alpha < 0.999) {
        char op[48];
        g_snprintf(op, sizeof op, " opacity=\"%.3f\"", c->alpha);
        char *tag = strstr(out->str, "<svg");
        if (tag) g_string_insert(out, (tag - out->str) + 4, op);
    }
    return g_string_free(out, FALSE);
}

static GdkTexture *rasterize(const char *svg, int px) {
    GdkPixbufLoader *l = gdk_pixbuf_loader_new_with_type("svg", NULL);
    if (!l) return NULL;
    gdk_pixbuf_loader_set_size(l, px, px);
    gboolean ok = gdk_pixbuf_loader_write(l, (const guchar *)svg, strlen(svg), NULL);
    ok = gdk_pixbuf_loader_close(l, NULL) && ok;
    GdkTexture *t = NULL;
    GdkPixbuf *pb = ok ? gdk_pixbuf_loader_get_pixbuf(l) : NULL;
    if (pb) {
G_GNUC_BEGIN_IGNORE_DEPRECATIONS
        t = gdk_texture_new_for_pixbuf(pb);
G_GNUC_END_IGNORE_DEPRECATIONS
    }
    g_object_unref(l);
    return t;
}

static void runway_symbol_snapshot_symbolic(GtkSymbolicPaintable *p, GdkSnapshot *snap, double w, double h,
                                            const GdkRGBA *colors, gsize n) {
    RunwaySymbol *s = (RunwaySymbol *)p;
    GdkRGBA fg = n > 0 ? colors[0] : (GdkRGBA){0, 0, 0, 1};
    double side = MIN(w, h);
    // Device pixels: twice the logical size covers 1x and 2x screens crisply.
    int px = (int)ceil(side * 2);
    if (px <= 0) return;
    graphene_rect_t r = GRAPHENE_RECT_INIT((float)((w - side) / 2), (float)((h - side) / 2), (float)side, (float)side);
    if (s->is_template) {
        if (s->cache_px != px) {
            g_clear_object(&s->cache);
            s->cache = rasterize(s->svg, px);
            s->cache_px = px;
        }
        if (s->cache) {
            gtk_snapshot_push_mask(GTK_SNAPSHOT(snap), GSK_MASK_MODE_ALPHA);
            gtk_snapshot_append_scaled_texture(GTK_SNAPSHOT(snap), s->cache, GSK_SCALING_FILTER_TRILINEAR, &r);
            gtk_snapshot_pop(GTK_SNAPSHOT(snap));
            gtk_snapshot_append_color(GTK_SNAPSHOT(snap), &fg, &r);
            gtk_snapshot_pop(GTK_SNAPSHOT(snap));
        }
        return;
    }
    if (!s->cache || s->cache_px != px || !gdk_rgba_equal(&s->cache_color, &fg)) {
        g_clear_object(&s->cache);
        char *svg = with_color(s->svg, &fg);
        s->cache = rasterize(svg, px);
        g_free(svg);
        s->cache_color = fg;
        s->cache_px = px;
    }
    if (!s->cache) return;
    gtk_snapshot_append_scaled_texture(GTK_SNAPSHOT(snap), s->cache, GSK_SCALING_FILTER_TRILINEAR, &r);
}

static void runway_symbol_snapshot(GdkPaintable *p, GdkSnapshot *snap, double w, double h) {
    GdkRGBA black = {0, 0, 0, 0.85};
    runway_symbol_snapshot_symbolic(GTK_SYMBOLIC_PAINTABLE(p), snap, w, h, &black, 1);
}
static int runway_symbol_width(GdkPaintable *p) { return ((RunwaySymbol *)p)->size; }
static int runway_symbol_height(GdkPaintable *p) { return ((RunwaySymbol *)p)->size; }
static GdkPaintableFlags runway_symbol_flags(GdkPaintable *p) { (void)p; return GDK_PAINTABLE_STATIC_CONTENTS | GDK_PAINTABLE_STATIC_SIZE; }

static void runway_symbol_paintable_init(GdkPaintableInterface *i) {
    i->snapshot = runway_symbol_snapshot;
    i->get_intrinsic_width = runway_symbol_width;
    i->get_intrinsic_height = runway_symbol_height;
    i->get_flags = runway_symbol_flags;
}
static void runway_symbol_symbolic_init(GtkSymbolicPaintableInterface *i) { i->snapshot_symbolic = runway_symbol_snapshot_symbolic; }

GdkPaintable *runway_symbol_new(const char *svg, int size) {
    RunwaySymbol *s = g_object_new(runway_symbol_get_type(), NULL);
    s->svg = g_strdup(svg);
    s->size = size > 0 ? size : 16;
    return GDK_PAINTABLE(s);
}

GtkWidget *runway_symbol_image(const char *svg, int size) {
    GdkPaintable *p = runway_symbol_new(svg, size);
    GtkWidget *img = gtk_image_new_from_paintable(p);
    gtk_image_set_pixel_size(GTK_IMAGE(img), size);
    g_object_unref(p);
    return img;
}

GtkWidget *runway_symbol_template_image(const char *svg, int size) {
    int px = MAX(1, size) * 2;
    GdkTexture *texture = rasterize(svg, px);
    if (!texture) return NULL;
    GdkPaintable *p = runway_symbol_new(svg, size);
    RunwaySymbol *s = (RunwaySymbol *)p;
    s->is_template = TRUE;
    s->cache = texture;
    s->cache_px = px;
    GtkWidget *img = gtk_image_new_from_paintable(p);
    gtk_image_set_pixel_size(GTK_IMAGE(img), size);
    g_object_unref(p);
    return img;
}
