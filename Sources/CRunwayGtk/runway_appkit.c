#if defined(__linux__) || defined(__FreeBSD__)
#include "runway_appkit.h"
#include <string.h>

typedef struct {
    RunwayAppKitEventFunc fn;
    void *data;
    GDestroyNotify notify;
    GtkWidget *content;
    unsigned down_keys[16];
    int n_down;
} EventTarget;

static void event_target_free(gpointer p, GClosure *c) {
    (void)c;
    EventTarget *t = p;
    if (t->notify) t->notify(t->data);
    g_free(t);
}

static unsigned mods(GdkModifierType s) {
    unsigned m = 0;
    if (s & GDK_SHIFT_MASK) m |= 1;
    if (s & GDK_CONTROL_MASK) m |= 2;
    if (s & GDK_ALT_MASK) m |= 4;
    if (s & (GDK_SUPER_MASK | GDK_META_MASK)) m |= 8;
    if (s & GDK_LOCK_MASK) m |= 16;
    return m;
}

/// Event position in `content` coordinates.
static gboolean content_point(GtkWidget *content, GdkEvent *ev, double *x, double *y) {
    double ex, ey;
    if (!gdk_event_get_position(ev, &ex, &ey)) return FALSE;
    GtkNative *native = gtk_widget_get_native(content);
    if (!native) return FALSE;
    double sx = 0, sy = 0;
    gtk_native_get_surface_transform(native, &sx, &sy);
    graphene_point_t p = GRAPHENE_POINT_INIT((float)(ex - sx), (float)(ey - sy)), out;
    if (!gtk_widget_compute_point(GTK_WIDGET(native), content, &p, &out)) return FALSE;
    *x = out.x;
    *y = out.y;
    return TRUE;
}

static gboolean legacy_event(GtkEventControllerLegacy *c, GdkEvent *ev, gpointer data) {
    (void)c;
    EventTarget *t = data;
    RunwayAppKitEvent e;
    memset(&e, 0, sizeof e);
    GdkEventType type = gdk_event_get_event_type(ev);
    e.modifiers = mods(gdk_event_get_modifier_state(ev));
    e.time = gdk_event_get_time(ev) / 1000.0;
    content_point(t->content, ev, &e.x, &e.y);
    switch (type) {
    case GDK_BUTTON_PRESS:
    case GDK_BUTTON_RELEASE: {
        guint b = gdk_button_event_get_button(ev);
        e.kind = type == GDK_BUTTON_PRESS ? RUNWAY_EV_DOWN : RUNWAY_EV_UP;
        e.button = b == 1 ? 0 : b == 3 ? 1 : b == 2 ? 2 : (int)b - 1;
        break;
    }
    case GDK_MOTION_NOTIFY: e.kind = RUNWAY_EV_MOTION; break;
    case GDK_ENTER_NOTIFY: e.kind = RUNWAY_EV_ENTER; break;
    case GDK_LEAVE_NOTIFY: e.kind = RUNWAY_EV_LEAVE; break;
    case GDK_SCROLL: {
        e.kind = RUNWAY_EV_SCROLL;
        double dx = 0, dy = 0;
        GdkScrollDirection dir = gdk_scroll_event_get_direction(ev);
        switch (dir) {
        case GDK_SCROLL_UP: dy = -1; break;
        case GDK_SCROLL_DOWN: dy = 1; break;
        case GDK_SCROLL_LEFT: dx = -1; break;
        case GDK_SCROLL_RIGHT: dx = 1; break;
        default: gdk_scroll_event_get_deltas(ev, &dx, &dy); break;
        }
        e.precise = gdk_scroll_event_get_unit(ev) == GDK_SCROLL_UNIT_SURFACE;
        // AppKit: positive deltaY when the wheel turns away from the user.
        e.dx = -dx;
        e.dy = -dy;
        break;
    }
    default: return FALSE;
    }
    return t->fn(&e, t->data);
}

static gboolean is_modifier(guint keyval) {
    switch (keyval) {
    case GDK_KEY_Shift_L: case GDK_KEY_Shift_R: case GDK_KEY_Control_L: case GDK_KEY_Control_R:
    case GDK_KEY_Alt_L: case GDK_KEY_Alt_R: case GDK_KEY_Super_L: case GDK_KEY_Super_R:
    case GDK_KEY_Meta_L: case GDK_KEY_Meta_R: case GDK_KEY_Caps_Lock: case GDK_KEY_ISO_Level3_Shift:
        return TRUE;
    default: return FALSE;
    }
}

static unsigned modifier_bit(guint keyval) {
    switch (keyval) {
    case GDK_KEY_Shift_L: case GDK_KEY_Shift_R: return 1;
    case GDK_KEY_Control_L: case GDK_KEY_Control_R: return 2;
    case GDK_KEY_Alt_L: case GDK_KEY_Alt_R: case GDK_KEY_ISO_Level3_Shift: return 4;
    case GDK_KEY_Super_L: case GDK_KEY_Super_R: case GDK_KEY_Meta_L: case GDK_KEY_Meta_R: return 8;
    case GDK_KEY_Caps_Lock: return 16;
    default: return 0;
    }
}

static gboolean key_common(EventTarget *t, guint keyval, guint keycode, GdkModifierType state, gboolean press) {
    RunwayAppKitEvent e;
    memset(&e, 0, sizeof e);
    e.modifiers = mods(state);
    e.time = g_get_monotonic_time() / 1e6;
    e.keyval = keyval;
    e.keycode = keycode;
    if (is_modifier(keyval)) {
        e.kind = RUNWAY_EV_FLAGS;
        if (press) e.modifiers |= modifier_bit(keyval); else e.modifiers &= ~modifier_bit(keyval);
        const char *n = gdk_keyval_name(keyval);
        e.keyname = n ? n : "";
        e.chars = "";
        t->fn(&e, t->data);
        return FALSE;
    }
    e.kind = press ? RUNWAY_EV_KEY_DOWN : RUNWAY_EV_KEY_UP;
    // Repeats: a press for a key that's already down.
    int found = -1;
    for (int i = 0; i < t->n_down; i++) if (t->down_keys[i] == keycode) found = i;
    if (press) {
        if (found >= 0) e.is_repeat = 1; else if (t->n_down < 16) t->down_keys[t->n_down++] = keycode;
    } else if (found >= 0) {
        t->down_keys[found] = t->down_keys[--t->n_down];
    }
    const char *n = gdk_keyval_name(keyval);
    e.keyname = n ? n : "";
    char buf[8] = { 0 };
    gunichar u = gdk_keyval_to_unicode(keyval);
    if (u) g_unichar_to_utf8(u, buf);
    e.chars = buf;
    return t->fn(&e, t->data);
}

static gboolean key_pressed(GtkEventControllerKey *c, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    (void)c;
    return key_common(data, keyval, keycode, state, TRUE);
}
static void key_released(GtkEventControllerKey *c, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    (void)c;
    key_common(data, keyval, keycode, state, FALSE);
}

void runway_appkit_install_events(GtkWidget *window, GtkWidget *content, RunwayAppKitEventFunc fn, void *data, GDestroyNotify notify) {
    EventTarget *t = g_new0(EventTarget, 1);
    t->fn = fn; t->data = data; t->notify = notify; t->content = content;
    GtkEventController *legacy = gtk_event_controller_legacy_new();
    gtk_event_controller_set_propagation_phase(legacy, GTK_PHASE_BUBBLE);
    g_signal_connect_data(legacy, "event", G_CALLBACK(legacy_event), t, event_target_free, 0);
    gtk_widget_add_controller(content, legacy);
    // Keys share the target; it's freed with the legacy controller's closure.
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect_data(keys, "key-pressed", G_CALLBACK(key_pressed), t, NULL, 0);
    g_signal_connect_data(keys, "key-released", G_CALLBACK(key_released), t, NULL, 0);
    gtk_widget_add_controller(window, keys);
}

typedef struct { RunwayBoolFunc fn; void *data; GDestroyNotify notify; } BoolTarget;
static void bool_target_free(gpointer p, GClosure *c) {
    (void)c;
    BoolTarget *t = p;
    if (t->notify) t->notify(t->data);
    g_free(t);
}
static void active_changed(GObject *o, GParamSpec *ps, gpointer data) {
    (void)ps;
    BoolTarget *t = data;
    t->fn(gtk_window_is_active(GTK_WINDOW(o)), t->data);
}
void runway_appkit_install_activation(GtkWidget *window, RunwayBoolFunc fn, void *data, GDestroyNotify notify) {
    BoolTarget *t = g_new0(BoolTarget, 1);
    t->fn = fn; t->data = data; t->notify = notify;
    g_signal_connect_data(window, "notify::is-active", G_CALLBACK(active_changed), t, bool_target_free, 0);
}

static void pressed(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    (void)g; (void)n; (void)x; (void)y;
    BoolTarget *t = data;
    t->fn(TRUE, t->data);
}
void runway_appkit_on_press(GtkWidget *widget, RunwayBoolFunc fn, void *data, GDestroyNotify notify) {
    BoolTarget *t = g_new0(BoolTarget, 1);
    t->fn = fn; t->data = data; t->notify = notify;
    GtkGesture *g = gtk_gesture_click_new();
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(g), GTK_PHASE_CAPTURE);
    g_signal_connect_data(g, "pressed", G_CALLBACK(pressed), t, bool_target_free, 0);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(g));
}

// MARK: Drops

typedef struct { RunwayDropFunc fn; void *data; GDestroyNotify notify; } DropTarget;
static void drop_target_free(gpointer p, GClosure *c) {
    (void)c;
    DropTarget *t = p;
    if (t->notify) t->notify(t->data);
    g_free(t);
}

static void value_contents(const GValue *v, char **uris, char **text) {
    *uris = NULL; *text = NULL;
    if (!v) return;
    if (G_VALUE_HOLDS(v, GDK_TYPE_FILE_LIST)) {
        GSList *files = gdk_file_list_get_files(g_value_get_boxed(v));
        GString *s = g_string_new(NULL);
        for (GSList *l = files; l; l = l->next) {
            char *u = g_file_get_uri(l->data);
            if (s->len) g_string_append_c(s, '\n');
            g_string_append(s, u);
            g_free(u);
        }
        g_slist_free(files);
        *uris = g_string_free(s, FALSE);
    } else if (G_VALUE_HOLDS_STRING(v)) {
        *text = g_value_dup_string(v);
    }
}

static GdkDragAction to_action(int op) {
    if (op & 1) return GDK_ACTION_COPY;
    if (op & 16) return GDK_ACTION_MOVE;
    if (op & 2) return GDK_ACTION_LINK;
    return 0;
}

static GdkDragAction drop_motion_common(GtkDropTarget *dt, double x, double y, DropTarget *t, int kind) {
    char *uris, *text;
    value_contents(gtk_drop_target_get_value(dt), &uris, &text);
    int op = t->fn(kind, x, y, uris ? uris : "", text ? text : "", t->data);
    g_free(uris); g_free(text);
    return to_action(op);
}
static GdkDragAction drop_enter(GtkDropTarget *dt, double x, double y, gpointer data) { return drop_motion_common(dt, x, y, data, 0); }
static GdkDragAction drop_motion(GtkDropTarget *dt, double x, double y, gpointer data) { return drop_motion_common(dt, x, y, data, 1); }
static void drop_leave(GtkDropTarget *dt, gpointer data) {
    (void)dt;
    DropTarget *t = data;
    t->fn(2, 0, 0, "", "", t->data);
}
static gboolean drop_drop(GtkDropTarget *dt, const GValue *value, double x, double y, gpointer data) {
    (void)dt;
    DropTarget *t = data;
    char *uris, *text;
    value_contents(value, &uris, &text);
    int op = t->fn(3, x, y, uris ? uris : "", text ? text : "", t->data);
    g_free(uris); g_free(text);
    return op != 0;
}

void runway_appkit_install_drop(GtkWidget *content, RunwayDropFunc fn, void *data, GDestroyNotify notify) {
    DropTarget *t = g_new0(DropTarget, 1);
    t->fn = fn; t->data = data; t->notify = notify;
    GtkDropTarget *dt = gtk_drop_target_new(G_TYPE_INVALID, GDK_ACTION_COPY | GDK_ACTION_MOVE | GDK_ACTION_LINK);
    GType types[2] = { GDK_TYPE_FILE_LIST, G_TYPE_STRING };
    gtk_drop_target_set_gtypes(dt, types, 2);
    gtk_drop_target_set_preload(dt, TRUE);
    g_signal_connect_data(dt, "enter", G_CALLBACK(drop_enter), t, drop_target_free, 0);
    g_signal_connect_data(dt, "motion", G_CALLBACK(drop_motion), t, NULL, 0);
    g_signal_connect_data(dt, "leave", G_CALLBACK(drop_leave), t, NULL, 0);
    g_signal_connect_data(dt, "drop", G_CALLBACK(drop_drop), t, NULL, 0);
    gtk_widget_add_controller(content, GTK_EVENT_CONTROLLER(dt));
}

// MARK: Menus

static GQuark bar_quark(void) {
    static GQuark q = 0;
    if (!q) q = g_quark_from_static_string("runway-menubar");
    return q;
}

void runway_appkit_set_menubar(GtkWidget *window, GtkWidget *bar) {
    GtkWidget *old = g_object_get_qdata(G_OBJECT(window), bar_quark());
    GtkWidget *child = gtk_window_get_child(GTK_WINDOW(window));
    if (old) {
        // The child is our box: [old bar, content].
        GtkWidget *content = gtk_widget_get_next_sibling(old);
        if (bar) {
            gtk_box_insert_child_after(GTK_BOX(child), bar, NULL);
            gtk_box_remove(GTK_BOX(child), old);
            g_object_set_qdata(G_OBJECT(window), bar_quark(), bar);
            return;
        }
        g_object_ref(content);
        gtk_box_remove(GTK_BOX(child), content);
        gtk_window_set_child(GTK_WINDOW(window), content);
        g_object_unref(content);
        g_object_set_qdata(G_OBJECT(window), bar_quark(), NULL);
        return;
    }
    if (!bar || !child) return;
    g_object_ref(child);
    gtk_window_set_child(GTK_WINDOW(window), NULL);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(box), bar);
    gtk_box_append(GTK_BOX(box), child);
    gtk_widget_set_vexpand(child, TRUE);
    gtk_widget_set_hexpand(child, TRUE);
    gtk_window_set_child(GTK_WINDOW(window), box);
    g_object_unref(child);
    g_object_set_qdata(G_OBJECT(window), bar_quark(), bar);
}

static void popover_closed(GtkPopover *p, gpointer data) {
    (void)p;
    *(gboolean *)data = TRUE;
}

void runway_appkit_popup_menu(GtkWidget *parent, GMenuModel *model, GActionGroup *group, double x, double y) {
    GtkWidget *pop = gtk_popover_menu_new_from_model(model);
    gtk_widget_set_parent(pop, parent);
    gtk_widget_insert_action_group(pop, "rwc", group);
    GdkRectangle r = { (int)x, (int)y, 1, 1 };
    gtk_popover_set_pointing_to(GTK_POPOVER(pop), &r);
    gtk_popover_set_has_arrow(GTK_POPOVER(pop), FALSE);
    gtk_widget_set_halign(pop, GTK_ALIGN_START);
    gboolean closed = FALSE;
    gulong id = g_signal_connect(pop, "closed", G_CALLBACK(popover_closed), &closed);
    gtk_popover_popup(GTK_POPOVER(pop));
    while (!closed) g_main_context_iteration(NULL, TRUE);
    // Let the chosen item's action run before the popover goes.
    while (g_main_context_pending(NULL)) g_main_context_iteration(NULL, FALSE);
    g_signal_handler_disconnect(pop, id);
    gtk_widget_unparent(pop);
}

typedef struct { RunwayIndexFunc2 fn; void *data; int index; } ActionTarget;
static void action_activated(GSimpleAction *a, GVariant *param, gpointer data) {
    (void)a; (void)param;
    ActionTarget *t = data;
    t->fn(t->index, t->data);
}
void runway_appkit_action_connect(GSimpleAction *action, RunwayIndexFunc2 fn, void *data, int index) {
    ActionTarget *t = g_new0(ActionTarget, 1);
    t->fn = fn; t->data = data; t->index = index;
    g_signal_connect_data(action, "activate", G_CALLBACK(action_activated), t, (GClosureNotify)g_free, 0);
}

void runway_appkit_set_cursor(GtkWidget *w, const char *name, const unsigned char *rgba, int width, int height, int hot_x, int hot_y) {
    if (!rgba) { gtk_widget_set_cursor_from_name(w, name); return; }
    GBytes *bytes = g_bytes_new(rgba, (gsize)width * height * 4);
    GdkTexture *tex = gdk_memory_texture_new(width, height, GDK_MEMORY_R8G8B8A8, bytes, (gsize)width * 4);
    GdkCursor *c = gdk_cursor_new_from_texture(tex, hot_x, hot_y, NULL);
    gtk_widget_set_cursor(w, c);
    g_object_unref(c);
    g_object_unref(tex);
    g_bytes_unref(bytes);
}
#endif

void runway_appkit_begin_move(GtkWidget *window, int button, double x, double y, guint32 timestamp) {
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
    if (!surface || !GDK_IS_TOPLEVEL(surface)) return;
    GdkSeat *seat = gdk_display_get_default_seat(gtk_widget_get_display(window));
    GdkDevice *pointer = seat ? gdk_seat_get_pointer(seat) : NULL;
    if (!pointer) return;
    gdk_toplevel_begin_move(GDK_TOPLEVEL(surface), pointer, button, x, y, timestamp);
}
