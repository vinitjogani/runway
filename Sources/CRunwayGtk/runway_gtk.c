#if defined(__linux__) || defined(__FreeBSD__)
#include "runway_gtk.h"
#include <string.h>

typedef struct { int x, y, w, h; } RunwayRect;
typedef struct { float radius, corner_radius; } RunwayBackdrop;

#define RUNWAY_TYPE_CANVAS (runway_canvas_get_type())
G_DECLARE_FINAL_TYPE(RunwayCanvas, runway_canvas, RUNWAY, CANVAS, GtkWidget)

struct _RunwayCanvas {
    GtkWidget parent_instance;
    int content_w, content_h;
    int last_w, last_h;
    RunwayResizeFunc resize_fn;
    void *resize_data;
    // As a scroll view's document: the viewport's adjustments, watched so
    // a scroll redraws the (culled) children.
    GtkAdjustment *hadj, *vadj;
    gboolean pass_through;
    unsigned backdrop_count;
    // A window's content: the smallest it may get (-1: its content size,
    // as for any canvas), so the window can still be made smaller.
    int min_w, min_h;
};

G_DEFINE_TYPE(RunwayCanvas, runway_canvas, GTK_TYPE_WIDGET)

static GQuark rect_quark(void) {
    static GQuark q = 0;
    if (!q) q = g_quark_from_static_string("runway-rect");
    return q;
}

static GQuark backdrop_quark(void) {
    static GQuark q = 0;
    if (!q) q = g_quark_from_static_string("runway-backdrop");
    return q;
}

static RunwayBackdrop *widget_backdrop(GtkWidget *widget) {
    return g_object_get_qdata(G_OBJECT(widget), backdrop_quark());
}

static void runway_canvas_measure(GtkWidget *widget, GtkOrientation orientation, int for_size,
                                  int *minimum, int *natural, int *min_baseline, int *nat_baseline) {
    RunwayCanvas *self = RUNWAY_CANVAS(widget);
    int v = orientation == GTK_ORIENTATION_HORIZONTAL ? self->content_w : self->content_h;
    if (v < 0) v = 0;
    int m = orientation == GTK_ORIENTATION_HORIZONTAL ? self->min_w : self->min_h;
    *minimum = m >= 0 ? MIN(m, v) : v;
    *natural = v;
    (void)for_size; (void)min_baseline; (void)nat_baseline;
}

static void runway_canvas_size_allocate(GtkWidget *widget, int width, int height, int baseline) {
    RunwayCanvas *self = RUNWAY_CANVAS(widget);
    for (GtkWidget *c = gtk_widget_get_first_child(widget); c; c = gtk_widget_get_next_sibling(c)) {
        /* Popovers parented here (AppKit's NSPopover) are presented, not placed. */
        if (GTK_IS_POPOVER(c)) { gtk_popover_present(GTK_POPOVER(c)); continue; }
        RunwayRect *r = g_object_get_qdata(G_OBJECT(c), rect_quark());
        if (!r || !gtk_widget_get_visible(c)) continue;
        int minw = 0, minh = 0;
        gtk_widget_measure(c, GTK_ORIENTATION_HORIZONTAL, -1, &minw, NULL, NULL, NULL);
        int w = r->w < minw ? minw : r->w;
        gtk_widget_measure(c, GTK_ORIENTATION_VERTICAL, w, &minh, NULL, NULL, NULL);
        int h = r->h < minh ? minh : r->h;
        GtkAllocation a = { r->x, r->y, w, h };
        gtk_widget_size_allocate(c, &a, -1);
    }
    if ((width != self->last_w || height != self->last_h) && self->resize_fn) {
        self->last_w = width;
        self->last_h = height;
        self->resize_fn(width, height, self->resize_data);
    }
    (void)baseline;
}

static void canvas_scrolled(GtkAdjustment *adj, gpointer data) {
    (void)adj;
    gtk_widget_queue_draw(GTK_WIDGET(data));
}

static void canvas_watch(RunwayCanvas *self, GtkAdjustment **slot, GtkAdjustment *adj) {
    if (*slot == adj) return;
    if (*slot) {
        g_signal_handlers_disconnect_by_data(*slot, self);
        g_object_unref(*slot);
    }
    *slot = adj ? g_object_ref(adj) : NULL;
    if (adj) g_signal_connect(adj, "value-changed", G_CALLBACK(canvas_scrolled), self);
}

static void clip_backdrop_slice(GskRenderNode *source, GskRenderNode **slices, guint *count,
                                float x1, float y1, float x2, float y2) {
    if (x2 <= x1 || y2 <= y1) return;
    graphene_rect_t clip = GRAPHENE_RECT_INIT(x1, y1, x2 - x1, y2 - y1);
    slices[(*count)++] = gsk_clip_node_new(source, &clip);
}

static void filter_backdrop(GPtrArray *preceding, const RunwayRect *rect,
                            const RunwayBackdrop *effect, double opacity) {
    if (!rect || rect->w <= 0 || rect->h <= 0 || !preceding->len || opacity <= 0) return;
    graphene_rect_t bounds = GRAPHENE_RECT_INIT(rect->x, rect->y, rect->w, rect->h);
    graphene_rect_t sample = bounds;
    // Leave enough room for the filter kernel while keeping its texture local.
    graphene_rect_inset(&sample, -3 * effect->radius, -3 * effect->radius);
    GskRenderNode *under = gsk_container_node_new((GskRenderNode **)preceding->pdata, preceding->len);
    GskRenderNode *crop = gsk_clip_node_new(under, &sample);
    GskRenderNode *blur = gsk_blur_node_new(crop, effect->radius);
    gsk_render_node_unref(crop);
    float corner = MIN(effect->corner_radius, MIN(rect->w, rect->h) / 2.0f);
    GskRoundedRect clip;
    gsk_rounded_rect_init_from_rect(&clip, &bounds, corner);
    GskRenderNode *diffused = gsk_rounded_clip_node_new(blur, &clip);
    gsk_render_node_unref(blur);

    // Replace the prefix within the clip. Layering a translucent blur on the
    // same sharp pixels would let the original text and seams bleed through.
    GdkRGBA opaque = { 1, 1, 1, 1 };
    GskRenderNode *mask_fill = gsk_color_node_new(&opaque, &bounds);
    GskRenderNode *mask = gsk_rounded_clip_node_new(mask_fill, &clip);
    gsk_render_node_unref(mask_fill);
    GskRenderNode *original = gsk_clip_node_new(under, &bounds);
    GskRenderNode *corners = gsk_mask_node_new(original, mask, GSK_MASK_MODE_INVERTED_ALPHA);
    gsk_render_node_unref(mask);
    GskRenderNode *pieces[] = { corners, diffused };
    GskRenderNode *replacement = gsk_container_node_new(pieces, G_N_ELEMENTS(pieces));
    gsk_render_node_unref(corners);
    gsk_render_node_unref(diffused);
    if (opacity < 1) {
        GskRenderNode *faded = gsk_cross_fade_node_new(original, replacement, opacity);
        gsk_render_node_unref(replacement);
        replacement = faded;
    }
    gsk_render_node_unref(original);

    // Keep the mask's offscreen work limited to the glass rectangle. Outside
    // that rectangle the renderer draws the original content in simple clips.
    graphene_rect_t under_bounds;
    gsk_render_node_get_bounds(under, &under_bounds);
    float left = under_bounds.origin.x, top = under_bounds.origin.y;
    float right = left + under_bounds.size.width, bottom = top + under_bounds.size.height;
    float glass_left = CLAMP(bounds.origin.x, left, right);
    float glass_right = CLAMP(bounds.origin.x + bounds.size.width, left, right);
    float glass_top = CLAMP(bounds.origin.y, top, bottom);
    float glass_bottom = CLAMP(bounds.origin.y + bounds.size.height, top, bottom);
    GskRenderNode *slices[5];
    guint count = 0;
    clip_backdrop_slice(under, slices, &count, left, top, right, glass_top);
    clip_backdrop_slice(under, slices, &count, left, glass_bottom, right, bottom);
    clip_backdrop_slice(under, slices, &count, left, glass_top, glass_left, glass_bottom);
    clip_backdrop_slice(under, slices, &count, glass_right, glass_top, right, glass_bottom);
    slices[count++] = replacement;
    GskRenderNode *result = gsk_container_node_new(slices, count);
    for (guint i = 0; i < count; i++) gsk_render_node_unref(slices[i]);
    gsk_render_node_unref(under);
    g_ptr_array_set_size(preceding, 0);
    g_ptr_array_add(preceding, result);
}

static void snapshot_prefix(GtkSnapshot *snapshot, GPtrArray *preceding) {
    for (guint i = 0; i < preceding->len; i++) gtk_snapshot_append_node(snapshot, preceding->pdata[i]);
}

// Children are snapshotted only where they can be seen. GTK's default
// snapshots every child, and the Cairo renderer then draws every node,
// clipped or not: a scroll view of 2,000 rows (12,000 widgets) repainted
// all of them for each caret blink frame, and kept a render node for each.
// As a scroll view's document (its parent is the GtkViewport GTK wraps it
// in) only children intersecting the visible rectangle, plus a margin, are
// drawn; a scroll queues a redraw so newly visible ones appear.
static void runway_canvas_snapshot(GtkWidget *widget, GtkSnapshot *snapshot) {
    RunwayCanvas *self = RUNWAY_CANVAS(widget);
    GtkWidget *parent = gtk_widget_get_parent(widget);
    gboolean cull = FALSE;
    double vx = 0, vy = 0, vw = 0, vh = 0;
    if (parent && GTK_IS_VIEWPORT(parent)) {
        GtkAdjustment *h = gtk_scrollable_get_hadjustment(GTK_SCROLLABLE(parent));
        GtkAdjustment *v = gtk_scrollable_get_vadjustment(GTK_SCROLLABLE(parent));
        canvas_watch(self, &self->hadj, h);
        canvas_watch(self, &self->vadj, v);
        if (h && v) {
            vx = gtk_adjustment_get_value(h); vw = gtk_adjustment_get_page_size(h);
            vy = gtk_adjustment_get_value(v); vh = gtk_adjustment_get_page_size(v);
            cull = vw > 0 && vh > 0;
        }
    }
    const double margin = 64;
    unsigned backdrop_count = self->backdrop_count;
    GPtrArray *preceding = backdrop_count ? g_ptr_array_new_with_free_func((GDestroyNotify)gsk_render_node_unref) : NULL;
    for (GtkWidget *c = gtk_widget_get_first_child(widget); c; c = gtk_widget_get_next_sibling(c)) {
        if (cull) {
            RunwayRect *r = g_object_get_qdata(G_OBJECT(c), rect_quark());
            if (r) {
                double w = MAX(r->w, gtk_widget_get_width(c)), h = MAX(r->h, gtk_widget_get_height(c));
                if (r->x > vx + vw + margin || r->x + w < vx - margin || r->y > vy + vh + margin || r->y + h < vy - margin) continue;
            }
        }
        if (!preceding) {
            gtk_widget_snapshot_child(widget, c, snapshot);
            continue;
        }
        RunwayBackdrop *effect = widget_backdrop(c);
        if (effect && gtk_widget_get_visible(c)) {
            filter_backdrop(preceding, g_object_get_qdata(G_OBJECT(c), rect_quark()),
                            effect, gtk_widget_get_opacity(c));
            if (--backdrop_count == 0) {
                snapshot_prefix(snapshot, preceding);
                g_clear_pointer(&preceding, g_ptr_array_unref);
                gtk_widget_snapshot_child(widget, c, snapshot);
                continue;
            }
        }
        // Reuse each child's render node for the original canvas and for any
        // following backdrop. Foreground widgets never enter their own blur.
        GtkSnapshot *child_snapshot = gtk_snapshot_new();
        gtk_widget_snapshot_child(widget, c, child_snapshot);
        GskRenderNode *node = gtk_snapshot_free_to_node(child_snapshot);
        if (node) g_ptr_array_add(preceding, node);
    }
    if (preceding) {
        snapshot_prefix(snapshot, preceding);
        g_ptr_array_unref(preceding);
    }
}

static void runway_canvas_dispose(GObject *object) {
    RunwayCanvas *self = RUNWAY_CANVAS(object);
    canvas_watch(self, &self->hadj, NULL);
    canvas_watch(self, &self->vadj, NULL);
    GtkWidget *w = GTK_WIDGET(object);
    GtkWidget *c;
    while ((c = gtk_widget_get_first_child(w))) gtk_widget_unparent(c);
    G_OBJECT_CLASS(runway_canvas_parent_class)->dispose(object);
}

// Picking asks the children first, then whether the widget itself
// contains the point: a pass-through canvas never does.
static gboolean runway_canvas_contains(GtkWidget *widget, double x, double y) {
    if (RUNWAY_CANVAS(widget)->pass_through) return FALSE;
    return GTK_WIDGET_CLASS(runway_canvas_parent_class)->contains(widget, x, y);
}

void runway_canvas_set_pass_through(GtkWidget *canvas, int pass) {
    RUNWAY_CANVAS(canvas)->pass_through = pass != 0;
}

static void runway_canvas_class_init(RunwayCanvasClass *klass) {
    GtkWidgetClass *wc = GTK_WIDGET_CLASS(klass);
    wc->contains = runway_canvas_contains;
    wc->measure = runway_canvas_measure;
    wc->size_allocate = runway_canvas_size_allocate;
    wc->snapshot = runway_canvas_snapshot;
    G_OBJECT_CLASS(klass)->dispose = runway_canvas_dispose;
}

static void runway_canvas_init(RunwayCanvas *self) {
    self->content_w = self->content_h = 0;
    self->last_w = self->last_h = -1;
    self->min_w = self->min_h = -1;
}

void runway_canvas_set_min_size(GtkWidget *canvas, int width, int height) {
    RunwayCanvas *self = RUNWAY_CANVAS(canvas);
    if (self->min_w == width && self->min_h == height) return;
    self->min_w = width;
    self->min_h = height;
    gtk_widget_queue_resize(canvas);
}

GtkWidget *runway_canvas_new(void) { return g_object_new(RUNWAY_TYPE_CANVAS, NULL); }

void runway_canvas_set_content_size(GtkWidget *canvas, int width, int height) {
    RunwayCanvas *self = RUNWAY_CANVAS(canvas);
    if (self->content_w == width && self->content_h == height) return;
    self->content_w = width;
    self->content_h = height;
    gtk_widget_queue_resize(canvas);
}

void runway_canvas_place(GtkWidget *canvas, GtkWidget *child, int x, int y, int width, int height) {
    RunwayRect *r = g_object_get_qdata(G_OBJECT(child), rect_quark());
    if (!r) {
        r = g_new0(RunwayRect, 1);
        g_object_set_qdata_full(G_OBJECT(child), rect_quark(), r, g_free);
    }
    gboolean changed = r->x != x || r->y != y || r->w != width || r->h != height;
    r->x = x; r->y = y; r->w = width; r->h = height;
    if (gtk_widget_get_parent(child) != canvas) {
        gtk_widget_set_parent(child, canvas);
        if (widget_backdrop(child)) RUNWAY_CANVAS(canvas)->backdrop_count++;
        changed = TRUE;
    }
    if (changed) gtk_widget_queue_allocate(canvas);
}

void runway_canvas_raise(GtkWidget *canvas, GtkWidget *child) {
    if (gtk_widget_get_parent(child) == canvas && gtk_widget_get_last_child(canvas) != child)
        gtk_widget_insert_before(child, canvas, NULL);
}

void runway_canvas_remove(GtkWidget *canvas, GtkWidget *child) {
    if (gtk_widget_get_parent(child) == canvas) {
        if (RUNWAY_IS_CANVAS(canvas) && widget_backdrop(child)) RUNWAY_CANVAS(canvas)->backdrop_count--;
        gtk_widget_unparent(child);
    }
}

void runway_widget_set_backdrop_blur(GtkWidget *child, float radius, float corner_radius) {
    gboolean had_backdrop = widget_backdrop(child) != NULL;
    gboolean has_backdrop = radius > 0;
    RunwayBackdrop *effect = NULL;
    if (has_backdrop) {
        effect = g_new(RunwayBackdrop, 1);
        effect->radius = MIN(radius, 64);
        effect->corner_radius = corner_radius > 0 ? corner_radius : 0;
    }
    g_object_set_qdata_full(G_OBJECT(child), backdrop_quark(), effect, g_free);
    GtkWidget *parent = gtk_widget_get_parent(child);
    if (parent && RUNWAY_IS_CANVAS(parent)) {
        if (had_backdrop != has_backdrop) {
            if (has_backdrop) RUNWAY_CANVAS(parent)->backdrop_count++;
            else RUNWAY_CANVAS(parent)->backdrop_count--;
        }
        gtk_widget_queue_draw(parent);
    }
}

void runway_canvas_set_resize_callback(GtkWidget *canvas, RunwayResizeFunc fn, void *user_data) {
    RunwayCanvas *self = RUNWAY_CANVAS(canvas);
    self->resize_fn = fn;
    self->resize_data = user_data;
}

void runway_canvas_set_clip(GtkWidget *canvas, gboolean clip) {
    gtk_widget_set_overflow(canvas, clip ? GTK_OVERFLOW_HIDDEN : GTK_OVERFLOW_VISIBLE);
}

gulong runway_connect(gpointer instance, const char *signal, GCallback cb, gpointer data) {
    return g_signal_connect_data(instance, signal, cb, data, NULL, 0);
}

static gboolean idle_trampoline(gpointer data) {
    gpointer *pair = data;
    ((RunwayVoidFunc)pair[0])(pair[1]);
    g_free(pair);
    return G_SOURCE_REMOVE;
}

void runway_idle(RunwayVoidFunc fn, void *user_data) {
    gpointer *pair = g_new(gpointer, 2);
    pair[0] = (gpointer)fn;
    pair[1] = user_data;
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, idle_trampoline, pair, NULL);
}

void runway_widget_add_css(GtkWidget *w, const char *css_class) { gtk_widget_add_css_class(w, css_class); }
void runway_widget_remove_css(GtkWidget *w, const char *css_class) { gtk_widget_remove_css_class(w, css_class); }

void runway_install_css(const char *css) {
    // One shared provider; installing again replaces its rules (a change
    // between light and dark).
    static GtkCssProvider *p = NULL;
    if (!p) {
        p = gtk_css_provider_new();
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(p),
                                                   GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
    gtk_css_provider_load_from_string(p, css);
}

void runway_settings_set_string(const char *property, const char *value) {
    GtkSettings *s = gtk_settings_get_default();
    if (s) g_object_set(s, property, value, NULL);
}

void runway_popovers_plain(GtkWidget *w) {
    // Mac menus hang from their control without an arrow.
    if (GTK_IS_MENU_BUTTON(w)) {
        GtkPopover *p = gtk_menu_button_get_popover(GTK_MENU_BUTTON(w));
        if (p) gtk_popover_set_has_arrow(p, FALSE);
    }
    for (GtkWidget *c = gtk_widget_get_first_child(w); c; c = gtk_widget_get_next_sibling(c))
        if (GTK_IS_POPOVER(c)) gtk_popover_set_has_arrow(GTK_POPOVER(c), FALSE);
}

static void constrain_popover_on_show(GtkWidget *popup, GtkWidget *anchor) {
    GtkRoot *root = gtk_widget_get_root(anchor);
    graphene_rect_t bounds;
    if (!root || !gtk_widget_compute_bounds(anchor, GTK_WIDGET(root), &bounds)) return;

    int popup_width = 0;
    gtk_widget_measure(popup, GTK_ORIENTATION_HORIZONTAL, -1, NULL, &popup_width, NULL, NULL);
    int viewport_width = gtk_widget_get_width(GTK_WIDGET(root));
    if (popup_width <= 0 || viewport_width <= 0) return;

    int left = (int)(bounds.origin.x + (bounds.size.width - popup_width) / 2);
    int gap = viewport_width - popup_width;
    int inset = MIN(8, MAX(0, gap / 2));
    int clamped = gap < 0 ? gap / 2 : CLAMP(left, inset, gap - inset);
    gtk_popover_set_offset(GTK_POPOVER(popup), clamped - left, 0);
    gtk_popover_present(GTK_POPOVER(popup));
}

static void constrain_menu_popover(GtkWidget *popup, GtkWidget *anchor) {
    const char *key = "runway-constrain-mobile-popover";
    if (!popup || g_object_get_data(G_OBJECT(popup), key)) return;
    g_object_set_data(G_OBJECT(popup), key, GINT_TO_POINTER(1));
    gtk_widget_set_halign(popup, GTK_ALIGN_CENTER);
    g_signal_connect_object(popup, "show", G_CALLBACK(constrain_popover_on_show), anchor, 0);
}

void runway_popovers_constrain_to_window(GtkWidget *w) {
    if (GTK_IS_MENU_BUTTON(w)) {
        constrain_menu_popover(GTK_WIDGET(gtk_menu_button_get_popover(GTK_MENU_BUTTON(w))), w);
        return;
    }
    for (GtkWidget *child = gtk_widget_get_first_child(w); child; child = gtk_widget_get_next_sibling(child)) {
        if (GTK_IS_POPOVER(child)) constrain_menu_popover(child, w);
    }
}

void runway_accessible_label(GtkWidget *w, const char *label) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
}

gboolean runway_prefers_dark(void) {
    const char *forced = g_getenv("RUNWAY_COLOR_SCHEME");
    if (forced) return g_ascii_strcasecmp(forced, "dark") == 0;
    const char *theme = g_getenv("GTK_THEME");
    if (theme && g_str_has_suffix(theme, ":dark")) return TRUE;
    GtkSettings *s = gtk_settings_get_default();
    if (s) {
        gboolean dark = FALSE;
        g_object_get(s, "gtk-application-prefer-dark-theme", &dark, NULL);
        if (dark) return TRUE;
        char *name = NULL;
        g_object_get(s, "gtk-theme-name", &name, NULL);
        gboolean d = name && g_str_has_suffix(name, "-dark");
        g_free(name);
        if (d) return TRUE;
    }
    GSettingsSchemaSource *src = g_settings_schema_source_get_default();
    GSettingsSchema *schema = src ? g_settings_schema_source_lookup(src, "org.gnome.desktop.interface", TRUE) : NULL;
    gboolean dark = FALSE;
    if (schema && g_settings_schema_has_key(schema, "color-scheme")) {
        GSettings *gs = g_settings_new("org.gnome.desktop.interface");
        char *cs = g_settings_get_string(gs, "color-scheme");
        dark = cs && g_strcmp0(cs, "prefer-dark") == 0;
        g_free(cs);
        g_object_unref(gs);
    }
    if (schema) g_settings_schema_unref(schema);
    return dark;
}

static GdkClipboard *clipboard(void) { return gdk_display_get_clipboard(gdk_display_get_default()); }

void runway_clipboard_set_text(const char *text) { gdk_clipboard_set_text(clipboard(), text); }

void runway_clipboard_set_uris(const char *uri_list, const char *plain) {
    GBytes *uris = g_bytes_new(uri_list, strlen(uri_list));
    GBytes *text = g_bytes_new(plain, strlen(plain));
    GdkContentProvider *ps[2] = {
        gdk_content_provider_new_for_bytes("text/uri-list", uris),
        gdk_content_provider_new_for_bytes("text/plain;charset=utf-8", text),
    };
    GdkContentProvider *u = gdk_content_provider_new_union(ps, 2);
    gdk_clipboard_set_content(clipboard(), u);
    g_object_unref(u);
    g_bytes_unref(uris);
    g_bytes_unref(text);
}

typedef struct { gboolean done; char *text; } TextWait;

static void got_text(GObject *src, GAsyncResult *res, gpointer data) {
    TextWait *w = data;
    w->text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(src), res, NULL);
    w->done = TRUE;
}

static void wait_until(gboolean *done, gint64 timeout_us) {
    gint64 end = g_get_monotonic_time() + timeout_us;
    while (!*done && (timeout_us < 0 || g_get_monotonic_time() < end)) g_main_context_iteration(NULL, TRUE);
}

char *runway_clipboard_get_text(void) {
    TextWait w = { FALSE, NULL };
    gdk_clipboard_read_text_async(clipboard(), NULL, got_text, &w);
    wait_until(&w.done, 2 * G_USEC_PER_SEC);
    return w.text;
}

gboolean runway_open_uri(const char *uri) {
    GError *err = NULL;
    gboolean ok = g_app_info_launch_default_for_uri(uri, NULL, &err);
    if (err) g_error_free(err);
    return ok;
}

void runway_reveal_uris(const char *const *uris) {
    if (!uris || !uris[0]) return;
    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (bus) {
        GVariantBuilder b;
        g_variant_builder_init(&b, G_VARIANT_TYPE("as"));
        for (int i = 0; uris[i]; i++) g_variant_builder_add(&b, "s", uris[i]);
        GVariant *r = g_dbus_connection_call_sync(bus, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
                                                  "org.freedesktop.FileManager1", "ShowItems", g_variant_new("(ass)", &b, ""),
                                                  NULL, G_DBUS_CALL_FLAGS_NONE, 3000, NULL, &err);
        g_object_unref(bus);
        if (r) { g_variant_unref(r); return; }
    }
    if (err) g_error_free(err);
    // No file manager service: open the folder.
    GFile *f = g_file_new_for_uri(uris[0]);
    GFile *parent = g_file_get_parent(f);
    if (parent) {
        char *u = g_file_get_uri(parent);
        runway_open_uri(u);
        g_free(u);
        g_object_unref(parent);
    }
    g_object_unref(f);
}

void runway_beep(void) { gdk_display_beep(gdk_display_get_default()); }

typedef struct { gboolean done; char *paths; int choice; } DialogWait;

static char *join_files(GListModel *files) {
    GString *s = g_string_new(NULL);
    guint n = g_list_model_get_n_items(files);
    for (guint i = 0; i < n; i++) {
        GFile *f = g_list_model_get_item(files, i);
        char *p = g_file_get_path(f);
        if (p) { if (s->len) g_string_append_c(s, '\n'); g_string_append(s, p); g_free(p); }
        g_object_unref(f);
    }
    return g_string_free(s, s->len == 0);
}

static void opened_one(GObject *src, GAsyncResult *res, gpointer data) {
    DialogWait *w = data;
    GFile *f = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(src), res, NULL);
    if (f) { w->paths = g_file_get_path(f); g_object_unref(f); }
    w->done = TRUE;
}
static void opened_many(GObject *src, GAsyncResult *res, gpointer data) {
    DialogWait *w = data;
    GListModel *m = gtk_file_dialog_open_multiple_finish(GTK_FILE_DIALOG(src), res, NULL);
    if (m) { w->paths = join_files(m); g_object_unref(m); }
    w->done = TRUE;
}
static void chose_folder(GObject *src, GAsyncResult *res, gpointer data) {
    DialogWait *w = data;
    GFile *f = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(src), res, NULL);
    if (f) { w->paths = g_file_get_path(f); g_object_unref(f); }
    w->done = TRUE;
}
static void saved(GObject *src, GAsyncResult *res, gpointer data) {
    DialogWait *w = data;
    GFile *f = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(src), res, NULL);
    if (f) { w->paths = g_file_get_path(f); g_object_unref(f); }
    w->done = TRUE;
}

char *runway_choose_files(GtkWindow *parent, const char *title, gboolean multiple, gboolean folders, const char *const *extensions) {
    GtkFileDialog *d = gtk_file_dialog_new();
    gtk_file_dialog_set_title(d, title);
    if (extensions && extensions[0]) {
        GtkFileFilter *filter = gtk_file_filter_new();
        for (int i = 0; extensions[i]; i++) gtk_file_filter_add_suffix(filter, extensions[i]);
        GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
        g_list_store_append(filters, filter);
        gtk_file_dialog_set_filters(d, G_LIST_MODEL(filters));
        g_object_unref(filters);
        g_object_unref(filter);
    }
    DialogWait w = { FALSE, NULL, -1 };
    if (folders) gtk_file_dialog_select_folder(d, parent, NULL, chose_folder, &w);
    else if (multiple) gtk_file_dialog_open_multiple(d, parent, NULL, opened_many, &w);
    else gtk_file_dialog_open(d, parent, NULL, opened_one, &w);
    wait_until(&w.done, -1);
    g_object_unref(d);
    return w.paths;
}

char *runway_choose_save(GtkWindow *parent, const char *title, const char *suggested) {
    GtkFileDialog *d = gtk_file_dialog_new();
    gtk_file_dialog_set_title(d, title);
    if (suggested && *suggested) gtk_file_dialog_set_initial_name(d, suggested);
    DialogWait w = { FALSE, NULL, -1 };
    gtk_file_dialog_save(d, parent, NULL, saved, &w);
    wait_until(&w.done, -1);
    g_object_unref(d);
    return w.paths;
}

static void alerted(GObject *src, GAsyncResult *res, gpointer data) {
    DialogWait *w = data;
    w->choice = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(src), res, NULL);
    w->done = TRUE;
}

int runway_alert(GtkWindow *parent, const char *title, const char *message, const char *const *buttons, int cancel_index, int default_index) {
    GtkAlertDialog *d = gtk_alert_dialog_new("%s", title);
    if (message && *message) gtk_alert_dialog_set_detail(d, message);
    gtk_alert_dialog_set_buttons(d, buttons);
    gtk_alert_dialog_set_cancel_button(d, cancel_index);
    gtk_alert_dialog_set_default_button(d, default_index);
    gtk_alert_dialog_set_modal(d, TRUE);
    DialogWait w = { FALSE, NULL, -1 };
    gtk_alert_dialog_choose(d, parent, NULL, alerted, &w);
    wait_until(&w.done, -1);
    g_object_unref(d);
    return w.choice < 0 ? cancel_index : w.choice;
}

typedef struct { RunwayIndexFunc fn; void *data; int index; } MenuAction;

static void menu_activated(GSimpleAction *a, GVariant *param, gpointer data) {
    MenuAction *m = data;
    m->fn(m->index, m->data);
}

void runway_menu_button_set(GtkWidget *menu_button, const char *const *titles, const int *kinds, const int *depths,
                            const gboolean *enabled, const gboolean *checked, int count, RunwayIndexFunc fn, void *user_data) {
    // kinds: 0 item, 1 separator, 2 submenu (its items follow at depth + 1)
    GSimpleActionGroup *group = g_simple_action_group_new();
    GMenu *stack[8];
    GMenu *sections[8];
    stack[0] = g_menu_new();
    sections[0] = g_menu_new();
    g_menu_append_section(stack[0], NULL, G_MENU_MODEL(sections[0]));
    g_object_unref(sections[0]);
    int depth = 0;
    for (int i = 0; i < count; i++) {
        int d = depths[i] < 7 ? depths[i] : 7;
        while (depth > d) depth--;
        if (kinds[i] == 1) {
            sections[depth] = g_menu_new();
            g_menu_append_section(stack[depth], NULL, G_MENU_MODEL(sections[depth]));
            g_object_unref(sections[depth]);
            continue;
        }
        if (kinds[i] == 2 && depth < 7) {
            GMenu *sub = g_menu_new();
            g_menu_append_submenu(sections[depth], titles[i], G_MENU_MODEL(sub));
            g_object_unref(sub);
            depth++;
            stack[depth] = sub;
            sections[depth] = g_menu_new();
            g_menu_append_section(sub, NULL, G_MENU_MODEL(sections[depth]));
            g_object_unref(sections[depth]);
            continue;
        }
        char name[32];
        g_snprintf(name, sizeof name, "i%d", i);
        GSimpleAction *a = checked[i] ? g_simple_action_new_stateful(name, NULL, g_variant_new_boolean(TRUE)) : g_simple_action_new(name, NULL);
        g_simple_action_set_enabled(a, enabled[i]);
        MenuAction *m = g_new(MenuAction, 1);
        m->fn = fn; m->data = user_data; m->index = i;
        g_signal_connect_data(a, "activate", G_CALLBACK(menu_activated), m, (GClosureNotify)g_free, 0);
        g_action_map_add_action(G_ACTION_MAP(group), G_ACTION(a));
        g_object_unref(a);
        char detailed[40];
        g_snprintf(detailed, sizeof detailed, "rw.%s", name);
        g_menu_append(sections[depth], titles[i], detailed);
    }
    gtk_widget_insert_action_group(menu_button, "rw", G_ACTION_GROUP(group));
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(menu_button), G_MENU_MODEL(stack[0]));
    g_object_unref(stack[0]);
    g_object_unref(group);
}

void runway_window_set_child(GtkWidget *window, GtkWidget *child) { gtk_window_set_child(GTK_WINDOW(window), child); }

GtkWidget *runway_drop_down_new(void) {
    const char *none[] = { NULL };
    return gtk_drop_down_new_from_strings(none);
}

/* Pop-up menu rows as the Mac draws them: a checkmark column, then the
   title. The checkmark is drawn by CSS for `row:selected`. */
static void menu_row_setup(GtkSignalListItemFactory *f, GtkListItem *item, gpointer data) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    GtkWidget *check = gtk_image_new();
    gtk_widget_add_css_class(check, "rw-menu-check");
    gtk_box_append(GTK_BOX(box), check);
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_box_append(GTK_BOX(box), label);
    gtk_list_item_set_child(item, box);
    (void)f; (void)data;
}

static void menu_row_bind(GtkSignalListItemFactory *f, GtkListItem *item, gpointer data) {
    GtkWidget *box = gtk_list_item_get_child(item);
    GObject *obj = gtk_list_item_get_item(item);
    const char *text = GTK_IS_STRING_OBJECT(obj) ? gtk_string_object_get_string(GTK_STRING_OBJECT(obj)) : "";
    gtk_label_set_text(GTK_LABEL(gtk_widget_get_last_child(box)), text);
    (void)f; (void)data;
}

void runway_drop_down_mac_menu(GtkWidget *dd) {
    GtkListItemFactory *f = gtk_signal_list_item_factory_new();
    g_signal_connect(f, "setup", G_CALLBACK(menu_row_setup), NULL);
    g_signal_connect(f, "bind", G_CALLBACK(menu_row_bind), NULL);
    gtk_drop_down_set_list_factory(GTK_DROP_DOWN(dd), f);
    g_object_unref(f);
}

void runway_drop_down_set_strings(GtkWidget *dd, const char *const *strings) {
    GtkStringList *l = gtk_string_list_new(strings);
    gtk_drop_down_set_model(GTK_DROP_DOWN(dd), G_LIST_MODEL(l));
    g_object_unref(l);
}

gboolean runway_widget_save_scaled_png(GtkWidget *w, GtkWidget *content, const char *path, guint scale) {
    int width = gtk_widget_get_width(w), height = gtk_widget_get_height(w);
    if (width <= 0 || height <= 0) return FALSE;
    GtkNative *native = gtk_widget_get_native(w);
    GskRenderer *r = native ? gtk_native_get_renderer(native) : NULL;
    if (!r) return FALSE;
    graphene_rect_t bounds = GRAPHENE_RECT_INIT(0, 0, width, height);
    if (content && !gtk_widget_compute_bounds(content, w, &bounds)) return FALSE;
    GdkPaintable *p = gtk_widget_paintable_new(w);
    GtkSnapshot *s = gtk_snapshot_new();
    gdk_paintable_snapshot(p, s, width, height);
    GskRenderNode *node = gtk_snapshot_free_to_node(s);
    g_object_unref(p);
    if (!node) return FALSE;
    scale = CLAMP(scale, 1, 4);
    if (scale > 1) {
        // Scale the render node before rasterization and keep the same crop
        // in logical points, including the origin below the desktop title bar.
        GskTransform *transform = gsk_transform_scale(NULL, scale, scale);
        GskRenderNode *scaled = gsk_transform_node_new(node, transform);
        gsk_transform_unref(transform);
        gsk_render_node_unref(node);
        node = scaled;
        bounds.origin.x *= scale;
        bounds.origin.y *= scale;
        bounds.size.width *= scale;
        bounds.size.height *= scale;
    }
    GdkTexture *t = gsk_renderer_render_texture(r, node, &bounds);
    gboolean ok = t && gdk_texture_save_to_png(t, path);
    if (t) g_object_unref(t);
    gsk_render_node_unref(node);
    return ok;
}

gboolean runway_widget_save_content_png(GtkWidget *w, GtkWidget *content, const char *path) {
    return runway_widget_save_scaled_png(w, content, path, 1);
}

gboolean runway_widget_save_png(GtkWidget *w, const char *path) {
    return runway_widget_save_content_png(w, NULL, path);
}

static GtkWidget *find_popup_owner(GtkWidget *w, int *n) {
    if (GTK_IS_DROP_DOWN(w) || GTK_IS_MENU_BUTTON(w)) {
        if ((*n)-- == 0) return w;
        return NULL;
    }
    for (GtkWidget *c = gtk_widget_get_first_child(w); c; c = gtk_widget_get_next_sibling(c)) {
        GtkWidget *r = find_popup_owner(c, n);
        if (r) return r;
    }
    return NULL;
}

GtkWidget *runway_debug_popup(GtkWidget *root, int index) {
    int n = index;
    GtkWidget *w = find_popup_owner(root, &n);
    if (!w) return NULL;
    if (GTK_IS_MENU_BUTTON(w)) {
        gtk_menu_button_popup(GTK_MENU_BUTTON(w));
        return GTK_WIDGET(gtk_menu_button_get_popover(GTK_MENU_BUTTON(w)));
    }
    g_signal_emit_by_name(w, "activate");
    for (GtkWidget *c = gtk_widget_get_first_child(w); c; c = gtk_widget_get_next_sibling(c))
        if (GTK_IS_POPOVER(c)) return c;
    return NULL;
}

static gboolean timeout_trampoline(gpointer data) {
    gpointer *pair = data;
    ((RunwayVoidFunc)pair[0])(pair[1]);
    g_free(pair);
    return G_SOURCE_REMOVE;
}

void runway_timeout(unsigned ms, RunwayVoidFunc fn, void *user_data) {
    gpointer *pair = g_new(gpointer, 2);
    pair[0] = (gpointer)fn;
    pair[1] = user_data;
    g_timeout_add(ms, timeout_trampoline, pair);
}
#endif
