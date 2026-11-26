// The app, its loop, top-level windows and popups, their input, cursors,
// drag and drop, screens and the menu bar, over GTK 4.
#if defined(__linux__) || defined(__FreeBSD__)
#include "rw_gtk.h"
#include <glib-unix.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/x11/gdkx.h>
#endif

RwGtk rwg;

int rwg_send_event(rw_event *ev) { return rwg.callback ? rwg.callback(ev) : 0; }

int rwg_send(int type, void *ctx) {
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = type;
    ev.ctx = ctx;
    return rwg_send_event(&ev);
}

unsigned rwg_mods(GdkModifierType s) {
    unsigned m = 0;
    if (s & GDK_SHIFT_MASK) m |= RW_MOD_SHIFT;
    if (s & GDK_CONTROL_MASK) m |= RW_MOD_CTRL;
    if (s & GDK_ALT_MASK) m |= RW_MOD_ALT;
    if (s & (GDK_SUPER_MASK | GDK_META_MASK)) m |= RW_MOD_WIN;
    if (s & GDK_LOCK_MASK) m |= 16;
    return m;
}

void rwg_wait(volatile int *done) {
    GMainContext *c = g_main_context_default();
    while (!*done) g_main_context_iteration(c, TRUE);
}

void rw_free(void *p) { free(p); }

// MARK: The loop

// libdispatch's main queue signals a file descriptor when it has work:
// draining it from the GLib loop keeps DispatchQueue.main and the main actor
// working (RunLoop timers are the Swift half's, through rw_wake_after).
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);

static gboolean drain_main_queue(gint fd, GIOCondition cond, gpointer data) {
    (void)fd; (void)cond; (void)data;
    _dispatch_main_queue_callback_4CF(NULL);
    return G_SOURCE_CONTINUE;
}

static void theme_changed(GObject *o, GParamSpec *p, gpointer d) {
    (void)o; (void)p; (void)d;
    rwg_send(RW_EV_THEME_CHANGED, NULL);
}

static gboolean family_exists(const char *family) {
    PangoFontMap *map = pango_cairo_font_map_get_default();
    PangoFontFamily **families = NULL;
    int n = 0;
    pango_font_map_list_families(map, &families, &n);
    gboolean found = FALSE;
    for (int i = 0; i < n && !found; i++) found = g_ascii_strcasecmp(pango_font_family_get_name(families[i]), family) == 0;
    g_free(families);
    return found;
}

#include "runway_gtk.h"
void rw_register_fonts(const char *const *paths, int count, const char *const *aliases, int alias_pairs) {
    runway_register_fonts(paths, count, aliases, alias_pairs);
}

int rw_init(rw_event_fn callback) {
    rwg.callback = callback;
    if (!gtk_init_check()) return 0;
    runway_tune_text_rendering();
    int fd = _dispatch_get_main_queue_handle_4CF();
    if (fd >= 0) g_unix_fd_add(fd, G_IO_IN, drain_main_queue, NULL);
    // The UI font: the closest to the Mac's that's installed, else GTK's.
    static const char *const ui[] = {"Inter", "SF Pro Text", "Cantarell", "Noto Sans", "Open Sans", "DejaVu Sans", NULL};
    for (int i = 0; ui[i]; i++) if (family_exists(ui[i])) { rwg.ui_family = g_strdup(ui[i]); break; }
    GtkSettings *s = gtk_settings_get_default();
    if (s) {
        g_signal_connect(s, "notify::gtk-application-prefer-dark-theme", G_CALLBACK(theme_changed), NULL);
        g_signal_connect(s, "notify::gtk-theme-name", G_CALLBACK(theme_changed), NULL);
    }
    return 1;
}

void rw_run(void) {
    if (!rwg.loop) rwg.loop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(rwg.loop);
}

void rw_quit(void) { if (rwg.loop) g_main_loop_quit(rwg.loop); }

static gboolean wake_cb(gpointer d) {
    (void)d;
    rwg_send(RW_EV_WAKE, NULL);
    return G_SOURCE_REMOVE;
}
void rw_wake(void) { g_idle_add_full(G_PRIORITY_DEFAULT, wake_cb, NULL, NULL); }

static guint wake_timer;
static gboolean wake_after_cb(gpointer d) {
    (void)d;
    wake_timer = 0;
    rwg_send(RW_EV_WAKE, NULL);
    return G_SOURCE_REMOVE;
}
void rw_wake_after(int ms) {
    if (wake_timer) g_source_remove(wake_timer);
    wake_timer = ms >= 0 ? g_timeout_add((guint)ms, wake_after_cb, NULL) : 0;
}

int rw_dark_mode(void) {
    GtkSettings *s = gtk_settings_get_default();
    if (!s) return 0;
    gboolean prefer = FALSE;
    char *theme = NULL;
    g_object_get(s, "gtk-application-prefer-dark-theme", &prefer, "gtk-theme-name", &theme, NULL);
    gboolean dark = prefer || (theme && (strstr(theme, "dark") || strstr(theme, "Dark")));
    g_free(theme);
    return dark ? 1 : 0;
}

int rw_font_available(const char *family) {
    static GHashTable *known;
    if (!known) known = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    gpointer v;
    if (g_hash_table_lookup_extended(known, family, NULL, &v)) return GPOINTER_TO_INT(v);
    int found = family_exists(family) ? 1 : 0;
    g_hash_table_insert(known, g_strdup(family), GINT_TO_POINTER(found));
    return found;
}

void rw_run_modal(volatile int *done) { rwg_wait(done); }

// MARK: Keys

int rwg_vk(guint k) {
    if (k >= GDK_KEY_a && k <= GDK_KEY_z) return (int)('A' + (k - GDK_KEY_a));
    if (k >= GDK_KEY_A && k <= GDK_KEY_Z) return (int)('A' + (k - GDK_KEY_A));
    if (k >= GDK_KEY_0 && k <= GDK_KEY_9) return (int)('0' + (k - GDK_KEY_0));
    if (k >= GDK_KEY_KP_0 && k <= GDK_KEY_KP_9) return 0x60 + (int)(k - GDK_KEY_KP_0);
    if (k >= GDK_KEY_F1 && k <= GDK_KEY_F24) return 0x70 + (int)(k - GDK_KEY_F1);
    switch (k) {
    case GDK_KEY_BackSpace: return 0x08;
    case GDK_KEY_Tab: case GDK_KEY_ISO_Left_Tab: return 0x09;
    case GDK_KEY_Return: case GDK_KEY_KP_Enter: return 0x0D;
    case GDK_KEY_Escape: return 0x1B;
    case GDK_KEY_space: return 0x20;
    case GDK_KEY_Page_Up: case GDK_KEY_KP_Page_Up: return 0x21;
    case GDK_KEY_Page_Down: case GDK_KEY_KP_Page_Down: return 0x22;
    case GDK_KEY_End: case GDK_KEY_KP_End: return 0x23;
    case GDK_KEY_Home: case GDK_KEY_KP_Home: return 0x24;
    case GDK_KEY_Left: case GDK_KEY_KP_Left: return 0x25;
    case GDK_KEY_Up: case GDK_KEY_KP_Up: return 0x26;
    case GDK_KEY_Right: case GDK_KEY_KP_Right: return 0x27;
    case GDK_KEY_Down: case GDK_KEY_KP_Down: return 0x28;
    case GDK_KEY_Insert: return 0x2D;
    case GDK_KEY_Delete: case GDK_KEY_KP_Delete: return 0x2E;
    case GDK_KEY_KP_Multiply: return 0x6A;
    case GDK_KEY_KP_Add: return 0x6B;
    case GDK_KEY_KP_Subtract: return 0x6D;
    case GDK_KEY_KP_Decimal: return 0x6E;
    case GDK_KEY_KP_Divide: return 0x6F;
    case GDK_KEY_Shift_L: case GDK_KEY_Shift_R: return 0x10;
    case GDK_KEY_Control_L: case GDK_KEY_Control_R: return 0x11;
    case GDK_KEY_Alt_L: case GDK_KEY_Alt_R: case GDK_KEY_ISO_Level3_Shift: return 0x12;
    case GDK_KEY_Caps_Lock: return 0x14;
    case GDK_KEY_Super_L: case GDK_KEY_Meta_L: return 0x5B;
    case GDK_KEY_Super_R: case GDK_KEY_Meta_R: return 0x5C;
    case GDK_KEY_semicolon: case GDK_KEY_colon: return 0xBA;
    case GDK_KEY_equal: case GDK_KEY_plus: return 0xBB;
    case GDK_KEY_comma: case GDK_KEY_less: return 0xBC;
    case GDK_KEY_minus: case GDK_KEY_underscore: return 0xBD;
    case GDK_KEY_period: case GDK_KEY_greater: return 0xBE;
    case GDK_KEY_slash: case GDK_KEY_question: return 0xBF;
    case GDK_KEY_grave: case GDK_KEY_asciitilde: return 0xC0;
    case GDK_KEY_bracketleft: case GDK_KEY_braceleft: return 0xDB;
    case GDK_KEY_backslash: case GDK_KEY_bar: return 0xDC;
    case GDK_KEY_bracketright: case GDK_KEY_braceright: return 0xDD;
    case GDK_KEY_apostrophe: case GDK_KEY_quotedbl: return 0xDE;
    }
    return 0;
}

int rw_key_char(int vk) {
    switch (vk) {
    case 0xBA: return ';';
    case 0xBB: return '=';
    case 0xBC: return ',';
    case 0xBD: return '-';
    case 0xBE: return '.';
    case 0xBF: return '/';
    case 0xC0: return '`';
    case 0xDB: return '[';
    case 0xDC: return '\\';
    case 0xDD: return ']';
    case 0xDE: return '\'';
    }
    return 0;
}

static gboolean is_modifier(guint k) {
    switch (k) {
    case GDK_KEY_Shift_L: case GDK_KEY_Shift_R: case GDK_KEY_Control_L: case GDK_KEY_Control_R: case GDK_KEY_Alt_L:
    case GDK_KEY_Alt_R: case GDK_KEY_Super_L: case GDK_KEY_Super_R: case GDK_KEY_Meta_L: case GDK_KEY_Meta_R:
    case GDK_KEY_Caps_Lock: case GDK_KEY_ISO_Level3_Shift:
        return TRUE;
    }
    return FALSE;
}

static unsigned modifier_bit(guint k) {
    switch (k) {
    case GDK_KEY_Shift_L: case GDK_KEY_Shift_R: return RW_MOD_SHIFT;
    case GDK_KEY_Control_L: case GDK_KEY_Control_R: return RW_MOD_CTRL;
    case GDK_KEY_Alt_L: case GDK_KEY_Alt_R: case GDK_KEY_ISO_Level3_Shift: return RW_MOD_ALT;
    case GDK_KEY_Super_L: case GDK_KEY_Super_R: case GDK_KEY_Meta_L: case GDK_KEY_Meta_R: return RW_MOD_WIN;
    }
    return 0;
}

gboolean rwg_native_text_focus(rw_window *w) {
    GtkWidget *f = w->window && GTK_IS_ROOT(w->window) ? gtk_root_get_focus(GTK_ROOT(w->window)) : NULL;
    if (w->popup && w->window) f = gtk_root_get_focus(GTK_ROOT(gtk_widget_get_root(w->window)));
    return f && (GTK_IS_TEXT(f) || GTK_IS_TEXT_VIEW(f)) && gtk_widget_is_sensitive(f);
}

/// Keys a focused text input lets the window have (as an EDIT forwards them).
static gboolean forwarded(guint keyval, GdkModifierType state, GtkWidget *focus) {
    gboolean ctrl = (state & GDK_CONTROL_MASK) != 0;
    gboolean multiline = GTK_IS_TEXT_VIEW(focus);
    if (keyval == GDK_KEY_Escape) return TRUE;
    if ((keyval == GDK_KEY_Tab || keyval == GDK_KEY_ISO_Left_Tab) && !multiline) return TRUE;
    if (keyval >= GDK_KEY_F1 && keyval <= GDK_KEY_F24) return TRUE;
    if (state & GDK_ALT_MASK) return TRUE;
    if (ctrl) {
        switch (keyval) {
        case GDK_KEY_a: case GDK_KEY_c: case GDK_KEY_v: case GDK_KEY_x: case GDK_KEY_z: case GDK_KEY_y:
        case GDK_KEY_A: case GDK_KEY_C: case GDK_KEY_V: case GDK_KEY_X: case GDK_KEY_Z: case GDK_KEY_Y:
        case GDK_KEY_Left: case GDK_KEY_Right: case GDK_KEY_Up: case GDK_KEY_Down: case GDK_KEY_Home: case GDK_KEY_End:
        case GDK_KEY_BackSpace: case GDK_KEY_Delete: case GDK_KEY_Insert:
            return FALSE;
        }
        return TRUE;
    }
    return FALSE;
}

static gboolean key_common(rw_window *w, guint keyval, guint keycode, GdkModifierType state, gboolean press, gboolean repeat) {
    gboolean text = rwg_native_text_focus(w);
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_RAW_KEY;
    ev.ctx = w->ctx;
    ev.key = rwg_vk(keyval);
    ev.mods = rwg_mods(state);
    if (!press) ev.flags |= RW_KEY_UP;
    if (text) ev.flags |= RW_KEY_NATIVE_TEXT;
    if (repeat) ev.flags |= RW_KEY_REPEAT;
    char chars[8] = {0};
    if (is_modifier(keyval)) {
        ev.flags |= RW_KEY_MODIFIER;
        unsigned bit = modifier_bit(keyval);
        if (press) ev.mods |= bit; else ev.mods &= ~bit;
    } else {
        gunichar u = gdk_keyval_to_unicode(keyval);
        if (u >= 32 && u != 127) g_unichar_to_utf8(u, chars);
    }
    const char *name = gdk_keyval_name(keyval);
    ev.text = chars;
    ev.text2 = name ? name : "";
    (void)keycode;
    if (rwg_send_event(&ev)) return TRUE;
    if (!press || is_modifier(keyval)) return FALSE;
    GtkWidget *focus = gtk_root_get_focus(GTK_ROOT(gtk_widget_get_root(w->area)));
    if (text && !forwarded(keyval, state, focus)) return FALSE;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_KEY_DOWN;
    ev.ctx = w->ctx;
    ev.key = rwg_vk(keyval);
    ev.mods = rwg_mods(state);
    if (ev.key == 0) return FALSE;
    if (rwg_send_event(&ev)) return TRUE;
    // A text input keeps Escape and Tab as an EDIT does.
    return text && (keyval == GDK_KEY_Escape || ((keyval == GDK_KEY_Tab || keyval == GDK_KEY_ISO_Left_Tab) && !GTK_IS_TEXT_VIEW(focus)));
}

typedef struct { unsigned keys[16]; int n; } HeldKeys;

static gboolean key_pressed(GtkEventControllerKey *c, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    rw_window *w = data;
    HeldKeys *held = g_object_get_data(G_OBJECT(c), "rw-held");
    gboolean repeat = FALSE;
    if (held) {
        for (int i = 0; i < held->n; i++) if (held->keys[i] == keycode) repeat = TRUE;
        if (!repeat && held->n < 16) held->keys[held->n++] = keycode;
    }
    return key_common(w, keyval, keycode, state, TRUE, repeat);
}

static void key_released(GtkEventControllerKey *c, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    HeldKeys *held = g_object_get_data(G_OBJECT(c), "rw-held");
    if (held) for (int i = 0; i < held->n; i++) if (held->keys[i] == keycode) { held->keys[i] = held->keys[--held->n]; break; }
    key_common(data, keyval, keycode, state, FALSE, FALSE);
}

// MARK: Pointer

static gboolean area_point(rw_window *w, GdkEvent *ev, double *x, double *y) {
    double ex, ey;
    if (!gdk_event_get_position(ev, &ex, &ey)) return FALSE;
    GtkNative *native = gtk_widget_get_native(w->area);
    if (!native) return FALSE;
    double sx = 0, sy = 0;
    gtk_native_get_surface_transform(native, &sx, &sy);
    graphene_point_t p = GRAPHENE_POINT_INIT((float)(ex - sx), (float)(ey - sy)), out;
    if (!gtk_widget_compute_point(GTK_WIDGET(native), w->area, &p, &out)) return FALSE;
    *x = out.x;
    *y = out.y;
    return TRUE;
}

static int button_index(guint b) { return b == 1 ? 0 : b == 3 ? 1 : b == 2 ? 2 : (int)b - 1; }

static gboolean area_event(GtkEventControllerLegacy *c, GdkEvent *e, gpointer data) {
    (void)c;
    rw_window *w = data;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.ctx = w->ctx;
    ev.mods = rwg_mods(gdk_event_get_modifier_state(e));
    GdkEventType type = gdk_event_get_event_type(e);
    w->last_time = gdk_event_get_time(e);
    double x = w->pointer_x, y = w->pointer_y;
    if (area_point(w, e, &x, &y)) { w->pointer_x = x; w->pointer_y = y; }
    ev.x = x;
    ev.y = y;
    switch (type) {
    case GDK_BUTTON_PRESS:
        ev.type = RW_EV_MOUSE_DOWN;
        ev.button = button_index(gdk_button_event_get_button(e));
        if (!w->popup) gtk_widget_grab_focus(w->area);
        break;
    case GDK_BUTTON_RELEASE:
        ev.type = RW_EV_MOUSE_UP;
        ev.button = button_index(gdk_button_event_get_button(e));
        break;
    case GDK_MOTION_NOTIFY:
    case GDK_ENTER_NOTIFY:
        ev.type = RW_EV_MOUSE_MOVE;
        break;
    case GDK_LEAVE_NOTIFY:
        ev.type = RW_EV_MOUSE_LEAVE;
        break;
    case GDK_SCROLL: {
        double dx = 0, dy = 0;
        gboolean lines = TRUE;
        switch (gdk_scroll_event_get_direction(e)) {
        case GDK_SCROLL_UP: dy = -1; break;
        case GDK_SCROLL_DOWN: dy = 1; break;
        case GDK_SCROLL_LEFT: dx = -1; break;
        case GDK_SCROLL_RIGHT: dx = 1; break;
        default:
            gdk_scroll_event_get_deltas(e, &dx, &dy);
            lines = gdk_scroll_event_get_unit(e) == GDK_SCROLL_UNIT_WHEEL;
            break;
        }
        double k = lines ? 48.0 : 1.0;   // three lines of about 16 DIPs a wheel step, as on Windows
        if ((ev.mods & RW_MOD_SHIFT) && dx == 0) { dx = dy; dy = 0; }
        ev.type = RW_EV_WHEEL;
        ev.dx = dx * k;
        ev.dy = dy * k;
        break;
    }
    default:
        return FALSE;
    }
    rwg_send_event(&ev);
    return TRUE;
}

// MARK: Windows

static void area_draw(GtkDrawingArea *a, cairo_t *cr, int width, int height, gpointer data) {
    (void)a; (void)width; (void)height;
    rw_window *w = data;
    rwg_begin_surface(w, cr);
    rwg_send(RW_EV_PAINT, w->ctx);
    rwg_end_surface(w);
}

static void area_resized(GtkDrawingArea *a, int width, int height, gpointer data) {
    (void)a;
    rw_window *w = data;
    w->width = width;
    w->height = height;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_RESIZE;
    ev.ctx = w->ctx;
    ev.dx = width;
    ev.dy = height;
    rwg_send_event(&ev);
}

static void scale_changed(GObject *o, GParamSpec *p, gpointer data) {
    (void)o; (void)p;
    rw_window *w = data;
    rwg_send(RW_EV_DPI_CHANGED, w->ctx);
}

static void active_changed(GObject *o, GParamSpec *p, gpointer data) {
    (void)p;
    rw_window *w = data;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_ACTIVATE;
    ev.ctx = w->ctx;
    ev.button = gtk_window_is_active(GTK_WINDOW(o)) ? 1 : 0;
    rwg_send_event(&ev);
}

static gboolean close_request(GtkWindow *win, gpointer data) {
    (void)win;
    rw_window *w = data;
    if (!w->closing) rwg_send(RW_EV_CLOSE_REQUEST, w->ctx);
    return !w->closing;   // the Swift half destroys the window when it agrees
}

static void destroyed(GtkWidget *wid, gpointer data) {
    (void)wid;
    rw_window *w = data;
    if (w->destroyed) return;
    w->destroyed = TRUE;
    if (w->timer) { g_source_remove(w->timer); w->timer = 0; }
    rwg_send(RW_EV_DESTROYED, w->ctx);
}

/// The drawing area, the overlay for native children and the input controllers.
static void build_content(rw_window *w) {
    w->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    w->overlay = gtk_overlay_new();
    gtk_widget_set_hexpand(w->overlay, TRUE);
    gtk_widget_set_vexpand(w->overlay, TRUE);
    w->area = gtk_drawing_area_new();
    gtk_widget_set_hexpand(w->area, TRUE);
    gtk_widget_set_vexpand(w->area, TRUE);
    gtk_widget_set_focusable(w->area, TRUE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(w->area), area_draw, w, NULL);
    g_signal_connect(w->area, "resize", G_CALLBACK(area_resized), w);
    g_signal_connect(w->area, "notify::scale-factor", G_CALLBACK(scale_changed), w);
    gtk_overlay_set_child(GTK_OVERLAY(w->overlay), w->area);
    gtk_box_append(GTK_BOX(w->box), w->overlay);

    GtkEventController *legacy = gtk_event_controller_legacy_new();
    g_signal_connect(legacy, "event", G_CALLBACK(area_event), w);
    gtk_widget_add_controller(w->area, legacy);
}

static void attach_keys(rw_window *w, GtkWidget *target) {
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_object_set_data_full(G_OBJECT(keys), "rw-held", g_new0(HeldKeys, 1), g_free);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), w);
    g_signal_connect(keys, "key-released", G_CALLBACK(key_released), w);
    gtk_widget_add_controller(target, keys);
}

rw_window *rw_window_create(const char *title, double width, double height, int resizable, rw_window *parent, int modal, void *ctx) {
    rw_window *w = g_new0(rw_window, 1);
    w->ctx = ctx;
    w->parent = parent;
    w->modal = modal != 0;
    w->alpha = 1;
    w->width = width;
    w->height = height;
    w->window = gtk_window_new();
    g_object_ref_sink(w->window);
    gtk_window_set_title(GTK_WINDOW(w->window), title ? title : "");
    gtk_window_set_default_size(GTK_WINDOW(w->window), (int)lround(width), (int)lround(height));
    gtk_window_set_resizable(GTK_WINDOW(w->window), resizable != 0);
    if (parent && parent->window && GTK_IS_WINDOW(parent->window)) gtk_window_set_transient_for(GTK_WINDOW(w->window), GTK_WINDOW(parent->window));
    if (modal && parent) gtk_window_set_modal(GTK_WINDOW(w->window), TRUE);
    build_content(w);
    gtk_window_set_child(GTK_WINDOW(w->window), w->box);
    attach_keys(w, w->window);
    g_signal_connect(w->window, "notify::is-active", G_CALLBACK(active_changed), w);
    g_signal_connect(w->window, "close-request", G_CALLBACK(close_request), w);
    g_signal_connect(w->window, "destroy", G_CALLBACK(destroyed), w);
    return w;
}

void rw_window_destroy(rw_window *w) {
    if (!w || w->closing) return;
    w->closing = TRUE;
    if (w->popup) {
        gtk_popover_popdown(GTK_POPOVER(w->window));
        if (!w->destroyed) { w->destroyed = TRUE; rwg_send(RW_EV_DESTROYED, w->ctx); }
        gtk_widget_unparent(w->window);
    } else {
        gtk_window_destroy(GTK_WINDOW(w->window));
    }
    // The struct lives on (the Swift half may still hold it); widgets go.
}

void rw_window_set_title(rw_window *w, const char *title) {
    if (w && !w->popup) gtk_window_set_title(GTK_WINDOW(w->window), title ? title : "");
}

void rw_window_set_content_size(rw_window *w, double width, double height) {
    if (!w) return;
    w->width = width;
    w->height = height;
    if (w->popup) { gtk_widget_set_size_request(w->area, (int)lround(width), (int)lround(height)); return; }
    int extra = 0;
    if (w->menubar) {
        int min = 0, nat = 0;
        gtk_widget_measure(w->menubar, GTK_ORIENTATION_VERTICAL, -1, &min, &nat, NULL, NULL);
        extra = nat;
    }
    gtk_window_set_default_size(GTK_WINDOW(w->window), (int)lround(width), (int)lround(height) + extra);
}

void rw_window_get_content_size(rw_window *w, double *width, double *height) {
    int a = gtk_widget_get_width(w->area), b = gtk_widget_get_height(w->area);
    *width = a > 0 ? a : w->width;
    *height = b > 0 ? b : w->height;
}

void rw_window_set_min_size(rw_window *w, double width, double height) {
    if (w && !w->popup) gtk_widget_set_size_request(w->area, (int)lround(width), (int)lround(height));
}

void rw_window_set_resizable(rw_window *w, int resizable) {
    if (w && !w->popup) gtk_window_set_resizable(GTK_WINDOW(w->window), resizable != 0);
}

void rw_window_show(rw_window *w) {
    if (!w) return;
    if (w->popup) { gtk_popover_popup(GTK_POPOVER(w->window)); return; }
    gtk_window_present(GTK_WINDOW(w->window));
    if (w->has_pending_position) {
        w->has_pending_position = FALSE;
        rw_window_set_position(w, w->pending_x, w->pending_y);
    }
}

void rw_window_show_inactive(rw_window *w) {
    if (!w) return;
    if (w->popup) gtk_popover_popup(GTK_POPOVER(w->window));
    else gtk_widget_set_visible(w->window, TRUE);
}

void rw_window_center(rw_window *w) { (void)w; }   // the desktop places windows

void rw_window_set_position(rw_window *w, double x, double y) {
    if (!w || w->popup) return;
#ifdef GDK_WINDOWING_X11
    // X11 lets a client place its windows (Wayland doesn't: there the
    // compositor does, and this does nothing).
    GtkNative *native = gtk_widget_get_native(w->window);
    GdkSurface *surface = native ? gtk_native_get_surface(native) : NULL;
    if (surface && GDK_IS_X11_SURFACE(surface)) {
        int scale = gdk_surface_get_scale_factor(surface);
        XMoveWindow(GDK_SURFACE_XDISPLAY(surface), GDK_SURFACE_XID(surface), (int)lround(x * scale), (int)lround(y * scale));
        return;
    }
    // Not yet realised: placed once it is.
    w->pending_x = x;
    w->pending_y = y;
    w->has_pending_position = TRUE;
#else
    (void)x; (void)y;
#endif
}

void rw_window_invalidate(rw_window *w) { if (w && w->area && !w->cr) gtk_widget_queue_draw(w->area); }
void rw_window_set_dark(rw_window *w, int dark) { (void)w; (void)dark; }

static const char *cursor_name(int c) {
    switch (c) {
    case RW_CURSOR_HAND: return "pointer";
    case RW_CURSOR_IBEAM: return "text";
    case RW_CURSOR_CROSS: return "crosshair";
    case RW_CURSOR_SIZEWE: return "ew-resize";
    case RW_CURSOR_SIZENS: return "ns-resize";
    case RW_CURSOR_SIZEALL: return "move";
    case RW_CURSOR_NO: return "not-allowed";
    case RW_CURSOR_WAIT: return "wait";
    case RW_CURSOR_HELP: return "help";
    case RW_CURSOR_SIZENWSE: return "nwse-resize";
    case RW_CURSOR_SIZENESW: return "nesw-resize";
    case RW_CURSOR_PROGRESS: return "progress";
    case RW_CURSOR_HIDDEN: return "none";
    }
    return "default";
}

void rw_window_set_cursor(rw_window *w, int cursor) {
    if (!w || !w->area) return;
    const char *name = cursor_name(cursor);
    const char *now = w->cursor ? gdk_cursor_get_name(w->cursor) : NULL;
    if (now && strcmp(now, name) == 0) return;
    if (w->cursor) g_object_unref(w->cursor);
    w->cursor = gdk_cursor_new_from_name(name, NULL);
    gtk_widget_set_cursor(w->area, w->cursor);
}

void rw_window_set_cursor_image(rw_window *w, int width, int height, const uint8_t *rgba, int hot_x, int hot_y) {
    if (!w || !rgba || width <= 0 || height <= 0) return;
    GBytes *bytes = g_bytes_new(rgba, (gsize)width * height * 4);
    GdkTexture *t = gdk_memory_texture_new(width, height, GDK_MEMORY_R8G8B8A8, bytes, (gsize)width * 4);
    g_bytes_unref(bytes);
    if (w->cursor) g_object_unref(w->cursor);
    w->cursor = gdk_cursor_new_from_texture(t, hot_x, hot_y, NULL);
    g_object_unref(t);
    gtk_widget_set_cursor(w->area, w->cursor);
}

void rw_window_capture(rw_window *w, int on) { (void)w; (void)on; }   // GTK grabs the pointer while a button is down

static gboolean timer_cb(gpointer data) {
    rw_window *w = data;
    rwg_send(RW_EV_TIMER, w->ctx);
    return G_SOURCE_CONTINUE;
}

void rw_window_set_timer(rw_window *w, int ms) {
    if (!w) return;
    if (ms > 0) {
        if (!w->timer) w->timer = g_timeout_add((guint)ms, timer_cb, w);
    } else if (w->timer) {
        g_source_remove(w->timer);
        w->timer = 0;
    }
}

double rw_window_scale(rw_window *w) { return w && w->area ? gtk_widget_get_scale_factor(w->area) : 1; }
int rw_window_backdrop(rw_window *w) { (void)w; return 0; }
void rw_window_focus(rw_window *w) { if (w && w->area) gtk_widget_grab_focus(w->area); }

void rw_window_set_decorated(rw_window *w, int decorated) {
    if (w && !w->popup) gtk_window_set_decorated(GTK_WINDOW(w->window), decorated != 0);
}

void rw_window_begin_move(rw_window *w) {
    if (!w || w->popup) return;
    GtkNative *native = gtk_widget_get_native(w->area);
    GdkSurface *surface = native ? gtk_native_get_surface(native) : NULL;
    if (!surface || !GDK_IS_TOPLEVEL(surface)) return;
    graphene_point_t p = GRAPHENE_POINT_INIT((float)w->pointer_x, (float)w->pointer_y), out;
    if (!gtk_widget_compute_point(w->area, GTK_WIDGET(native), &p, &out)) return;
    double sx = 0, sy = 0;
    gtk_native_get_surface_transform(native, &sx, &sy);
    GdkSeat *seat = gdk_display_get_default_seat(gdk_display_get_default());
    GdkDevice *pointer = seat ? gdk_seat_get_pointer(seat) : NULL;
    gdk_toplevel_begin_move(GDK_TOPLEVEL(surface), pointer, 1, out.x + sx, out.y + sy, w->last_time);
}

void rw_window_activate(rw_window *w) { if (w && !w->popup) gtk_window_present(GTK_WINDOW(w->window)); }

int rw_window_is_active(rw_window *w) {
    if (!w) return 0;
    if (w->popup) return gtk_widget_get_visible(w->window) ? 1 : 0;
    return gtk_window_is_active(GTK_WINDOW(w->window)) ? 1 : 0;
}

// MARK: Popups

static void popup_closed(GtkPopover *p, gpointer data) {
    (void)p;
    rw_window *w = data;
    if (w->closing) return;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_ACTIVATE;
    ev.ctx = w->ctx;
    ev.button = 0;
    rwg_send_event(&ev);
}

rw_window *rw_popup_create(rw_window *owner, void *ctx) {
    if (!owner || !owner->area) return NULL;
    rw_window *w = g_new0(rw_window, 1);
    w->ctx = ctx;
    w->parent = owner;
    w->popup = TRUE;
    w->alpha = 1;
    w->window = gtk_popover_new();
    gtk_popover_set_has_arrow(GTK_POPOVER(w->window), FALSE);
    gtk_popover_set_autohide(GTK_POPOVER(w->window), TRUE);
    gtk_popover_set_position(GTK_POPOVER(w->window), GTK_POS_BOTTOM);
    gtk_widget_add_css_class(w->window, "rw-popup");
    build_content(w);
    gtk_popover_set_child(GTK_POPOVER(w->window), w->box);
    gtk_widget_set_parent(w->window, owner->area);
    attach_keys(w, w->window);
    g_signal_connect(w->window, "closed", G_CALLBACK(popup_closed), w);
    static gboolean styled = FALSE;
    if (!styled) {
        // The drawn content fills the popover edge to edge.
        GtkCssProvider *css = gtk_css_provider_new();
        gtk_css_provider_load_from_string(css, "popover.rw-popup > contents { padding: 0; border-radius: 8px; }");
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        g_object_unref(css);
        styled = TRUE;
    }
    return w;
}

void rw_popup_place(rw_window *w, double x, double y, double width, double height) {
    if (!w || !w->popup) return;
    w->width = width;
    w->height = height;
    w->popup_x = x;
    w->popup_y = y;
    gtk_widget_set_size_request(w->area, (int)lround(width), (int)lround(height));
    GdkRectangle r = {(int)lround(x), (int)lround(y) - 1, (int)lround(width), 1};
    gtk_popover_set_pointing_to(GTK_POPOVER(w->window), &r);
}

void rw_window_offset_in(rw_window *w, rw_window *other, double *x, double *y) {
    *x = 0; *y = 0;
    if (!w || !other) return;
    graphene_point_t p = GRAPHENE_POINT_INIT(0, 0), out;
    if (gtk_widget_compute_point(w->area, other->area, &p, &out)) { *x = out.x; *y = out.y; }
    else if (w->popup) { *x = w->popup_x; *y = w->popup_y; }
}

// MARK: Drag and drop

static int drop_ops(rw_window *w, int kind, double x, double y, const GValue *value) {
    char *files = NULL, *text = NULL;
    if (value && G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) {
        GString *s = g_string_new(NULL);
        for (GSList *l = gdk_file_list_get_files(g_value_get_boxed(value)); l; l = l->next) {
            char *p = g_file_get_path(l->data);
            if (!p) continue;
            if (s->len) g_string_append_c(s, '\n');
            g_string_append(s, p);
            g_free(p);
        }
        files = g_string_free(s, FALSE);
    } else if (value && G_VALUE_HOLDS_STRING(value)) {
        text = g_value_dup_string(value);
    }
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_DRAG;
    ev.ctx = w->ctx;
    ev.button = kind;
    ev.x = x;
    ev.y = y;
    ev.text = files ? files : "";
    ev.text2 = text ? text : "";
    int ops = rwg_send_event(&ev);
    g_free(files);
    g_free(text);
    return ops;
}

static GdkDragAction to_action(int ops) {
    if (ops & RW_DROP_COPY) return GDK_ACTION_COPY;
    if (ops & RW_DROP_MOVE) return GDK_ACTION_MOVE;
    if (ops & RW_DROP_LINK) return GDK_ACTION_LINK;
    return 0;
}

static GdkDragAction drop_enter(GtkDropTarget *t, double x, double y, gpointer data) {
    return to_action(drop_ops(data, 0, x, y, gtk_drop_target_get_value(t)));
}
static GdkDragAction drop_motion(GtkDropTarget *t, double x, double y, gpointer data) {
    return to_action(drop_ops(data, 1, x, y, gtk_drop_target_get_value(t)));
}
static void drop_leave(GtkDropTarget *t, gpointer data) { (void)t; drop_ops(data, 2, 0, 0, NULL); }
static gboolean drop_drop(GtkDropTarget *t, const GValue *value, double x, double y, gpointer data) {
    (void)t;
    return drop_ops(data, 3, x, y, value) != 0;
}

void rw_window_accept_drops(rw_window *w, int on) {
    if (!w || !w->area) return;
    if (on && !w->drop) {
        w->drop = gtk_drop_target_new(G_TYPE_INVALID, GDK_ACTION_COPY | GDK_ACTION_MOVE | GDK_ACTION_LINK);
        GType types[2] = {GDK_TYPE_FILE_LIST, G_TYPE_STRING};
        gtk_drop_target_set_gtypes(w->drop, types, 2);
        gtk_drop_target_set_preload(w->drop, TRUE);
        g_signal_connect(w->drop, "enter", G_CALLBACK(drop_enter), w);
        g_signal_connect(w->drop, "motion", G_CALLBACK(drop_motion), w);
        g_signal_connect(w->drop, "leave", G_CALLBACK(drop_leave), w);
        g_signal_connect(w->drop, "drop", G_CALLBACK(drop_drop), w);
        gtk_widget_add_controller(w->area, GTK_EVENT_CONTROLLER(w->drop));
    } else if (!on && w->drop) {
        gtk_widget_remove_controller(w->area, GTK_EVENT_CONTROLLER(w->drop));
        w->drop = NULL;
    }
}

// MARK: Screens

int rw_screens(double *out, int max) {
    GListModel *monitors = gdk_display_get_monitors(gdk_display_get_default());
    int n = (int)g_list_model_get_n_items(monitors), count = 0;
    for (int i = 0; i < n && count < max; i++) {
        GdkMonitor *m = g_list_model_get_item(monitors, (guint)i);
        GdkRectangle r, work;
        gdk_monitor_get_geometry(m, &r);
        work = r;
#ifdef GDK_WINDOWING_X11
        if (GDK_IS_X11_MONITOR(m)) gdk_x11_monitor_get_workarea(m, &work);
#endif
        double *o = out + count * 9;
        o[0] = r.x; o[1] = r.y; o[2] = r.width; o[3] = r.height;
        o[4] = work.x; o[5] = work.y; o[6] = work.width; o[7] = work.height;
        o[8] = gdk_monitor_get_scale_factor(m);
        count++;
        g_object_unref(m);
    }
    return count;
}

// MARK: Menus

struct rw_menu {
    GMenu *model;
    GMenu *section;              // where items go (separators start new sections)
    struct rw_menu *root;
    GSimpleActionGroup *group;   // the root's
    GPtrArray *children;
    int chosen;
    rw_window *menubar_of;       // the window whose menu bar this is
};

static rw_menu *menu_new(rw_menu *root) {
    rw_menu *m = g_new0(rw_menu, 1);
    m->model = g_menu_new();
    m->section = g_menu_new();
    g_menu_append_section(m->model, NULL, G_MENU_MODEL(m->section));
    m->root = root ? root : m;
    if (!root) m->group = g_simple_action_group_new();
    m->children = g_ptr_array_new();
    return m;
}

rw_menu *rw_menu_create(void) { return menu_new(NULL); }

rw_menu *rw_menubar_create(void) {
    // A menu bar's items are its submenus, side by side: no sections.
    rw_menu *m = g_new0(rw_menu, 1);
    m->model = g_menu_new();
    m->section = m->model;
    g_object_ref(m->section);
    m->root = m;
    m->group = g_simple_action_group_new();
    m->children = g_ptr_array_new();
    return m;
}

/// "Ctrl+Shift+Z" (what the Swift half writes after a tab) → "<Control><Shift>z".
static char *accel_from_text(const char *t) {
    GString *s = g_string_new(NULL);
    char **parts = g_strsplit(t, "+", -1);
    int n = (int)g_strv_length(parts);
    for (int i = 0; i < n; i++) {
        const char *p = parts[i];
        if (i < n - 1) {
            if (!strcmp(p, "Ctrl")) g_string_append(s, "<Control>");
            else if (!strcmp(p, "Shift")) g_string_append(s, "<Shift>");
            else if (!strcmp(p, "Alt")) g_string_append(s, "<Alt>");
            else if (!strcmp(p, "Win")) g_string_append(s, "<Super>");
            continue;
        }
        // The key: one character, or a name.
        if (*p == 0 && i > 0) { g_string_append(s, "plus"); continue; }
        static const char *const names[][2] = {{"Enter", "Return"}, {"Esc", "Escape"}, {"Backspace", "BackSpace"}, {"Del", "Delete"},
            {",", "comma"}, {".", "period"}, {"/", "slash"}, {";", "semicolon"}, {"[", "bracketleft"}, {"]", "bracketright"},
            {"-", "minus"}, {"=", "equal"}, {"Space", "space"}, {"\\", "backslash"}, {"'", "apostrophe"}, {"`", "grave"},
            {"PgUp", "Page_Up"}, {"PgDn", "Page_Down"}};
        const char *k = p;
        for (size_t j = 0; j < sizeof names / sizeof names[0]; j++) if (!strcmp(p, names[j][0])) k = names[j][1];
        if (strlen(k) == 1) { char c[2] = {(char)g_ascii_tolower(k[0]), 0}; g_string_append(s, c); } else g_string_append(s, k);
    }
    g_strfreev(parts);
    return g_string_free(s, FALSE);
}

static void item_activated(GSimpleAction *a, GVariant *param, gpointer data) {
    (void)param;
    rw_menu *root = data;
    int id = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(a), "rw-id"));
    if (root->menubar_of) {
        rw_event ev;
        memset(&ev, 0, sizeof ev);
        ev.type = RW_EV_MENU_COMMAND;
        ev.ctx = root->menubar_of->ctx;
        ev.key = id;
        rwg_send_event(&ev);
    } else {
        root->chosen = id;
    }
}

void rw_menu_add(rw_menu *m, const char *title, int id, int enabled, int checked) {
    char name[32];
    snprintf(name, sizeof name, "i%d", id);
    GSimpleAction *a = g_simple_action_new_stateful(name, NULL, g_variant_new_boolean(checked != 0));
    g_object_set_data(G_OBJECT(a), "rw-id", GINT_TO_POINTER(id));
    g_simple_action_set_enabled(a, enabled != 0);
    g_signal_connect(a, "activate", G_CALLBACK(item_activated), m->root);
    g_action_map_add_action(G_ACTION_MAP(m->root->group), G_ACTION(a));
    g_object_unref(a);
    // "Title\tCtrl+N": the label, then the shortcut shown beside it.
    const char *tab = title ? strchr(title, '\t') : NULL;
    char *label = tab ? g_strndup(title, (gsize)(tab - title)) : g_strdup(title ? title : "");
    // Mnemonic underscores show literally.
    GString *escaped = g_string_new(NULL);
    for (const char *c = label; *c; c++) { if (*c == '_') g_string_append_c(escaped, '_'); g_string_append_c(escaped, *c); }
    char detailed[40];
    snprintf(detailed, sizeof detailed, "rwm.%s", name);
    GMenuItem *item = g_menu_item_new(escaped->str, detailed);
    if (tab) {
        char *accel = accel_from_text(tab + 1);
        g_menu_item_set_attribute(item, "accel", "s", accel);
        g_free(accel);
    }
    g_menu_append_item(m->section, item);
    g_object_unref(item);
    g_string_free(escaped, TRUE);
    g_free(label);
}

void rw_menu_add_separator(rw_menu *m) {
    if (m->section == m->model) return;
    GMenu *next = g_menu_new();
    g_menu_append_section(m->model, NULL, G_MENU_MODEL(next));
    g_object_unref(m->section);
    m->section = next;
}

rw_menu *rw_menu_add_submenu(rw_menu *m, const char *title, int enabled) {
    (void)enabled;
    rw_menu *child = menu_new(m->root);
    GString *escaped = g_string_new(NULL);
    for (const char *c = title ? title : ""; *c; c++) { if (*c == '_') g_string_append_c(escaped, '_'); g_string_append_c(escaped, *c); }
    g_menu_append_submenu(m->section, escaped->str, G_MENU_MODEL(child->model));
    g_string_free(escaped, TRUE);
    g_ptr_array_add(m->children, child);
    return child;
}

static void popup_menu_closed(GtkPopover *p, gpointer data) {
    (void)p;
    volatile int *done = data;
    *done = 1;
}

static gboolean quit_soon(gpointer data) {
    volatile int *done = data;
    *done = 2;
    return G_SOURCE_REMOVE;
}

int rw_menu_popup(rw_menu *m, rw_window *w, double x, double y) {
    if (!m || !w || !w->area) return 0;
    m->root->chosen = 0;
    GtkWidget *pop = gtk_popover_menu_new_from_model(G_MENU_MODEL(m->model));
    gtk_widget_insert_action_group(pop, "rwm", G_ACTION_GROUP(m->root->group));
    gtk_widget_set_parent(pop, w->area);
    gtk_popover_set_has_arrow(GTK_POPOVER(pop), FALSE);
    gtk_popover_set_position(GTK_POPOVER(pop), GTK_POS_BOTTOM);
    gtk_widget_set_halign(pop, GTK_ALIGN_START);
    GdkRectangle r = {(int)lround(x), (int)lround(y), 1, 1};
    gtk_popover_set_pointing_to(GTK_POPOVER(pop), &r);
    volatile int done = 0;
    g_signal_connect(pop, "closed", G_CALLBACK(popup_menu_closed), (gpointer)&done);
    gtk_popover_popup(GTK_POPOVER(pop));
    while (!done) g_main_context_iteration(NULL, TRUE);
    // The chosen item's action runs just after the menu closes.
    g_idle_add(quit_soon, (gpointer)&done);
    while (done != 2) g_main_context_iteration(NULL, TRUE);
    g_signal_handlers_disconnect_by_data(pop, (gpointer)&done);
    gtk_widget_unparent(pop);
    return m->root->chosen;
}

static void free_menu(rw_menu *m, gboolean models) {
    for (guint i = 0; i < m->children->len; i++) free_menu(g_ptr_array_index(m->children, i), models);
    g_ptr_array_free(m->children, TRUE);
    if (m->section && m->section != m->model) g_object_unref(m->section);
    if (m->section == m->model && m->section) g_object_unref(m->section);
    if (models) g_object_unref(m->model);
    if (m->root == m && m->group && models) g_object_unref(m->group);
    g_free(m);
}

void rw_menu_free(rw_menu *m) { if (m) free_menu(m, TRUE); }

static void menubar_pressed(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    (void)g; (void)n; (void)x; (void)y;
    rw_window *w = data;
    rwg_send(RW_EV_MENU_OPENING, w->ctx);
}

void rw_window_set_menubar(rw_window *w, rw_menu *m) {
    if (!w || w->popup) return;
    if (w->menubar) {
        gtk_box_remove(GTK_BOX(w->box), w->menubar);
        w->menubar = NULL;
    }
    if (w->menu_actions) {
        gtk_widget_insert_action_group(w->window, "rwm", NULL);
        g_object_unref(w->menu_actions);
        w->menu_actions = NULL;
    }
    if (!m) return;
    m->menubar_of = w;
    w->menu_actions = g_object_ref(m->group);
    gtk_widget_insert_action_group(w->window, "rwm", G_ACTION_GROUP(w->menu_actions));
    w->menubar = gtk_popover_menu_bar_new_from_model(G_MENU_MODEL(m->model));
    GtkGesture *press = gtk_gesture_click_new();
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(press), GTK_PHASE_CAPTURE);
    g_signal_connect(press, "pressed", G_CALLBACK(menubar_pressed), w);
    gtk_widget_add_controller(w->menubar, GTK_EVENT_CONTROLLER(press));
    gtk_box_prepend(GTK_BOX(w->box), w->menubar);
    // The bar keeps its model and actions; the wrappers can go. The root
    // stays alive (actions report through it) until the bar is replaced.
    g_object_set_data_full(G_OBJECT(w->menubar), "rw-menu", m, (GDestroyNotify)rw_menu_free);
}

void rw_window_menu_item_state(rw_window *w, int id, int enabled, int checked) {
    if (!w || !w->menu_actions) return;
    char name[32];
    snprintf(name, sizeof name, "i%d", id);
    GAction *a = g_action_map_lookup_action(G_ACTION_MAP(w->menu_actions), name);
    if (!a) return;
    g_simple_action_set_enabled(G_SIMPLE_ACTION(a), enabled != 0);
    g_simple_action_set_state(G_SIMPLE_ACTION(a), g_variant_new_boolean(checked != 0));
}

#endif
