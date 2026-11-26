// Accessibility for drawn windows on Linux: each element of the tree the
// Swift half sends (rw_window_set_a11y) becomes an invisible, click-through
// widget at the element's frame, with its role, name, description, value
// and states, so GTK exposes it over AT-SPI like any widget. Actions are
// installed widget actions ("a11y.default", "a11y.increment", ...) that
// AT-SPI lists and runs; they come back as RW_EV_A11Y_ACTION. Widgets are
// kept across updates where an element keeps its role.
#if defined(__linux__) || defined(__FreeBSD__)
#include "rw_gtk.h"
#include <gio/gio.h>

#define RW_TYPE_A11Y (rw_a11y_get_type())
G_DECLARE_FINAL_TYPE(RwA11y, rw_a11y, RW, A11Y, GtkWidget)

struct _RwA11y {
    GtkWidget parent;
    rw_window *win;
    int index;
    int role;
    double x, y, width, height;   // window coordinates
    char *name, *value, *hint, *actions;
    unsigned states;
    int has_range;
    double number, minimum, maximum;
};

G_DEFINE_TYPE(RwA11y, rw_a11y, GTK_TYPE_WIDGET)

static const char *const action_names[] = { "default", "increment", "decrement", "escape", "magicTap" };
#define ACTION_COUNT ((int)(sizeof action_names / sizeof *action_names))

/// The position of `name` in a newline-separated list, or -1.
static int action_index(const char *list, const char *name) {
    if (!list) return -1;
    int i = 0;
    size_t n = strlen(name);
    for (const char *p = list; *p; i++) {
        const char *end = strchr(p, '\n');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len == n && strncmp(p, name, n) == 0) return i;
        if (!end) break;
        p = end + 1;
    }
    return -1;
}

static void run_action(GtkWidget *widget, const char *action, GVariant *param) {
    (void)param;
    RwA11y *self = RW_A11Y(widget);
    const char *name = strchr(action, '.') ? strchr(action, '.') + 1 : action;
    int k = action_index(self->actions, name);
    if (k < 0 && strcmp(name, "default") == 0 && self->actions) k = 0;
    if (k < 0 || !self->win) return;
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_A11Y_ACTION;
    ev.ctx = self->win->ctx;
    ev.clicks = self->index;
    ev.key = k;
    rwg_send_event(&ev);
}

static void rw_a11y_measure(GtkWidget *w, GtkOrientation o, int for_size, int *min, int *nat, int *min_base, int *nat_base) {
    (void)w; (void)o; (void)for_size; (void)min_base; (void)nat_base;
    *min = 0; *nat = 0;
}

static void rw_a11y_allocate(GtkWidget *widget, int width, int height, int baseline) {
    (void)width; (void)height; (void)baseline;
    RwA11y *self = RW_A11Y(widget);
    for (GtkWidget *c = gtk_widget_get_first_child(widget); c; c = gtk_widget_get_next_sibling(c)) {
        RwA11y *a = RW_A11Y(c);
        GtkAllocation r = { (int)lround(a->x - self->x), (int)lround(a->y - self->y),
                            MAX(1, (int)lround(a->width)), MAX(1, (int)lround(a->height)) };
        gtk_widget_size_allocate(c, &r, -1);
    }
}

static void rw_a11y_snapshot(GtkWidget *w, GtkSnapshot *s) { (void)w; (void)s; }

static void rw_a11y_dispose(GObject *o) {
    GtkWidget *c;
    while ((c = gtk_widget_get_first_child(GTK_WIDGET(o)))) gtk_widget_unparent(c);
    G_OBJECT_CLASS(rw_a11y_parent_class)->dispose(o);
}

static void rw_a11y_finalize(GObject *o) {
    RwA11y *self = RW_A11Y(o);
    g_free(self->name); g_free(self->value); g_free(self->hint); g_free(self->actions);
    G_OBJECT_CLASS(rw_a11y_parent_class)->finalize(o);
}

static void rw_a11y_class_init(RwA11yClass *klass) {
    GtkWidgetClass *wc = GTK_WIDGET_CLASS(klass);
    wc->measure = rw_a11y_measure;
    wc->size_allocate = rw_a11y_allocate;
    wc->snapshot = rw_a11y_snapshot;
    G_OBJECT_CLASS(klass)->dispose = rw_a11y_dispose;
    G_OBJECT_CLASS(klass)->finalize = rw_a11y_finalize;
    for (int i = 0; i < ACTION_COUNT; i++) {
        char *full = g_strconcat("a11y.", action_names[i], NULL);
        gtk_widget_class_install_action(wc, full, NULL, run_action);
        g_free(full);
    }
}

static void rw_a11y_init(RwA11y *self) {
    gtk_widget_set_can_target(GTK_WIDGET(self), FALSE);
    gtk_widget_set_focusable(GTK_WIDGET(self), FALSE);
    gtk_widget_set_can_focus(GTK_WIDGET(self), FALSE);
}

static GtkAccessibleRole gtk_role(int role, int parent_role) {
    switch (role) {
    case RW_ROLE_BUTTON: case RW_ROLE_MENUBUTTON: case RW_ROLE_COLORWELL: return GTK_ACCESSIBLE_ROLE_BUTTON;
    case RW_ROLE_CHECKBOX: return GTK_ACCESSIBLE_ROLE_CHECKBOX;
    case RW_ROLE_SWITCH: return GTK_ACCESSIBLE_ROLE_SWITCH;
    case RW_ROLE_TEXT: return GTK_ACCESSIBLE_ROLE_LABEL;
    case RW_ROLE_TEXTFIELD: case RW_ROLE_TEXTAREA: return GTK_ACCESSIBLE_ROLE_TEXT_BOX;
    case RW_ROLE_SEARCHFIELD: return GTK_ACCESSIBLE_ROLE_SEARCH_BOX;
    case RW_ROLE_IMAGE: return GTK_ACCESSIBLE_ROLE_IMG;
    case RW_ROLE_LINK: return GTK_ACCESSIBLE_ROLE_LINK;
    case RW_ROLE_SLIDER: return GTK_ACCESSIBLE_ROLE_SLIDER;
    case RW_ROLE_COMBOBOX: return GTK_ACCESSIBLE_ROLE_COMBO_BOX;
    case RW_ROLE_TABLIST: return GTK_ACCESSIBLE_ROLE_TAB_LIST;
    case RW_ROLE_PROGRESS: return GTK_ACCESSIBLE_ROLE_PROGRESS_BAR;
    case RW_ROLE_HEADING: return GTK_ACCESSIBLE_ROLE_HEADING;
    case RW_ROLE_STEPPER: return GTK_ACCESSIBLE_ROLE_SPIN_BUTTON;
    case RW_ROLE_SEPARATOR: return GTK_ACCESSIBLE_ROLE_SEPARATOR;
    case RW_ROLE_TOGGLEBUTTON: return parent_role == RW_ROLE_TABLIST ? GTK_ACCESSIBLE_ROLE_TAB : GTK_ACCESSIBLE_ROLE_TOGGLE_BUTTON;
    default: return GTK_ACCESSIBLE_ROLE_GROUP;
    }
}

static gboolean same(const char *a, const char *b) { return g_strcmp0(a, b) == 0; }

static void set_string(char **slot, const char *v) { if (!same(*slot, v)) { g_free(*slot); *slot = g_strdup(v); } }

/// Brings a widget's accessible properties and states in line with its node.
static void apply(RwA11y *a, const rw_a11y_node *n, gboolean fresh) {
    GtkAccessible *acc = GTK_ACCESSIBLE(a);
    if (fresh || !same(a->name, n->name)) {
        if (n->name && *n->name) gtk_accessible_update_property(acc, GTK_ACCESSIBLE_PROPERTY_LABEL, n->name, -1);
        else gtk_accessible_reset_property(acc, GTK_ACCESSIBLE_PROPERTY_LABEL);
        set_string(&a->name, n->name);
    }
    if (fresh || !same(a->hint, n->hint)) {
        if (n->hint && *n->hint) gtk_accessible_update_property(acc, GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, n->hint, -1);
        else gtk_accessible_reset_property(acc, GTK_ACCESSIBLE_PROPERTY_DESCRIPTION);
        set_string(&a->hint, n->hint);
    }
    gboolean ranged = n->role == RW_ROLE_SLIDER || n->role == RW_ROLE_PROGRESS || n->role == RW_ROLE_STEPPER;
    if (fresh || !same(a->value, n->value) || a->has_range != n->has_range || a->number != n->number
        || a->minimum != n->minimum || a->maximum != n->maximum) {
        if (ranged && n->has_range)
            gtk_accessible_update_property(acc, GTK_ACCESSIBLE_PROPERTY_VALUE_MIN, n->minimum, GTK_ACCESSIBLE_PROPERTY_VALUE_MAX, n->maximum,
                                           GTK_ACCESSIBLE_PROPERTY_VALUE_NOW, n->number, -1);
        if (ranged && n->value) gtk_accessible_update_property(acc, GTK_ACCESSIBLE_PROPERTY_VALUE_TEXT, n->value, -1);
        else if (!ranged && n->value && *n->value && n->role != RW_ROLE_TEXTFIELD && n->role != RW_ROLE_TEXTAREA)
            gtk_accessible_update_property(acc, GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, n->hint && *n->hint ? n->hint : n->value, -1);
        set_string(&a->value, n->value);
        a->has_range = n->has_range; a->number = n->number; a->minimum = n->minimum; a->maximum = n->maximum;
    }
    if (fresh || a->states != n->states) {
        unsigned s = n->states;
        gtk_accessible_update_state(acc, GTK_ACCESSIBLE_STATE_DISABLED, (s & RW_STATE_DISABLED) != 0, -1);
        if (s & RW_STATE_CHECKABLE) {
            int v = (s & RW_STATE_MIXED) ? GTK_ACCESSIBLE_TRISTATE_MIXED : (s & RW_STATE_CHECKED) ? GTK_ACCESSIBLE_TRISTATE_TRUE : GTK_ACCESSIBLE_TRISTATE_FALSE;
            if (n->role == RW_ROLE_TOGGLEBUTTON) gtk_accessible_update_state(acc, GTK_ACCESSIBLE_STATE_PRESSED, v, -1);
            else gtk_accessible_update_state(acc, GTK_ACCESSIBLE_STATE_CHECKED, v, -1);
        }
        gtk_accessible_update_state(acc, GTK_ACCESSIBLE_STATE_SELECTED, (s & RW_STATE_SELECTED) != 0, -1);
        if (n->role == RW_ROLE_TEXTFIELD || n->role == RW_ROLE_TEXTAREA || n->role == RW_ROLE_SEARCHFIELD)
            gtk_accessible_update_property(acc, GTK_ACCESSIBLE_PROPERTY_MULTI_LINE, (s & RW_STATE_MULTILINE) != 0,
                                           GTK_ACCESSIBLE_PROPERTY_READ_ONLY, (s & RW_STATE_EDITABLE) == 0, -1);
        if (n->role == RW_ROLE_MENUBUTTON || n->role == RW_ROLE_COMBOBOX)
            gtk_accessible_update_property(acc, GTK_ACCESSIBLE_PROPERTY_HAS_POPUP, TRUE, -1);
        if (s & RW_STATE_MODAL) gtk_accessible_update_property(acc, GTK_ACCESSIBLE_PROPERTY_MODAL, TRUE, -1);
        a->states = n->states;
    }
    if (fresh || !same(a->actions, n->actions)) {
        set_string(&a->actions, n->actions);
        for (int i = 0; i < ACTION_COUNT; i++) {
            char *full = g_strconcat("a11y.", action_names[i], NULL);
            gtk_widget_action_set_enabled(GTK_WIDGET(a), full, action_index(n->actions, action_names[i]) >= 0);
            g_free(full);
        }
    }
    a->x = n->x; a->y = n->y; a->width = n->width; a->height = n->height;
}

static RwA11y *make(rw_window *w, const rw_a11y_node *n, int parent_role) {
    RwA11y *a = g_object_new(RW_TYPE_A11Y, "accessible-role", gtk_role(n->role, parent_role), NULL);
    a->win = w;
    a->role = n->role;
    apply(a, n, TRUE);
    return a;
}

typedef struct { int *items; int count, capacity; } IntList;
static void push(IntList *l, int v) {
    if (l->count == l->capacity) { l->capacity = l->capacity ? l->capacity * 2 : 4; l->items = g_renew(int, l->items, l->capacity); }
    l->items[l->count++] = v;
}

/// Makes `widget`'s children match node `index`'s, reusing widgets that keep their role.
static void sync_children(rw_window *w, GtkWidget *widget, int index, const rw_a11y_node *nodes, IntList *kids) {
    RwA11y *self = RW_A11Y(widget);
    self->index = index;
    GtkWidget *existing = gtk_widget_get_first_child(widget);
    IntList *mine = &kids[index];
    for (int k = 0; k < mine->count; k++) {
        int c = mine->items[k];
        const rw_a11y_node *n = &nodes[c];
        GtkWidget *child;
        if (existing && RW_A11Y(existing)->role == n->role) {
            child = existing;
            existing = gtk_widget_get_next_sibling(existing);
            apply(RW_A11Y(child), n, FALSE);
        } else {
            child = GTK_WIDGET(make(w, n, nodes[index].role));
            gtk_widget_insert_before(child, widget, existing);
            if (existing) {
                // A different element took this place: drop the old one.
                GtkWidget *next = gtk_widget_get_next_sibling(existing);
                gtk_widget_unparent(existing);
                existing = next;
            }
        }
        sync_children(w, child, c, nodes, kids);
    }
    while (existing) {
        GtkWidget *next = gtk_widget_get_next_sibling(existing);
        gtk_widget_unparent(existing);
        existing = next;
    }
    gtk_widget_queue_allocate(widget);
}

void rw_window_set_a11y(rw_window *w, const rw_a11y_node *nodes, int count) {
    if (!w || !w->overlay || count <= 0) return;
    if (!w->a11y_root) {
        w->a11y_root = GTK_WIDGET(make(w, &nodes[0], -1));
        gtk_overlay_add_overlay(GTK_OVERLAY(w->overlay), w->a11y_root);
        gtk_overlay_set_measure_overlay(GTK_OVERLAY(w->overlay), w->a11y_root, FALSE);
    } else {
        apply(RW_A11Y(w->a11y_root), &nodes[0], FALSE);
    }
    IntList *kids = g_new0(IntList, count);
    for (int i = 1; i < count; i++) if (nodes[i].parent >= 0 && nodes[i].parent < i) push(&kids[nodes[i].parent], i);
    sync_children(w, w->a11y_root, 0, nodes, kids);
    for (int i = 0; i < count; i++) g_free(kids[i].items);
    g_free(kids);
}

void rw_set_app_name(const char *name) {
    if (!name || !*name) return;
    g_set_application_name(name);
    if (!g_get_prgname()) g_set_prgname(name);
}

/// Whether an accessibility bus is running in this session (what assistive
/// technologies listen on). RUNWAY_A11Y=0 turns the tree off, =1 forces it.
int rw_window_a11y_wanted(rw_window *w) {
    (void)w;
    static int known = -1;
    if (known >= 0) return known;
    const char *env = g_getenv("RUNWAY_A11Y");
    if (env) return known = env[0] != '0';
    if (g_getenv("NO_AT_BRIDGE") && strcmp(g_getenv("NO_AT_BRIDGE"), "1") == 0) return known = 0;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!bus) return known = 0;
    GVariant *r = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                                              g_variant_new("(s)", "org.a11y.Bus"), G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 500, NULL, NULL);
    gboolean has = FALSE;
    if (r) { g_variant_get(r, "(b)", &has); g_variant_unref(r); }
    g_object_unref(bus);
    return known = has ? 1 : 0;
}
#endif
