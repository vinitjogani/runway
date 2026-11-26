// Text input over the drawn content: GtkText / GtkTextView for edits and
// Runway's GtkTextView (runway_text_view, CRunwayGtk) for rich text, each in
// a clipping container placed over the drawing area, as the Win32 binding
// places EDIT and RichEdit children.
#if defined(__linux__) || defined(__FreeBSD__)
#include "rw_gtk.h"
#include "runway_controls.h"

// MARK: The clipping container

typedef struct {
    GtkWidget parent_instance;
    GtkWidget *child;
    int ox, oy, cw, ch;
    // Placement asked for while the window was painting, applied on idle
    // (widgets can't move in the middle of a snapshot).
    gboolean pending, pending_visible;
    int pm[4], po[4];
    guint idle;
} RwClip;
typedef struct { GtkWidgetClass parent_class; } RwClipClass;
GType rw_clip_get_type(void);
G_DEFINE_TYPE(RwClip, rw_clip, GTK_TYPE_WIDGET)

static void rw_clip_measure(GtkWidget *w, GtkOrientation o, int for_size, int *min, int *nat, int *mb, int *nb) {
    (void)w; (void)o; (void)for_size;
    *min = *nat = 0;   // its size request decides
    *mb = *nb = -1;
}

static void rw_clip_allocate(GtkWidget *w, int width, int height, int baseline) {
    (void)width; (void)height; (void)baseline;
    RwClip *c = (RwClip *)w;
    if (!c->child || !gtk_widget_get_visible(c->child)) return;
    // The child keeps its frame; what falls outside the container is cut away.
    int min = 0, nat = 0;
    gtk_widget_measure(c->child, GTK_ORIENTATION_HORIZONTAL, -1, &min, &nat, NULL, NULL);
    int cw = c->cw > min ? c->cw : min;
    gtk_widget_measure(c->child, GTK_ORIENTATION_VERTICAL, cw, &min, &nat, NULL, NULL);
    int ch = c->ch > min ? c->ch : min;
    graphene_point_t p = GRAPHENE_POINT_INIT((float)c->ox, (float)c->oy);
    gtk_widget_allocate(c->child, cw, ch, -1, gsk_transform_translate(NULL, &p));
}

static void rw_clip_dispose(GObject *o) {
    RwClip *c = (RwClip *)o;
    if (c->child) { gtk_widget_unparent(c->child); c->child = NULL; }
    G_OBJECT_CLASS(rw_clip_parent_class)->dispose(o);
}

static void rw_clip_class_init(RwClipClass *k) {
    GTK_WIDGET_CLASS(k)->measure = rw_clip_measure;
    GTK_WIDGET_CLASS(k)->size_allocate = rw_clip_allocate;
    G_OBJECT_CLASS(k)->dispose = rw_clip_dispose;
}

static void rw_clip_init(RwClip *c) { gtk_widget_set_overflow(GTK_WIDGET(c), GTK_OVERFLOW_HIDDEN); }

GtkWidget *rwg_clipper_new(rw_window *w) {
    GtkWidget *c = g_object_new(rw_clip_get_type(), NULL);
    gtk_widget_set_halign(c, GTK_ALIGN_START);
    gtk_widget_set_valign(c, GTK_ALIGN_START);
    gtk_widget_set_visible(c, FALSE);
    gtk_overlay_add_overlay(GTK_OVERLAY(w->overlay), c);
    return c;
}

static void clip_set_child(GtkWidget *clipper, GtkWidget *child) {
    RwClip *c = (RwClip *)clipper;
    c->child = child;
    gtk_widget_set_parent(child, clipper);
}

static void apply_place(RwClip *c, gboolean visible, const int m[4], const int o[4]) {
    GtkWidget *clipper = GTK_WIDGET(c);
    if (!visible) {
        if (gtk_widget_get_visible(clipper)) {
            GtkRoot *root = gtk_widget_get_root(clipper);
            GtkWidget *f = root ? gtk_root_get_focus(root) : NULL;
            if (f && (f == c->child || gtk_widget_is_ancestor(f, clipper))) gtk_root_set_focus(root, NULL);
            gtk_widget_set_visible(clipper, FALSE);
        }
        return;
    }
    gboolean changed = c->ox != o[0] || c->oy != o[1] || c->cw != o[2] || c->ch != o[3] ||
                       gtk_widget_get_margin_start(clipper) != m[0] || gtk_widget_get_margin_top(clipper) != m[1];
    int rw = 0, rh = 0;
    gtk_widget_get_size_request(clipper, &rw, &rh);
    changed = changed || rw != m[2] || rh != m[3];
    c->ox = o[0]; c->oy = o[1]; c->cw = o[2]; c->ch = o[3];
    if (changed) {
        gtk_widget_set_margin_start(clipper, m[0]);
        gtk_widget_set_margin_top(clipper, m[1]);
        gtk_widget_set_size_request(clipper, m[2], m[3]);
        gtk_widget_queue_allocate(clipper);
    }
    if (!gtk_widget_get_visible(clipper)) gtk_widget_set_visible(clipper, TRUE);
}

static gboolean apply_pending(gpointer data) {
    RwClip *c = data;
    c->idle = 0;
    if (c->pending) { c->pending = FALSE; apply_place(c, c->pending_visible, c->pm, c->po); }
    g_object_unref(c);
    return G_SOURCE_REMOVE;
}

void rwg_clipper_place(rw_window *w, GtkWidget *clipper, GtkWidget *child, double x, double y, double width, double height,
                       double cx, double cy, double cw, double ch, int visible) {
    (void)child;
    RwClip *c = (RwClip *)clipper;
    double vx = fmax(x, cx), vy = fmax(y, cy);
    double vr = fmin(x + width, cx + cw), vb = fmin(y + height, cy + ch);
    gboolean show = visible && vr - vx >= 1 && vb - vy >= 1;
    int m[4] = {(int)lround(vx), (int)lround(vy), (int)lround(vr - vx), (int)lround(vb - vy)};
    int o[4] = {(int)lround(x - vx), (int)lround(y - vy), (int)lround(width), (int)lround(height)};
    if (!w->cr) { c->pending = FALSE; apply_place(c, show, m, o); return; }
    c->pending = TRUE;
    c->pending_visible = show;
    memcpy(c->pm, m, sizeof m);
    memcpy(c->po, o, sizeof o);
    if (!c->idle) c->idle = g_idle_add_full(G_PRIORITY_HIGH_IDLE, apply_pending, g_object_ref(c), NULL);
}

// MARK: Presses in native children

gboolean rwg_child_pointer(rw_window *w, GtkWidget *child, double x, double y, int button, gboolean release, gboolean after) {
    if (!w || !w->ctx) return FALSE;
    graphene_point_t p = GRAPHENE_POINT_INIT((float)x, (float)y), out;
    if (!gtk_widget_compute_point(child, w->area, &p, &out)) return FALSE;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = after ? RW_EV_CHILD_MOUSE_AFTER : RW_EV_CHILD_MOUSE;
    ev.ctx = w->ctx;
    ev.x = out.x;
    ev.y = out.y;
    ev.button = button;
    ev.flags = release ? RW_MOUSE_RELEASE : 0;
    return rwg_send_event(&ev) != 0;
}

typedef struct { rw_window *window; GtkWidget *child; gboolean after; } ChildPointer;

static gboolean child_event(GtkEventControllerLegacy *c, GdkEvent *e, gpointer data) {
    (void)c;
    ChildPointer *cp = data;
    GdkEventType t = gdk_event_get_event_type(e);
    if (t != GDK_BUTTON_PRESS && t != GDK_BUTTON_RELEASE) return FALSE;
    double ex, ey;
    if (!gdk_event_get_position(e, &ex, &ey)) return FALSE;
    GtkNative *native = gtk_widget_get_native(cp->child);
    if (!native) return FALSE;
    double sx = 0, sy = 0;
    gtk_native_get_surface_transform(native, &sx, &sy);
    graphene_point_t p = GRAPHENE_POINT_INIT((float)(ex - sx), (float)(ey - sy)), out;
    if (!gtk_widget_compute_point(GTK_WIDGET(native), cp->child, &p, &out)) return FALSE;
    guint b = gdk_button_event_get_button(e);
    int button = b == 1 ? 0 : b == 3 ? 1 : b == 2 ? 2 : (int)b - 1;
    gboolean taken = rwg_child_pointer(cp->window, cp->child, out.x, out.y, button, t == GDK_BUTTON_RELEASE, cp->after);
    return cp->after ? FALSE : taken;
}

static void watch_presses(rw_window *w, GtkWidget *child) {
    for (int after = 0; after < 2; after++) {
        ChildPointer *cp = g_new0(ChildPointer, 1);
        cp->window = w;
        cp->child = child;
        cp->after = after;
        GtkEventController *c = gtk_event_controller_legacy_new();
        gtk_event_controller_set_propagation_phase(c, after ? GTK_PHASE_BUBBLE : GTK_PHASE_CAPTURE);
        g_signal_connect_data(c, "event", G_CALLBACK(child_event), cp, (GClosureNotify)(void (*)(void))g_free, 0);
        gtk_widget_add_controller(child, c);
    }
}

// MARK: Offsets

int rwg_utf16_to_chars(const char *s, int utf16) {
    int u = 0, n = 0;
    for (const char *p = s; *p && u < utf16; p = g_utf8_next_char(p)) {
        gunichar c = g_utf8_get_char(p);
        u += c > 0xFFFF ? 2 : 1;
        n++;
    }
    return n;
}

int rwg_chars_to_utf16(const char *s, int chars) {
    int u = 0, n = 0;
    for (const char *p = s; *p && n < chars; p = g_utf8_next_char(p)) {
        gunichar c = g_utf8_get_char(p);
        u += c > 0xFFFF ? 2 : 1;
        n++;
    }
    return u;
}

/// A CSS provider of the widget's own (a class only it has).
static void own_css(GtkWidget *w, GtkCssProvider **provider, char **klass, const char *css_format_selector, const char *body) {
    static int next = 0;
    if (!*provider) {
        *provider = gtk_css_provider_new();
        *klass = g_strdup_printf("rw-own-%d", ++next);
        gtk_widget_add_css_class(w, *klass);
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(*provider),
                                                   GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 5);
    }
    char *css = g_strdup_printf(css_format_selector, *klass, *klass, body, body);
    gtk_css_provider_load_from_string(*provider, css);
    g_free(css);
}

static char *css_rgba(rw_color c) {
    return g_strdup_printf("rgba(%d,%d,%d,%.3f)", (int)lroundf(c.r * 255), (int)lroundf(c.g * 255), (int)lroundf(c.b * 255), c.a);
}

// MARK: Edits

struct rw_edit {
    rw_window *window;
    void *ctx;
    gboolean multiline, updating;
    GtkWidget *clipper, *widget;
    GtkCssProvider *css;
    char *klass;
    char *style;
};

static void edit_changed(rw_edit *e) {
    if (!e->updating && e->ctx) rwg_send(RW_EV_EDIT_CHANGED, e->ctx);
}
static void text_changed(GtkEditable *ed, gpointer data) { (void)ed; edit_changed(data); }
static void buffer_changed(GtkTextBuffer *b, gpointer data) { (void)b; edit_changed(data); }

static void edit_activate(GtkText *t, gpointer data) {
    (void)t;
    rw_edit *e = data;
    if (e->ctx && rwg_send(RW_EV_EDIT_SUBMIT, e->ctx)) return;
    if (!e->window) return;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_KEY_DOWN;
    ev.ctx = e->window->ctx;
    ev.key = 0x0D;
    rwg_send_event(&ev);
}

static void edit_focus_in(GtkEventControllerFocus *f, gpointer data) { (void)f; rw_edit *e = data; if (e->ctx) rwg_send(RW_EV_EDIT_FOCUS, e->ctx); }
static void edit_focus_out(GtkEventControllerFocus *f, gpointer data) { (void)f; rw_edit *e = data; if (e->ctx) rwg_send(RW_EV_EDIT_BLUR, e->ctx); }

static gboolean edit_key(GtkEventControllerKey *k, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    (void)k; (void)keycode;
    rw_edit *e = data;
    if (!e->ctx) return FALSE;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_EDIT_KEY;
    ev.ctx = e->ctx;
    ev.key = rwg_vk(keyval);
    ev.mods = rwg_mods(state);
    return ev.key && rwg_send_event(&ev);
}

rw_edit *rw_edit_create(rw_window *w, int multiline, void *ctx) {
    if (!w) return NULL;
    rw_edit *e = g_new0(rw_edit, 1);
    e->window = w;
    e->ctx = ctx;
    e->multiline = multiline != 0;
    if (e->multiline) {
        e->widget = gtk_text_view_new();
        gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(e->widget), GTK_WRAP_WORD_CHAR);
        g_signal_connect(gtk_text_view_get_buffer(GTK_TEXT_VIEW(e->widget)), "changed", G_CALLBACK(buffer_changed), e);
    } else {
        e->widget = gtk_text_new();
        gtk_editable_set_width_chars(GTK_EDITABLE(e->widget), 1);
        g_signal_connect(e->widget, "changed", G_CALLBACK(text_changed), e);
        g_signal_connect(e->widget, "activate", G_CALLBACK(edit_activate), e);
    }
    gtk_widget_add_css_class(e->widget, "rw-edit");
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(edit_focus_in), e);
    g_signal_connect(focus, "leave", G_CALLBACK(edit_focus_out), e);
    gtk_widget_add_controller(e->widget, focus);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(edit_key), e);
    gtk_widget_add_controller(e->widget, keys);
    watch_presses(w, e->widget);
    e->clipper = rwg_clipper_new(w);
    clip_set_child(e->clipper, e->widget);
    return e;
}

void rw_edit_destroy(rw_edit *e) {
    if (!e) return;
    e->ctx = NULL;
    if (e->clipper && e->window && e->window->overlay && !e->window->destroyed) {
        GtkWidget *f = gtk_root_get_focus(GTK_ROOT(gtk_widget_get_root(e->window->area)));
        if (f && (f == e->widget || gtk_widget_is_ancestor(f, e->clipper))) gtk_widget_grab_focus(e->window->area);
        gtk_overlay_remove_overlay(GTK_OVERLAY(e->window->overlay), e->clipper);
    }
    if (e->css) {
        gtk_style_context_remove_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(e->css));
        g_object_unref(e->css);
    }
    g_free(e->klass);
    g_free(e->style);
    g_free(e);
}

void rw_edit_set_frame(rw_edit *e, double x, double y, double width, double height, double cx, double cy, double cw, double ch, int visible) {
    if (!e || !e->window || e->window->destroyed) return;
    rwg_clipper_place(e->window, e->clipper, e->widget, x, y, width, height, cx, cy, cw, ch, visible);
}

void rw_edit_set_text(rw_edit *e, const char *text) {
    if (!e) return;
    e->updating = TRUE;
    if (e->multiline) {
        GtkTextBuffer *b = gtk_text_view_get_buffer(GTK_TEXT_VIEW(e->widget));
        gtk_text_buffer_set_text(b, text ? text : "", -1);
        GtkTextIter end;
        gtk_text_buffer_get_end_iter(b, &end);
        gtk_text_buffer_place_cursor(b, &end);
    } else {
        gtk_editable_set_text(GTK_EDITABLE(e->widget), text ? text : "");
        gtk_editable_set_position(GTK_EDITABLE(e->widget), -1);
    }
    e->updating = FALSE;
}

char *rw_edit_copy_text(rw_edit *e) {
    if (!e) return strdup("");
    if (e->multiline) {
        GtkTextBuffer *b = gtk_text_view_get_buffer(GTK_TEXT_VIEW(e->widget));
        GtkTextIter a, z;
        gtk_text_buffer_get_bounds(b, &a, &z);
        char *t = gtk_text_buffer_get_text(b, &a, &z, FALSE);
        char *out = strdup(t);
        g_free(t);
        return out;
    }
    return strdup(gtk_editable_get_text(GTK_EDITABLE(e->widget)));
}

void rw_edit_set_style(rw_edit *e, float size, int weight, rw_color text, rw_color background, int password) {
    if (!e) return;
    char *fg = css_rgba(text), *bg = css_rgba(background);
    char *body = g_strdup_printf("font-family: \"%s\"; font-size: %.1fpx; font-weight: %d; color: %s; background: %s; caret-color: %s; "
                                 "padding: 0; margin: 0; border: none; box-shadow: none; outline: none; min-height: 0; min-width: 0;",
                                 rwg.ui_family ? rwg.ui_family : "Sans", size, weight, fg, bg, fg);
    if (!e->style || strcmp(body, e->style) != 0) {
        g_free(e->style);
        e->style = body;
        // The widget, and a text view's text area.
        own_css(e->widget, &e->css, &e->klass, ".%s, .%s > text { %s } /* %s */", body);
    } else {
        g_free(body);
    }
    g_free(fg);
    g_free(bg);
    if (!e->multiline) gtk_text_set_visibility(GTK_TEXT(e->widget), !password);
}

void rw_edit_set_placeholder(rw_edit *e, const char *text) {
    if (e && !e->multiline) gtk_text_set_placeholder_text(GTK_TEXT(e->widget), text);
}

void rw_edit_set_enabled(rw_edit *e, int enabled) { if (e) gtk_widget_set_sensitive(e->widget, enabled != 0); }

void rw_edit_focus(rw_edit *e, int select_all) {
    if (!e) return;
    if (e->multiline) { gtk_widget_grab_focus(e->widget); return; }
    if (select_all) { gtk_widget_grab_focus(e->widget); gtk_editable_select_region(GTK_EDITABLE(e->widget), 0, -1); }
    else gtk_text_grab_focus_without_selecting(GTK_TEXT(e->widget));
}

int rw_edit_has_focus(rw_edit *e) { return e && gtk_widget_has_focus(e->widget) ? 1 : 0; }

void rw_edit_set_alignment(rw_edit *e, int alignment) {
    if (!e) return;
    float x = alignment == RW_ALIGN_CENTER ? 0.5f : alignment == RW_ALIGN_TRAILING ? 1.0f : 0.0f;
    if (e->multiline) gtk_text_view_set_justification(GTK_TEXT_VIEW(e->widget), alignment == RW_ALIGN_CENTER ? GTK_JUSTIFY_CENTER
                                                      : alignment == RW_ALIGN_TRAILING ? GTK_JUSTIFY_RIGHT : GTK_JUSTIFY_LEFT);
    else gtk_editable_set_alignment(GTK_EDITABLE(e->widget), x);
}

void rw_edit_set_readonly(rw_edit *e, int readonly) {
    if (!e) return;
    if (e->multiline) gtk_text_view_set_editable(GTK_TEXT_VIEW(e->widget), !readonly);
    else gtk_editable_set_editable(GTK_EDITABLE(e->widget), !readonly);
}

// MARK: Rich text

struct rw_rich {
    rw_window *window;
    void *ctx;
    GtkWidget *clipper, *view;
    gboolean updating, takes_typing, wraps;
    double insets[4];
    rw_window *surface;
    GHashTable *tags;            // run key -> GtkTextTag
    GtkCssProvider *css;
    char *klass;
    int clicks;
    guint32 last_click;
    double last_x, last_y;
};

static GtkTextBuffer *rich_buffer(rw_rich *r) { return gtk_text_view_get_buffer(GTK_TEXT_VIEW(r->view)); }

static char *rich_text(rw_rich *r) {
    GtkTextIter a, z;
    gtk_text_buffer_get_bounds(rich_buffer(r), &a, &z);
    return gtk_text_buffer_get_text(rich_buffer(r), &a, &z, TRUE);
}

static void rich_draw(int layer, cairo_t *cr, void *data) {
    rw_rich *r = data;
    if (!r->ctx) return;
    if (!r->surface) r->surface = g_new0(rw_window, 1);
    rwg_begin_surface(r->surface, cr);
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_RICH_PAINT;
    ev.ctx = r->ctx;
    ev.button = layer;
    rwg_send_event(&ev);
    rwg_end_surface(r->surface);
}

static gboolean rich_pointer(int kind, double x, double y, int button, unsigned modifiers, double time, void *data) {
    rw_rich *r = data;
    if (!r->ctx) return FALSE;
    gboolean up = kind != 0;
    if (!up) {
        guint32 now = (guint32)(time * 1000);
        if (now - r->last_click <= 400 && fabs(x - r->last_x) < 5 && fabs(y - r->last_y) < 5) r->clicks++;
        else r->clicks = 1;
        r->last_click = now;
        r->last_x = x;
        r->last_y = y;
    }
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_RICH_POINTER;
    ev.ctx = r->ctx;
    ev.x = x;
    ev.y = y;
    ev.button = button;
    ev.flags = up ? RW_MOUSE_RELEASE : 0;
    ev.clicks = r->clicks;
    ev.mods = rwg_mods((GdkModifierType)modifiers);
    return rwg_send_event(&ev) != 0;
}

static gboolean rich_insert(const char *text, void *data) {
    rw_rich *r = data;
    if (!r->ctx || !r->takes_typing) return FALSE;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_RICH_CHAR;
    ev.ctx = r->ctx;
    ev.text = text;
    return rwg_send_event(&ev) != 0;
}

static void rich_delete(int start, int end, void *data) { (void)start; (void)end; (void)data; }   // the buffer's change reports it

static void rich_selection(int start, int end, gboolean dragging, void *data) {
    (void)start; (void)end;
    rw_rich *r = data;
    if (r->updating || !r->ctx) return;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_RICH_SELECTION;
    ev.ctx = r->ctx;
    if (dragging) ev.flags = RW_KEY_REPEAT;
    rwg_send_event(&ev);
}

static void rich_height(int height, void *data) {
    rw_rich *r = data;
    if (!r->ctx) return;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_RICH_HEIGHT;
    ev.ctx = r->ctx;
    ev.dy = height;
    rwg_send_event(&ev);
}

static void rich_changed(GtkTextBuffer *b, gpointer data) {
    (void)b;
    rw_rich *r = data;
    if (!r->updating && r->ctx) rwg_send(RW_EV_RICH_CHANGED, r->ctx);
}

static void rich_focus_in(GtkEventControllerFocus *f, gpointer data) {
    (void)f;
    rw_rich *r = data;
    if (!r->ctx) return;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_RICH_FOCUS;
    ev.ctx = r->ctx;
    ev.button = 1;
    rwg_send_event(&ev);
}
static void rich_focus_out(GtkEventControllerFocus *f, gpointer data) {
    (void)f;
    rw_rich *r = data;
    if (r->ctx) rwg_send(RW_EV_RICH_FOCUS, r->ctx);
}

static gboolean rich_key(GtkEventControllerKey *k, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    (void)k; (void)keycode;
    rw_rich *r = data;
    if (!r->ctx) return FALSE;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_RICH_KEY;
    ev.ctx = r->ctx;
    ev.key = rwg_vk(keyval);
    ev.mods = rwg_mods(state);
    return ev.key && rwg_send_event(&ev);
}

rw_rich *rw_rich_create(rw_window *w, void *ctx) {
    if (!w) return NULL;
    rw_rich *r = g_new0(rw_rich, 1);
    r->window = w;
    r->ctx = ctx;
    r->wraps = TRUE;
    r->insets[0] = 5; r->insets[2] = 5;
    r->tags = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    r->view = runway_text_view_new();
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(r->view), GTK_WRAP_WORD_CHAR);
    // AppKit keeps the undo stack (NSTextView registers its changes).
    gtk_text_buffer_set_enable_undo(rich_buffer(r), FALSE);
    gtk_widget_add_css_class(r->view, "rw-rich");
    RunwayTextViewCallbacks cb;
    memset(&cb, 0, sizeof cb);
    cb.draw = rich_draw;
    cb.pointer = rich_pointer;
    cb.insert = rich_insert;
    cb.delete_range = rich_delete;
    cb.selection = rich_selection;
    cb.height = rich_height;
    cb.data = r;
    runway_text_view_set_callbacks(r->view, &cb);
    g_signal_connect(rich_buffer(r), "changed", G_CALLBACK(rich_changed), r);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(rich_focus_in), r);
    g_signal_connect(focus, "leave", G_CALLBACK(rich_focus_out), r);
    gtk_widget_add_controller(r->view, focus);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(rich_key), r);
    gtk_widget_add_controller(r->view, keys);
    // Monitors see presses first; the view's own pointer callback does the rest.
    for (int i = 0; i < 1; i++) {
        ChildPointer *cp = g_new0(ChildPointer, 1);
        cp->window = w;
        cp->child = r->view;
        GtkEventController *c = gtk_event_controller_legacy_new();
        gtk_event_controller_set_propagation_phase(c, GTK_PHASE_CAPTURE);
        g_signal_connect_data(c, "event", G_CALLBACK(child_event), cp, (GClosureNotify)(void (*)(void))g_free, 0);
        gtk_widget_add_controller(r->view, c);
    }
    r->clipper = rwg_clipper_new(w);
    clip_set_child(r->clipper, r->view);
    return r;
}

void rw_rich_destroy(rw_rich *r) {
    if (!r) return;
    r->ctx = NULL;
    if (r->clipper && r->window && r->window->overlay && !r->window->destroyed) {
        GtkWidget *f = gtk_root_get_focus(GTK_ROOT(gtk_widget_get_root(r->window->area)));
        if (f && (f == r->view || gtk_widget_is_ancestor(f, r->clipper))) gtk_widget_grab_focus(r->window->area);
        gtk_overlay_remove_overlay(GTK_OVERLAY(r->window->overlay), r->clipper);
    }
    if (r->css) {
        gtk_style_context_remove_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(r->css));
        g_object_unref(r->css);
    }
    g_hash_table_destroy(r->tags);
    g_free(r->klass);
    g_free(r->surface);
    g_free(r);
}

void rw_rich_set_frame(rw_rich *r, double x, double y, double width, double height, double cx, double cy, double cw, double ch, int visible) {
    if (!r || !r->window || r->window->destroyed) return;
    rwg_clipper_place(r->window, r->clipper, r->view, x, y, width, height, cx, cy, cw, ch, visible);
}

static char *pango_font(const rw_rich_run *run) {
    const char *family = run->family && *run->family ? run->family : (rwg.ui_family ? rwg.ui_family : "Sans");
    const char *weight = run->weight >= 850 ? " Heavy" : run->weight >= 750 ? " Bold" : run->weight >= 650 ? " Semi-Bold"
                       : run->weight >= 550 ? " Medium" : run->weight <= 250 ? " Thin" : run->weight <= 350 ? " Light" : "";
    return g_strdup_printf("%s%s%s %.1fpx", family, weight, run->italic ? " Italic" : "", run->size > 0 ? run->size : 13);
}

static char *hex(rw_color c, float alpha) {
    return g_strdup_printf("#%02x%02x%02x%02x", (int)lroundf(c.r * 255), (int)lroundf(c.g * 255), (int)lroundf(c.b * 255),
                           (int)lroundf((alpha < 0 ? c.a : alpha) * 255));
}

static GtkTextTag *tag_for(rw_rich *r, const rw_rich_run *run) {
    char *font = pango_font(run);
    char *fg = run->has_color ? hex(run->color, run->color.a > 0 ? run->color.a : 1.0f / 255) : NULL;
    char *bg = run->has_background && run->background.a > 0 ? hex(run->background, -1) : NULL;
    int just = !run->has_paragraph ? -1 : run->alignment == 3 ? 3 : run->alignment == RW_ALIGN_CENTER ? 2 : run->alignment == RW_ALIGN_TRAILING ? 1 : 0;
    char *key = g_strdup_printf("%s|%s|%s|%d|%d|%.2f|%d|%d|%d|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.2f|%.0f", font, fg ? fg : "", bg ? bg : "",
                                run->underline, run->strikethrough, run->baseline_offset, run->hidden, run->has_paragraph, just,
                                run->line_spacing, run->paragraph_spacing, run->spacing_before, run->first_indent, run->head_indent,
                                run->tail_indent, run->line_height_multiple, r->insets[0] * 1000 + r->insets[2]);
    GtkTextTag *t = g_hash_table_lookup(r->tags, key);
    if (!t) {
        t = runway_text_tag_new(rich_buffer(r), font, fg, bg, run->underline != 0, run->strikethrough != 0,
                                (int)lround(run->baseline_offset * PANGO_SCALE), 0, just,
                                run->has_paragraph ? (int)lround(r->insets[0] + run->head_indent) : -1,
                                run->has_paragraph ? (int)lround(run->first_indent - run->head_indent) : G_MININT,
                                run->has_paragraph ? (int)lround(r->insets[2] + fmax(0, -run->tail_indent)) : -1,
                                run->has_paragraph ? (int)lround(run->spacing_before) : -1,
                                run->has_paragraph ? (int)lround(run->paragraph_spacing) : -1,
                                run->has_paragraph ? (int)lround(run->line_spacing) : -1);
        runway_text_tag_set_more(t, run->hidden != 0, run->line_height_multiple, NULL, NULL, run->underline ? run->underline : 1);
        g_hash_table_insert(r->tags, g_strdup(key), t);
    }
    g_free(key);
    g_free(font);
    g_free(fg);
    g_free(bg);
    return t;
}

/// Replaces characters [start, end) with the runs' text, then styles it.
static void replace_chars(rw_rich *r, int start, int end, const rw_rich_run *runs, int count) {
    GtkTextBuffer *b = rich_buffer(r);
    r->updating = TRUE;
    runway_text_view_set_programmatic(r->view, TRUE);
    GtkTextIter a, z;
    gtk_text_buffer_get_iter_at_offset(b, &a, start);
    gtk_text_buffer_get_iter_at_offset(b, &z, end);
    GString *all = g_string_new(NULL);
    for (int i = 0; i < count; i++) if (runs[i].text) g_string_append(all, runs[i].text);
    char *old = gtk_text_buffer_get_text(b, &a, &z, TRUE);
    if (strcmp(old, all->str) != 0) {
        gtk_text_buffer_delete(b, &a, &z);
        gtk_text_buffer_get_iter_at_offset(b, &a, start);
        gtk_text_buffer_insert(b, &a, all->str, -1);
    }
    g_free(old);
    int n = (int)g_utf8_strlen(all->str, -1);
    gtk_text_buffer_get_iter_at_offset(b, &a, start);
    gtk_text_buffer_get_iter_at_offset(b, &z, start + n);
    gtk_text_buffer_remove_all_tags(b, &a, &z);
    int at = start;
    for (int i = 0; i < count; i++) {
        int len = runs[i].text ? (int)g_utf8_strlen(runs[i].text, -1) : 0;
        if (!len) continue;
        gtk_text_buffer_get_iter_at_offset(b, &a, at);
        gtk_text_buffer_get_iter_at_offset(b, &z, at + len);
        gtk_text_buffer_apply_tag(b, tag_for(r, &runs[i]), &a, &z);
        at += len;
    }
    g_string_free(all, TRUE);
    runway_text_view_set_programmatic(r->view, FALSE);
    r->updating = FALSE;
}

void rw_rich_configure(rw_rich *r, int editable, int wraps, double left, double top, double right, double bottom,
                       rw_color background, const rw_rich_run *typing, int takes_typing) {
    if (!r) return;
    GtkTextView *v = GTK_TEXT_VIEW(r->view);
    r->takes_typing = takes_typing != 0;
    r->wraps = wraps != 0;
    gtk_text_view_set_editable(v, editable != 0);
    gtk_text_view_set_cursor_visible(v, editable != 0);
    gtk_text_view_set_wrap_mode(v, wraps ? GTK_WRAP_WORD_CHAR : GTK_WRAP_NONE);
    r->insets[0] = left; r->insets[1] = top; r->insets[2] = right; r->insets[3] = bottom;
    gtk_text_view_set_left_margin(v, (int)lround(left));
    gtk_text_view_set_right_margin(v, (int)lround(right));
    gtk_text_view_set_top_margin(v, (int)lround(top));
    gtk_text_view_set_bottom_margin(v, (int)lround(bottom));
    char *bg = css_rgba(background);
    char *fg = typing && typing->has_color ? css_rgba(typing->color) : g_strdup("inherit");
    char *body = g_strdup_printf("background: %s; color: %s; font-family: \"%s\"; font-size: %.1fpx; caret-color: %s;", bg, fg,
                                 typing && typing->family && *typing->family ? typing->family : (rwg.ui_family ? rwg.ui_family : "Sans"),
                                 typing && typing->size > 0 ? typing->size : 13, fg);
    own_css(r->view, &r->css, &r->klass, ".%s, .%s > text { %s } /* %s */", body);
    g_free(body);
    g_free(bg);
    g_free(fg);
}

void rw_rich_set_runs(rw_rich *r, const rw_rich_run *runs, int count) {
    if (!r) return;
    GtkTextBuffer *b = rich_buffer(r);
    GtkTextIter sa, sb;
    gtk_text_buffer_get_selection_bounds(b, &sa, &sb);
    int s0 = gtk_text_iter_get_offset(&sa), s1 = gtk_text_iter_get_offset(&sb);
    replace_chars(r, 0, gtk_text_buffer_get_char_count(b), runs, count);
    int n = gtk_text_buffer_get_char_count(b);
    r->updating = TRUE;
    runway_text_view_set_programmatic(r->view, TRUE);
    gtk_text_buffer_get_iter_at_offset(b, &sa, s0 < n ? s0 : n);
    gtk_text_buffer_get_iter_at_offset(b, &sb, s1 < n ? s1 : n);
    gtk_text_buffer_select_range(b, &sb, &sa);
    runway_text_view_set_programmatic(r->view, FALSE);
    r->updating = FALSE;
}

void rw_rich_replace(rw_rich *r, int start, int end, const rw_rich_run *runs, int count) {
    if (!r) return;
    char *t = rich_text(r);
    int a = rwg_utf16_to_chars(t, start), z = rwg_utf16_to_chars(t, end);
    g_free(t);
    replace_chars(r, a, z, runs, count);
    // The caret after the inserted text, as RichEdit leaves it.
    int n = 0;
    for (int i = 0; i < count; i++) if (runs[i].text) n += (int)g_utf8_strlen(runs[i].text, -1);
    GtkTextIter it;
    gtk_text_buffer_get_iter_at_offset(rich_buffer(r), &it, a + n);
    r->updating = TRUE;
    runway_text_view_set_programmatic(r->view, TRUE);
    gtk_text_buffer_place_cursor(rich_buffer(r), &it);
    runway_text_view_set_programmatic(r->view, FALSE);
    r->updating = FALSE;
}

void rw_rich_get_selection(rw_rich *r, int *start, int *end) {
    *start = *end = 0;
    if (!r) return;
    GtkTextIter a, z;
    gtk_text_buffer_get_selection_bounds(rich_buffer(r), &a, &z);
    char *t = rich_text(r);
    *start = rwg_chars_to_utf16(t, gtk_text_iter_get_offset(&a));
    *end = rwg_chars_to_utf16(t, gtk_text_iter_get_offset(&z));
    g_free(t);
}

void rw_rich_set_selection(rw_rich *r, int start, int end) {
    if (!r) return;
    char *t = rich_text(r);
    int a = rwg_utf16_to_chars(t, start), z = rwg_utf16_to_chars(t, end);
    g_free(t);
    GtkTextIter ia, iz;
    gtk_text_buffer_get_iter_at_offset(rich_buffer(r), &ia, a);
    gtk_text_buffer_get_iter_at_offset(rich_buffer(r), &iz, z);
    r->updating = TRUE;
    runway_text_view_set_programmatic(r->view, TRUE);
    gtk_text_buffer_select_range(rich_buffer(r), &iz, &ia);
    runway_text_view_set_programmatic(r->view, FALSE);
    r->updating = FALSE;
}

void rw_rich_undo(rw_rich *r, int redo) {
    if (!r) return;
    if (redo) gtk_text_buffer_redo(rich_buffer(r)); else gtk_text_buffer_undo(rich_buffer(r));
}

double rw_rich_height(rw_rich *r, double width) {
    if (!r) return 0;
    if (gtk_widget_get_width(r->view) > 0 && fabs(gtk_widget_get_width(r->view) - width) < 1)
        return runway_text_view_content_height(r->view);
    // Not laid out at this width yet: Pango measures the text as it will be.
    char *t = rich_text(r);
    PangoLayout *l = gtk_widget_create_pango_layout(r->view, *t ? t : " ");
    pango_layout_set_width(l, r->wraps ? (int)lround(fmax(1, width - r->insets[0] - r->insets[2]) * PANGO_SCALE) : -1);
    pango_layout_set_wrap(l, PANGO_WRAP_WORD_CHAR);
    int w = 0, h = 0;
    pango_layout_get_pixel_size(l, &w, &h);
    g_object_unref(l);
    g_free(t);
    return ceil(h + r->insets[1] + r->insets[3]);
}

void rw_rich_char_rect(rw_rich *r, int index, double *x, double *y, double *width, double *height) {
    *x = *y = *width = *height = 0;
    if (!r) return;
    char *t = rich_text(r);
    int c = rwg_utf16_to_chars(t, index);
    g_free(t);
    double out[4] = {0};
    runway_text_view_char_rect(r->view, c, out);
    *x = out[0]; *y = out[1]; *width = out[2]; *height = out[3];
}

int rw_rich_char_index(rw_rich *r, double x, double y) {
    if (!r) return 0;
    GtkTextView *v = GTK_TEXT_VIEW(r->view);
    int bx = 0, by = 0;
    gtk_text_view_window_to_buffer_coords(v, GTK_TEXT_WINDOW_WIDGET, (int)lround(x), (int)lround(y), &bx, &by);
    GtkTextIter it;
    gtk_text_view_get_iter_at_location(v, &it, bx, by);
    char *t = rich_text(r);
    int u = rwg_chars_to_utf16(t, gtk_text_iter_get_offset(&it));
    g_free(t);
    return u;
}

void rw_rich_move(rw_rich *r, int step, int count, int extend) {
    if (r) runway_text_view_move(r->view, step, count, extend != 0);
}

void rw_rich_focus(rw_rich *r) { if (r) gtk_widget_grab_focus(r->view); }
int rw_rich_has_focus(rw_rich *r) { return r && gtk_widget_has_focus(r->view) ? 1 : 0; }

char *rw_rich_copy_text(rw_rich *r) {
    if (!r) return strdup("");
    char *t = rich_text(r);
    char *out = strdup(t);
    g_free(t);
    return out;
}

void rw_rich_set_layers(rw_rich *r, int below, int above) {
    if (r) runway_text_view_set_layers(r->view, below != 0, above != 0);
}

rw_window *rw_rich_surface(rw_rich *r) { return r ? r->surface : NULL; }

#endif
