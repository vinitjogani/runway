#if defined(__linux__) || defined(__FreeBSD__)
#include "runway_controls.h"
#include "runway_gtk.h"
#include <string.h>
#include <unistd.h>

// MARK: Text tags

GtkTextTag *runway_text_tag_new(GtkTextBuffer *buffer, const char *font, const char *fg, const char *bg,
                                gboolean underline, gboolean strike, int rise_pango, double letter_spacing_pango,
                                int justification, int left_margin, int indent, int right_margin,
                                int pixels_above, int pixels_below, int pixels_inside) {
    GtkTextTag *tag = gtk_text_buffer_create_tag(buffer, NULL, NULL);
    if (font) g_object_set(tag, "font", font, NULL);
    if (fg) g_object_set(tag, "foreground", fg, NULL);
    if (bg) g_object_set(tag, "background", bg, NULL);
    if (underline) g_object_set(tag, "underline", PANGO_UNDERLINE_SINGLE, NULL);
    if (strike) g_object_set(tag, "strikethrough", TRUE, NULL);
    if (rise_pango) g_object_set(tag, "rise", rise_pango, NULL);
    if (letter_spacing_pango != 0) g_object_set(tag, "letter-spacing", (int)letter_spacing_pango, NULL);
    if (justification >= 0) {
        GtkJustification j = justification == 1 ? GTK_JUSTIFY_RIGHT : justification == 2 ? GTK_JUSTIFY_CENTER
                           : justification == 3 ? GTK_JUSTIFY_FILL : GTK_JUSTIFY_LEFT;
        g_object_set(tag, "justification", j, NULL);
    }
    if (left_margin >= 0) g_object_set(tag, "left-margin", left_margin, NULL);
    if (indent != G_MININT) g_object_set(tag, "indent", indent, NULL);
    if (right_margin >= 0) g_object_set(tag, "right-margin", right_margin, NULL);
    if (pixels_above >= 0) g_object_set(tag, "pixels-above-lines", pixels_above, NULL);
    if (pixels_below >= 0) g_object_set(tag, "pixels-below-lines", pixels_below, NULL);
    if (pixels_inside >= 0) g_object_set(tag, "pixels-inside-wrap", pixels_inside, NULL);
    return tag;
}

double runway_text_width(GtkWidget *widget, const char *font, const char *text) {
    PangoLayout *layout = gtk_widget_create_pango_layout(widget, text);
    PangoFontDescription *d = pango_font_description_from_string(font);
    pango_layout_set_font_description(layout, d);
    pango_font_description_free(d);
    int w = 0, h = 0;
    pango_layout_get_size(layout, &w, &h);
    g_object_unref(layout);
    return w / (double)PANGO_SCALE;
}

void runway_text_tag_set_margins(GtkTextTag *tag, int left, int right) {
    g_object_set(tag, "left-margin", left, "right-margin", right, NULL);
}

void runway_text_tag_set_more(GtkTextTag *tag, gboolean invisible, double line_height, const char *underline_rgba,
                              const char *strike_rgba, int underline_style) {
    if (invisible) g_object_set(tag, "invisible", TRUE, NULL);
    if (line_height > 0) g_object_set(tag, "line-height", (float)line_height, NULL);
    GdkRGBA c;
    if (underline_rgba && gdk_rgba_parse(&c, underline_rgba)) g_object_set(tag, "underline-rgba", &c, NULL);
    if (strike_rgba && gdk_rgba_parse(&c, strike_rgba)) g_object_set(tag, "strikethrough-rgba", &c, NULL);
    if (underline_style == 2) g_object_set(tag, "underline", PANGO_UNDERLINE_SINGLE_LINE, NULL);
    if (underline_style == 3) g_object_set(tag, "underline", PANGO_UNDERLINE_DOUBLE, NULL);
}

int runway_markup_height(GtkWidget *widget, const char *markup, int width, gboolean wrap) {
    PangoLayout *layout = gtk_widget_create_pango_layout(widget, NULL);
    pango_layout_set_markup(layout, markup, -1);
    if (wrap && width > 0) {
        pango_layout_set_width(layout, width * PANGO_SCALE);
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);
    }
    int w = 0, h = 0;
    pango_layout_get_pixel_size(layout, &w, &h);
    g_object_unref(layout);
    return h;
}

// MARK: Pop-up menus

typedef struct { GtkWidget *button; GtkWidget *canvas; } PopupInfo;

static gboolean popup_cleanup(gpointer data) {
    PopupInfo *p = data;
    runway_canvas_remove(p->canvas, p->button);
    g_object_unref(p->button);
    g_object_unref(p->canvas);
    g_free(p);
    return G_SOURCE_REMOVE;
}

static void popup_closed(GtkPopover *popover, gpointer data) {
    (void)popover;
    // After the menu's action has run.
    g_idle_add(popup_cleanup, data);
}

void runway_popup_menu(GtkWidget *canvas, int x, int y, const char *const *titles, const int *kinds, const int *depths,
                       const gboolean *enabled, const gboolean *checked, int count, RunwayAKIndexFunc fn, void *user_data) {
    GtkWidget *button = gtk_menu_button_new();
    g_object_ref_sink(button);
    gtk_widget_set_opacity(button, 0);
    runway_canvas_place(canvas, button, x, y, 1, 1);
    runway_menu_button_set(button, titles, kinds, depths, enabled, checked, count, (RunwayIndexFunc)fn, user_data);
    GtkPopover *pop = gtk_menu_button_get_popover(GTK_MENU_BUTTON(button));
    PopupInfo *info = g_new(PopupInfo, 1);
    info->button = button;
    info->canvas = g_object_ref(canvas);
    if (pop) {
        gtk_popover_set_has_arrow(pop, FALSE);
        gtk_widget_set_halign(GTK_WIDGET(pop), GTK_ALIGN_START);
        g_signal_connect(pop, "closed", G_CALLBACK(popup_closed), info);
    }
    gtk_menu_button_popup(GTK_MENU_BUTTON(button));
    if (!pop) popup_cleanup(info);
}

// MARK: Status items (StatusNotifierItem + dbusmenu)

typedef struct { char *title; int kind; gboolean enabled, checked; int parent; } SIItem;

struct RunwayStatusItem {
    GDBusConnection *bus;
    char *bus_name;
    guint name_id, item_reg, menu_reg;
    char *id, *title, *icon, *tooltip;
    gboolean visible;
    SIItem *items;
    int count;
    guint revision;
    RunwayStatusFunc fn;
    void *data;
};

static const char *sni_xml =
    "<node><interface name='org.kde.StatusNotifierItem'>"
    "<property name='Category' type='s' access='read'/>"
    "<property name='Id' type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/>"
    "<property name='IconName' type='s' access='read'/>"
    "<property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "<property name='ItemIsMenu' type='b' access='read'/>"
    "<property name='Menu' type='o' access='read'/>"
    "<method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='SecondaryActivate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='Scroll'><arg type='i' direction='in'/><arg type='s' direction='in'/></method>"
    "<signal name='NewTitle'/><signal name='NewIcon'/><signal name='NewToolTip'/>"
    "<signal name='NewStatus'><arg type='s'/></signal>"
    "</interface></node>";

static const char *menu_xml =
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

static GVariant *sni_get(GDBusConnection *c, const char *sender, const char *path, const char *iface,
                         const char *prop, GError **err, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)err;
    RunwayStatusItem *s = data;
    if (!strcmp(prop, "Category")) return g_variant_new_string("ApplicationStatus");
    if (!strcmp(prop, "Id")) return g_variant_new_string(s->id);
    if (!strcmp(prop, "Title")) return g_variant_new_string(s->title);
    if (!strcmp(prop, "Status")) return g_variant_new_string(s->visible ? "Active" : "Passive");
    if (!strcmp(prop, "IconName")) return g_variant_new_string(s->icon);
    if (!strcmp(prop, "ItemIsMenu")) return g_variant_new_boolean(FALSE);
    if (!strcmp(prop, "Menu")) return g_variant_new_object_path("/MenuBar");
    if (!strcmp(prop, "ToolTip")) {
        GVariantBuilder px;
        g_variant_builder_init(&px, G_VARIANT_TYPE("a(iiay)"));
        return g_variant_new("(sa(iiay)ss)", s->icon, &px, s->tooltip, "");
    }
    return NULL;
}

static void sni_call(GDBusConnection *c, const char *sender, const char *path, const char *iface, const char *method,
                     GVariant *params, GDBusMethodInvocation *inv, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)params;
    RunwayStatusItem *s = data;
    if (!strcmp(method, "Activate") || !strcmp(method, "SecondaryActivate")) s->fn(-1, s->data);
    g_dbus_method_invocation_return_value(inv, NULL);
}

/// One menu node: its properties and (for the root and submenus) children.
static GVariant *menu_node(RunwayStatusItem *s, int id) {
    GVariantBuilder props, kids;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_init(&kids, G_VARIANT_TYPE("av"));
    if (id == 0) {
        g_variant_builder_add(&props, "{sv}", "children-display", g_variant_new_string("submenu"));
    } else {
        SIItem *it = &s->items[id - 1];
        if (it->kind == 1) {
            g_variant_builder_add(&props, "{sv}", "type", g_variant_new_string("separator"));
        } else {
            g_variant_builder_add(&props, "{sv}", "label", g_variant_new_string(it->title));
            g_variant_builder_add(&props, "{sv}", "enabled", g_variant_new_boolean(it->enabled));
            if (it->checked) {
                g_variant_builder_add(&props, "{sv}", "toggle-type", g_variant_new_string("checkmark"));
                g_variant_builder_add(&props, "{sv}", "toggle-state", g_variant_new_int32(1));
            }
            if (it->kind == 2) g_variant_builder_add(&props, "{sv}", "children-display", g_variant_new_string("submenu"));
        }
    }
    for (int i = 0; i < s->count; i++) {
        if (s->items[i].parent == id && s->items[i].kind != 3) g_variant_builder_add(&kids, "v", menu_node(s, i + 1));
    }
    return g_variant_new("(ia{sv}av)", id, &props, &kids);
}

static void menu_call(GDBusConnection *c, const char *sender, const char *path, const char *iface, const char *method,
                      GVariant *params, GDBusMethodInvocation *inv, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface;
    RunwayStatusItem *s = data;
    if (!strcmp(method, "GetLayout")) {
        gint32 parent = 0, depth = 0;
        g_variant_get(params, "(ii^a&s)", &parent, &depth, NULL);
        if (parent < 0 || parent > s->count) parent = 0;
        g_dbus_method_invocation_return_value(inv, g_variant_new("(u@(ia{sv}av))", s->revision, menu_node(s, parent)));
    } else if (!strcmp(method, "GetGroupProperties")) {
        GVariantIter *ids;
        g_variant_get(params, "(ai^a&s)", &ids, NULL);
        GVariantBuilder out;
        g_variant_builder_init(&out, G_VARIANT_TYPE("a(ia{sv})"));
        gint32 id;
        while (g_variant_iter_next(ids, "i", &id)) {
            if (id < 0 || id > s->count) continue;
            GVariant *node = menu_node(s, id);
            GVariant *props = g_variant_get_child_value(node, 1);
            g_variant_builder_add(&out, "(i@a{sv})", id, props);
            g_variant_unref(props);
            g_variant_unref(g_variant_ref_sink(node));
        }
        g_variant_iter_free(ids);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(a(ia{sv}))", &out));
    } else if (!strcmp(method, "GetProperty")) {
        g_dbus_method_invocation_return_value(inv, g_variant_new("(v)", g_variant_new_string("")));
    } else if (!strcmp(method, "Event")) {
        gint32 id; const char *ev;
        g_variant_get(params, "(i&svu)", &id, &ev, NULL, NULL);
        if (!strcmp(ev, "clicked") && id > 0 && id <= s->count) s->fn(id - 1, s->data);
        g_dbus_method_invocation_return_value(inv, NULL);
    } else if (!strcmp(method, "EventGroup")) {
        g_dbus_method_invocation_return_value(inv, g_variant_new("(ai)", NULL));
    } else if (!strcmp(method, "AboutToShow")) {
        s->fn(-2, s->data);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(b)", FALSE));
    } else if (!strcmp(method, "AboutToShowGroup")) {
        s->fn(-2, s->data);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(aiai)", NULL, NULL));
    } else {
        g_dbus_method_invocation_return_value(inv, NULL);
    }
}

static GVariant *menu_get(GDBusConnection *c, const char *sender, const char *path, const char *iface,
                          const char *prop, GError **err, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)err; (void)data;
    if (!strcmp(prop, "Version")) return g_variant_new_uint32(3);
    if (!strcmp(prop, "TextDirection")) return g_variant_new_string("ltr");
    if (!strcmp(prop, "Status")) return g_variant_new_string("normal");
    return NULL;
}

static const GDBusInterfaceVTable sni_vtable = { sni_call, sni_get, NULL, { 0 } };
static const GDBusInterfaceVTable menu_vtable = { menu_call, menu_get, NULL, { 0 } };

RunwayStatusItem *runway_status_item_new(const char *id, const char *title, const char *icon_name, const char *tooltip,
                                         RunwayStatusFunc fn, void *user_data) {
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!bus) return NULL;
    // Is there a tray to show it?
    GVariant *owner = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                                  "NameHasOwner", g_variant_new("(s)", "org.kde.StatusNotifierWatcher"),
                                                  G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 500, NULL, NULL);
    gboolean has = FALSE;
    if (owner) { g_variant_get(owner, "(b)", &has); g_variant_unref(owner); }
    if (!has) { g_object_unref(bus); return NULL; }

    static int counter = 0;
    RunwayStatusItem *s = g_new0(RunwayStatusItem, 1);
    s->bus = bus;
    s->id = g_strdup(id); s->title = g_strdup(title); s->icon = g_strdup(icon_name); s->tooltip = g_strdup(tooltip ? tooltip : "");
    s->visible = TRUE;
    s->fn = fn; s->data = user_data;
    s->revision = 1;
    s->bus_name = g_strdup_printf("org.kde.StatusNotifierItem-%d-%d", (int)getpid(), ++counter);

    GDBusNodeInfo *sni = g_dbus_node_info_new_for_xml(sni_xml, NULL);
    GDBusNodeInfo *menu = g_dbus_node_info_new_for_xml(menu_xml, NULL);
    s->item_reg = g_dbus_connection_register_object(bus, "/StatusNotifierItem", sni->interfaces[0], &sni_vtable, s, NULL, NULL);
    s->menu_reg = g_dbus_connection_register_object(bus, "/MenuBar", menu->interfaces[0], &menu_vtable, s, NULL, NULL);
    g_dbus_node_info_unref(sni);
    g_dbus_node_info_unref(menu);
    s->name_id = g_bus_own_name_on_connection(bus, s->bus_name, G_BUS_NAME_OWNER_FLAGS_NONE, NULL, NULL, NULL, NULL);
    g_dbus_connection_call(bus, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                           "RegisterStatusNotifierItem", g_variant_new("(s)", s->bus_name), NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
    return s;
}

static void emit(RunwayStatusItem *s, const char *path, const char *iface, const char *sig, GVariant *args) {
    g_dbus_connection_emit_signal(s->bus, NULL, path, iface, sig, args, NULL);
}

void runway_status_item_set(RunwayStatusItem *s, const char *title, const char *icon_name, const char *tooltip, gboolean visible) {
    if (!s) return;
    g_free(s->title); s->title = g_strdup(title);
    g_free(s->icon); s->icon = g_strdup(icon_name);
    g_free(s->tooltip); s->tooltip = g_strdup(tooltip ? tooltip : "");
    gboolean status = s->visible != visible;
    s->visible = visible;
    emit(s, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewTitle", NULL);
    emit(s, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewIcon", NULL);
    emit(s, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewToolTip", NULL);
    if (status) emit(s, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewStatus", g_variant_new("(s)", visible ? "Active" : "Passive"));
}

void runway_status_item_set_menu(RunwayStatusItem *s, const char *const *titles, const int *kinds,
                                 const gboolean *enabled, const gboolean *checked, int count) {
    if (!s) return;
    for (int i = 0; i < s->count; i++) g_free(s->items[i].title);
    g_free(s->items);
    s->items = g_new0(SIItem, count > 0 ? count : 1);
    s->count = count;
    int stack[16]; int depth = 0; stack[0] = 0;
    for (int i = 0; i < count; i++) {
        s->items[i].title = g_strdup(titles[i]);
        s->items[i].kind = kinds[i];
        s->items[i].enabled = enabled[i];
        s->items[i].checked = checked[i];
        s->items[i].parent = stack[depth];
        if (kinds[i] == 2 && depth < 15) stack[++depth] = i + 1;
        if (kinds[i] == 3 && depth > 0) depth--;
    }
    s->revision++;
    emit(s, "/MenuBar", "com.canonical.dbusmenu", "LayoutUpdated", g_variant_new("(ui)", s->revision, 0));
}

void runway_status_item_free(RunwayStatusItem *s) {
    if (!s) return;
    g_bus_unown_name(s->name_id);
    g_dbus_connection_unregister_object(s->bus, s->item_reg);
    g_dbus_connection_unregister_object(s->bus, s->menu_reg);
    for (int i = 0; i < s->count; i++) g_free(s->items[i].title);
    g_free(s->items);
    g_free(s->id); g_free(s->title); g_free(s->icon); g_free(s->tooltip); g_free(s->bus_name);
    g_object_unref(s->bus);
    g_free(s);
}

gboolean runway_is_popover(GtkWidget *w) { return GTK_IS_POPOVER(w); }
#endif
