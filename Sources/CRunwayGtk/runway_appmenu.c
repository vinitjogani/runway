#if defined(__linux__) || defined(__FreeBSD__)
// The global menu bar: a window's menu (the GMenuModel and actions its
// in-window bar uses) exported as com.canonical.dbusmenu and registered
// with com.canonical.AppMenu.Registrar, the protocol Unity, KDE Plasma and
// the Xfce, MATE and Budgie appmenu plugins show at the top of the screen.
// KDE also reads the _KDE_NET_WM_APPMENU_* window properties. Clicks run
// the same GActions; sections become separators; accels become shortcuts.
// Whether a host is present is watched: the in-window bar shows only when
// there is none (GNOME, or the host goes away).

#include "runway_gtk.h"
#include <string.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/x11/gdkx.h>
#endif

typedef struct {
    int parent;          // id of the parent node (0: the root)
    gboolean separator, submenu;
    char *label, *action, *accel;
    GVariant *target;
} AMItem;

struct _RunwayAppMenu {
    GDBusConnection *bus;
    GtkWidget *window;
    GMenuModel *model;
    GActionGroup *group;   // actions, unprefixed names
    char *prefix;          // "rwm." in the model's action names
    char *path;
    guint reg, watch;
    gboolean registered, host;
    AMItem *items;
    int count, cap;
    guint revision;
    RunwayAppMenuHostFunc on_host;
    RunwayAppMenuShowFunc on_show;
    void *data;
};

static const char *am_xml =
    "<node><interface name='com.canonical.dbusmenu'>"
    "<property name='Version' type='u' access='read'/>"
    "<property name='TextDirection' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/>"
    "<method name='GetLayout'><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='as' direction='in'/>"
    "<arg type='u' direction='out'/><arg type='(ia{sv}av)' direction='out'/></method>"
    "<method name='GetGroupProperties'><arg type='ai' direction='in'/><arg type='as' direction='in'/>"
    "<arg type='a(ia{sv})' direction='out'/></method>"
    "<method name='GetProperty'><arg type='i' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='out'/></method>"
    "<method name='Event'><arg type='i' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='in'/><arg type='u' direction='in'/></method>"
    "<method name='EventGroup'><arg type='a(isvu)' direction='in'/><arg type='ai' direction='out'/></method>"
    "<method name='AboutToShow'><arg type='i' direction='in'/><arg type='b' direction='out'/></method>"
    "<method name='AboutToShowGroup'><arg type='ai' direction='in'/><arg type='ai' direction='out'/><arg type='ai' direction='out'/></method>"
    "<signal name='LayoutUpdated'><arg type='u'/><arg type='i'/></signal>"
    "<signal name='ItemsPropertiesUpdated'><arg type='a(ia{sv})'/><arg type='a(ias)'/></signal>"
    "</interface></node>";

static void am_clear(RunwayAppMenu *m) {
    for (int i = 0; i < m->count; i++) {
        g_free(m->items[i].label); g_free(m->items[i].action); g_free(m->items[i].accel);
        if (m->items[i].target) g_variant_unref(m->items[i].target);
    }
    m->count = 0;
}

static int am_add(RunwayAppMenu *m, AMItem it) {
    if (m->count == m->cap) { m->cap = m->cap ? m->cap * 2 : 64; m->items = g_renew(AMItem, m->items, m->cap); }
    m->items[m->count++] = it;
    return m->count;  // ids start at 1
}

static void am_walk(RunwayAppMenu *m, GMenuModel *model, int parent, gboolean *need_sep) {
    int n = g_menu_model_get_n_items(model);
    for (int i = 0; i < n; i++) {
        GMenuModel *section = g_menu_model_get_item_link(model, i, G_MENU_LINK_SECTION);
        if (section) {
            // Sections are set off by separators, as the in-window bar draws them.
            gboolean has_items = g_menu_model_get_n_items(section) > 0;
            if (has_items && *need_sep) am_add(m, (AMItem){ .parent = parent, .separator = TRUE });
            gboolean inner = FALSE;
            am_walk(m, section, parent, &inner);
            if (has_items) *need_sep = TRUE;
            g_object_unref(section);
            continue;
        }
        AMItem it = { .parent = parent };
        g_menu_model_get_item_attribute(model, i, G_MENU_ATTRIBUTE_LABEL, "s", &it.label);
        g_menu_model_get_item_attribute(model, i, G_MENU_ATTRIBUTE_ACTION, "s", &it.action);
        g_menu_model_get_item_attribute(model, i, "accel", "s", &it.accel);
        it.target = g_menu_model_get_item_attribute_value(model, i, G_MENU_ATTRIBUTE_TARGET, NULL);
        GMenuModel *sub = g_menu_model_get_item_link(model, i, G_MENU_LINK_SUBMENU);
        it.submenu = sub != NULL;
        int id = am_add(m, it);
        if (sub) {
            gboolean sep = FALSE;
            am_walk(m, sub, id, &sep);
            g_object_unref(sub);
        }
        *need_sep = TRUE;
    }
}

static void am_rebuild(RunwayAppMenu *m) {
    am_clear(m);
    gboolean sep = FALSE;
    if (m->model) am_walk(m, m->model, 0, &sep);
}

static const char *am_action_name(RunwayAppMenu *m, const char *full) {
    size_t n = strlen(m->prefix);
    return strncmp(full, m->prefix, n) == 0 ? full + n : full;
}

/// dbusmenu's shortcut: [["Control", "Shift", "n"]] from a GTK accel.
static GVariant *am_shortcut(const char *accel) {
    guint key = 0; GdkModifierType mods = 0;
    if (!accel || !gtk_accelerator_parse(accel, &key, &mods) || !key) return NULL;
    GVariantBuilder one, all;
    g_variant_builder_init(&one, G_VARIANT_TYPE("as"));
    if (mods & GDK_CONTROL_MASK) g_variant_builder_add(&one, "s", "Control");
    if (mods & GDK_ALT_MASK) g_variant_builder_add(&one, "s", "Alt");
    if (mods & GDK_SHIFT_MASK) g_variant_builder_add(&one, "s", "Shift");
    if (mods & GDK_SUPER_MASK) g_variant_builder_add(&one, "s", "Super");
    const char *name = gdk_keyval_name(gdk_keyval_to_lower(key));
    g_variant_builder_add(&one, "s", name ? name : "");
    g_variant_builder_init(&all, G_VARIANT_TYPE("aas"));
    g_variant_builder_add_value(&all, g_variant_builder_end(&one));
    return g_variant_builder_end(&all);
}

static GVariant *am_props(RunwayAppMenu *m, int id) {
    GVariantBuilder p;
    g_variant_builder_init(&p, G_VARIANT_TYPE("a{sv}"));
    if (id == 0) {
        g_variant_builder_add(&p, "{sv}", "children-display", g_variant_new_string("submenu"));
        return g_variant_builder_end(&p);
    }
    AMItem *it = &m->items[id - 1];
    if (it->separator) {
        g_variant_builder_add(&p, "{sv}", "type", g_variant_new_string("separator"));
        return g_variant_builder_end(&p);
    }
    g_variant_builder_add(&p, "{sv}", "label", g_variant_new_string(it->label ? it->label : ""));
    if (it->submenu) g_variant_builder_add(&p, "{sv}", "children-display", g_variant_new_string("submenu"));
    if (it->action && m->group) {
        const char *a = am_action_name(m, it->action);
        gboolean enabled = g_action_group_has_action(m->group, a) && g_action_group_get_action_enabled(m->group, a);
        g_variant_builder_add(&p, "{sv}", "enabled", g_variant_new_boolean(enabled));
        GVariant *state = g_action_group_has_action(m->group, a) ? g_action_group_get_action_state(m->group, a) : NULL;
        if (state) {
            gboolean on = FALSE;
            const char *kind = "checkmark";
            if (g_variant_is_of_type(state, G_VARIANT_TYPE_BOOLEAN)) on = g_variant_get_boolean(state);
            else if (it->target) { on = g_variant_equal(state, it->target); kind = "radio"; }
            g_variant_builder_add(&p, "{sv}", "toggle-type", g_variant_new_string(kind));
            g_variant_builder_add(&p, "{sv}", "toggle-state", g_variant_new_int32(on ? 1 : 0));
            g_variant_unref(state);
        }
    } else if (!it->submenu) {
        g_variant_builder_add(&p, "{sv}", "enabled", g_variant_new_boolean(FALSE));
    }
    GVariant *sc = am_shortcut(it->accel);
    if (sc) g_variant_builder_add(&p, "{sv}", "shortcut", sc);
    return g_variant_builder_end(&p);
}

static GVariant *am_node(RunwayAppMenu *m, int id, int depth) {
    GVariantBuilder kids;
    g_variant_builder_init(&kids, G_VARIANT_TYPE("av"));
    if (depth != 0) {
        for (int i = 0; i < m->count; i++)
            if (m->items[i].parent == id) g_variant_builder_add(&kids, "v", am_node(m, i + 1, depth < 0 ? -1 : depth - 1));
    }
    return g_variant_new("(i@a{sv}av)", id, am_props(m, id), &kids);
}

static void am_call(GDBusConnection *c, const char *sender, const char *path, const char *iface, const char *method,
                    GVariant *params, GDBusMethodInvocation *inv, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface;
    RunwayAppMenu *m = data;
    if (!strcmp(method, "GetLayout")) {
        gint32 parent = 0, depth = -1;
        g_variant_get(params, "(ii^a&s)", &parent, &depth, NULL);
        if (parent == 0) am_rebuild(m);
        if (parent < 0 || parent > m->count) parent = 0;
        g_dbus_method_invocation_return_value(inv, g_variant_new("(u@(ia{sv}av))", m->revision, am_node(m, parent, depth)));
    } else if (!strcmp(method, "GetGroupProperties")) {
        GVariantIter *ids;
        g_variant_get(params, "(ai^a&s)", &ids, NULL);
        GVariantBuilder out;
        g_variant_builder_init(&out, G_VARIANT_TYPE("a(ia{sv})"));
        gint32 id;
        while (g_variant_iter_next(ids, "i", &id))
            if (id >= 0 && id <= m->count) g_variant_builder_add(&out, "(i@a{sv})", id, am_props(m, id));
        g_variant_iter_free(ids);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(a(ia{sv}))", &out));
    } else if (!strcmp(method, "GetProperty")) {
        g_dbus_method_invocation_return_value(inv, g_variant_new("(v)", g_variant_new_string("")));
    } else if (!strcmp(method, "Event")) {
        gint32 id; const char *ev;
        g_variant_get(params, "(i&svu)", &id, &ev, NULL, NULL);
        if (!strcmp(ev, "clicked") && id > 0 && id <= m->count) {
            AMItem *it = &m->items[id - 1];
            if (it->action && m->group) {
                const char *a = am_action_name(m, it->action);
                g_action_group_activate_action(m->group, a, it->target);
            }
        }
        g_dbus_method_invocation_return_value(inv, NULL);
    } else if (!strcmp(method, "EventGroup")) {
        GVariantIter *evs;
        g_variant_get(params, "(a(isvu))", &evs);
        gint32 id; const char *ev; GVariant *v; guint32 t;
        while (g_variant_iter_next(evs, "(i&svu)", &id, &ev, &v, &t)) {
            if (!strcmp(ev, "clicked") && id > 0 && id <= m->count && m->items[id - 1].action && m->group)
                g_action_group_activate_action(m->group, am_action_name(m, m->items[id - 1].action), m->items[id - 1].target);
            g_variant_unref(v);
        }
        g_variant_iter_free(evs);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(ai)", NULL));
    } else if (!strcmp(method, "AboutToShow") || !strcmp(method, "AboutToShowGroup")) {
        // Menus validate as they open (validateMenuItem:, menuNeedsUpdate:).
        if (m->on_show) m->on_show(m->data);
        if (!strcmp(method, "AboutToShow")) g_dbus_method_invocation_return_value(inv, g_variant_new("(b)", TRUE));
        else g_dbus_method_invocation_return_value(inv, g_variant_new("(aiai)", NULL, NULL));
    } else {
        g_dbus_method_invocation_return_value(inv, NULL);
    }
}

static GVariant *am_get(GDBusConnection *c, const char *sender, const char *path, const char *iface,
                        const char *prop, GError **err, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)err; (void)data;
    if (!strcmp(prop, "Version")) return g_variant_new_uint32(3);
    if (!strcmp(prop, "TextDirection")) return g_variant_new_string("ltr");
    if (!strcmp(prop, "Status")) return g_variant_new_string("normal");
    return NULL;
}

static const GDBusInterfaceVTable am_vtable = { am_call, am_get, NULL, { 0 } };

static void am_register_window(RunwayAppMenu *m) {
    if (!m->host || m->registered) return;
#ifdef GDK_WINDOWING_X11
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(m->window));
    if (surface && GDK_IS_X11_SURFACE(surface)) {
        guint32 xid = (guint32)gdk_x11_surface_get_xid(surface);
        g_dbus_connection_call(m->bus, "com.canonical.AppMenu.Registrar", "/com/canonical/AppMenu/Registrar",
                               "com.canonical.AppMenu.Registrar", "RegisterWindow", g_variant_new("(uo)", xid, m->path),
                               NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
        gdk_x11_surface_set_utf8_property(surface, "_KDE_NET_WM_APPMENU_SERVICE_NAME", g_dbus_connection_get_unique_name(m->bus));
        gdk_x11_surface_set_utf8_property(surface, "_KDE_NET_WM_APPMENU_OBJECT_PATH", m->path);
        m->registered = TRUE;
    }
#endif
}

static void am_realized(GtkWidget *w, gpointer data) { (void)w; am_register_window(data); }

static void am_host_changed(RunwayAppMenu *m, gboolean present) {
    // A registrar only helps a window it can name (an X11 window id).
    gboolean usable = present;
#ifdef GDK_WINDOWING_X11
    usable = usable && GDK_IS_X11_DISPLAY(gtk_widget_get_display(m->window));
#else
    usable = FALSE;
#endif
    if (!usable) { m->registered = FALSE; }
    if (m->host == usable) return;
    m->host = usable;
    if (usable && gtk_widget_get_realized(m->window)) am_register_window(m);
    if (m->on_host) m->on_host(usable, m->data);
}

static void am_appeared(GDBusConnection *c, const char *name, const char *owner, gpointer data) {
    (void)c; (void)name; (void)owner; am_host_changed(data, TRUE);
}
static void am_vanished(GDBusConnection *c, const char *name, gpointer data) {
    (void)c; (void)name; am_host_changed(data, FALSE);
}

RunwayAppMenu *runway_appmenu_new(GtkWidget *window, RunwayAppMenuHostFunc on_host, RunwayAppMenuShowFunc on_show, void *data) {
    const char *env = g_getenv("RUNWAY_GLOBAL_MENU");
    if (env && !strcmp(env, "0")) return NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!bus) return NULL;
    static int counter = 0;
    RunwayAppMenu *m = g_new0(RunwayAppMenu, 1);
    m->bus = bus;
    m->window = window;
    m->on_host = on_host; m->on_show = on_show; m->data = data;
    m->revision = 1;
    m->prefix = g_strdup("");
    m->path = g_strdup_printf("/com/canonical/menu/runway%d", ++counter);
    GDBusNodeInfo *info = g_dbus_node_info_new_for_xml(am_xml, NULL);
    m->reg = g_dbus_connection_register_object(bus, m->path, info->interfaces[0], &am_vtable, m, NULL, NULL);
    g_dbus_node_info_unref(info);
    g_signal_connect(window, "realize", G_CALLBACK(am_realized), m);
    m->watch = g_bus_watch_name_on_connection(bus, "com.canonical.AppMenu.Registrar", G_BUS_NAME_WATCHER_FLAGS_NONE,
                                              am_appeared, am_vanished, m, NULL);
    return m;
}

void runway_appmenu_set(RunwayAppMenu *m, GMenuModel *model, GActionGroup *group, const char *prefix) {
    if (!m) return;
    g_set_object(&m->model, model);
    g_set_object(&m->group, group);
    g_free(m->prefix);
    m->prefix = g_strdup_printf("%s.", prefix ? prefix : "");
    am_rebuild(m);
    m->revision++;
    g_dbus_connection_emit_signal(m->bus, NULL, m->path, "com.canonical.dbusmenu", "LayoutUpdated",
                                  g_variant_new("(ui)", m->revision, 0), NULL);
}

/// Item states changed (enabled, checked): hosts re-read the layout.
void runway_appmenu_changed(RunwayAppMenu *m) {
    if (!m) return;
    m->revision++;
    g_dbus_connection_emit_signal(m->bus, NULL, m->path, "com.canonical.dbusmenu", "LayoutUpdated",
                                  g_variant_new("(ui)", m->revision, 0), NULL);
}

gboolean runway_appmenu_has_host(RunwayAppMenu *m) { return m && m->host; }

void runway_appmenu_free(RunwayAppMenu *m) {
    if (!m) return;
    g_bus_unwatch_name(m->watch);
    g_dbus_connection_unregister_object(m->bus, m->reg);
    g_signal_handlers_disconnect_by_data(m->window, m);
    am_clear(m);
    g_free(m->items);
    g_clear_object(&m->model);
    g_clear_object(&m->group);
    g_free(m->prefix); g_free(m->path);
    g_object_unref(m->bus);
    g_free(m);
}
#endif
