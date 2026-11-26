// Desktop services for the drawn backend on GTK: the clipboard, opening
// and revealing files, sounds, file and colour dialogs, message boxes and
// tray items. The calls answer synchronously, so the async GTK dialogs run
// the main context until they finish.
#if defined(__linux__) || defined(__FreeBSD__)
#include "rw_gtk.h"
#include "runway_controls.h"

static GtkWindow *owner_window(rw_window *w) {
    if (!w) return NULL;
    if (w->popup && w->parent) return owner_window(w->parent);
    return w->window && GTK_IS_WINDOW(w->window) ? GTK_WINDOW(w->window) : NULL;
}

// MARK: Colour

typedef struct { volatile int done; GdkRGBA rgba; gboolean ok; } ColorWait;

static void color_done(GObject *src, GAsyncResult *res, gpointer data) {
    ColorWait *c = data;
    GdkRGBA *r = gtk_color_dialog_choose_rgba_finish(GTK_COLOR_DIALOG(src), res, NULL);
    if (r) { c->rgba = *r; c->ok = TRUE; gdk_rgba_free(r); }
    c->done = 1;
}

int rw_choose_color(rw_window *owner, rw_color initial, rw_color *result) {
    GtkColorDialog *d = gtk_color_dialog_new();
    gtk_color_dialog_set_with_alpha(d, TRUE);
    ColorWait c = {0};
    GdkRGBA start = {initial.r, initial.g, initial.b, initial.a};
    gtk_color_dialog_choose_rgba(d, owner_window(owner), &start, NULL, color_done, &c);
    rwg_wait(&c.done);
    g_object_unref(d);
    if (!c.ok) return 0;
    *result = (rw_color){c.rgba.red, c.rgba.green, c.rgba.blue, c.rgba.alpha};
    return 1;
}

// MARK: Clipboard

static GdkClipboard *clipboard(void) { return gdk_display_get_clipboard(gdk_display_get_default()); }

void rw_clipboard_set_text(const char *text) { gdk_clipboard_set_text(clipboard(), text ? text : ""); }

void rw_clipboard_set_files(const char *const *paths, int count) {
    GSList *files = NULL;
    for (int i = count - 1; i >= 0; i--) files = g_slist_prepend(files, g_file_new_for_path(paths[i]));
    GdkFileList *list = gdk_file_list_new_from_list(files);
    GValue v = G_VALUE_INIT;
    g_value_init(&v, GDK_TYPE_FILE_LIST);
    g_value_take_boxed(&v, list);
    gdk_clipboard_set_value(clipboard(), &v);
    g_value_unset(&v);
    g_slist_free_full(files, g_object_unref);
}

typedef struct { volatile int done; char *text; } TextWait;

static void text_done(GObject *src, GAsyncResult *res, gpointer data) {
    TextWait *t = data;
    t->text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(src), res, NULL);
    t->done = 1;
}

char *rw_clipboard_get_text(void) {
    TextWait t = {0};
    gdk_clipboard_read_text_async(clipboard(), NULL, text_done, &t);
    rwg_wait(&t.done);
    if (!t.text) return NULL;
    char *out = strdup(t.text);
    g_free(t.text);
    return out;
}

// MARK: The shell

int rw_shell_open(const char *target) {
    if (!target || !*target) return 0;
    char *uri = g_uri_peek_scheme(target) ? g_strdup(target) : g_filename_to_uri(target, NULL, NULL);
    if (!uri) return 0;
    gboolean ok = g_app_info_launch_default_for_uri(uri, NULL, NULL);
    g_free(uri);
    return ok ? 1 : 0;
}

void rw_reveal(const char *const *paths, int count) {
    if (count <= 0) return;
    // The file manager's ShowItems, else the first item's folder.
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (bus) {
        GVariantBuilder b;
        g_variant_builder_init(&b, G_VARIANT_TYPE("as"));
        for (int i = 0; i < count; i++) {
            char *u = g_filename_to_uri(paths[i], NULL, NULL);
            if (u) { g_variant_builder_add(&b, "s", u); g_free(u); }
        }
        GVariant *r = g_dbus_connection_call_sync(bus, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
                                                  "org.freedesktop.FileManager1", "ShowItems", g_variant_new("(ass)", &b, ""),
                                                  NULL, G_DBUS_CALL_FLAGS_NONE, 2000, NULL, NULL);
        g_object_unref(bus);
        if (r) { g_variant_unref(r); return; }
    }
    char *dir = g_path_get_dirname(paths[0]);
    rw_shell_open(dir);
    g_free(dir);
}

// MARK: Sounds

int rw_play_sound(const char *name) {
    // Windows event names (what the Swift half maps Mac sounds to) → the
    // freedesktop sound theme's.
    static const char *const map[][2] = {
        {"SystemAsterisk", "dialog-information"}, {"Notification.Default", "message-new-instant"},
        {"Notification.IM", "message-new-instant"}, {"Notification.Reminder", "alarm-clock-elapsed"},
        {"SystemExclamation", "dialog-warning"}, {"SystemHand", "dialog-error"}, {".Default", "bell"},
    };
    const char *id = name;
    for (size_t i = 0; i < sizeof map / sizeof map[0]; i++) if (!strcmp(name, map[i][0])) id = map[i][1];
    char *player = g_find_program_in_path("canberra-gtk-play");
    if (player) {
        char *argv[] = {player, "-i", (char *)id, NULL};
        gboolean ok = g_spawn_async(NULL, argv, NULL, G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL, NULL, NULL, NULL, NULL);
        g_free(player);
        if (ok) return 1;
    }
    char *path = g_strdup_printf("/usr/share/sounds/freedesktop/stereo/%s.oga", id);
    char *paplay = g_file_test(path, G_FILE_TEST_EXISTS) ? g_find_program_in_path("paplay") : NULL;
    gboolean ok = FALSE;
    if (paplay) {
        char *argv[] = {paplay, path, NULL};
        ok = g_spawn_async(NULL, argv, NULL, G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL, NULL, NULL, NULL, NULL);
        g_free(paplay);
    }
    g_free(path);
    return ok ? 1 : 0;
}

void rw_beep(void) { gdk_display_beep(gdk_display_get_default()); }

// MARK: File dialogs

typedef struct { volatile int done; GListModel *files; GFile *file; } FileWait;

static void open_done(GObject *src, GAsyncResult *res, gpointer data) {
    FileWait *f = data;
    f->file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(src), res, NULL);
    f->done = 1;
}
static void open_many_done(GObject *src, GAsyncResult *res, gpointer data) {
    FileWait *f = data;
    f->files = gtk_file_dialog_open_multiple_finish(GTK_FILE_DIALOG(src), res, NULL);
    f->done = 1;
}
static void folder_done(GObject *src, GAsyncResult *res, gpointer data) {
    FileWait *f = data;
    f->file = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(src), res, NULL);
    f->done = 1;
}
static void folders_done(GObject *src, GAsyncResult *res, gpointer data) {
    FileWait *f = data;
    f->files = gtk_file_dialog_select_multiple_folders_finish(GTK_FILE_DIALOG(src), res, NULL);
    f->done = 1;
}
static void save_done(GObject *src, GAsyncResult *res, gpointer data) {
    FileWait *f = data;
    f->file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(src), res, NULL);
    f->done = 1;
}

static char *paths_of(FileWait *f) {
    GString *s = g_string_new(NULL);
    if (f->file) {
        char *p = g_file_get_path(f->file);
        if (p) { g_string_append(s, p); g_free(p); }
        g_object_unref(f->file);
    }
    if (f->files) {
        guint n = g_list_model_get_n_items(f->files);
        for (guint i = 0; i < n; i++) {
            GFile *file = g_list_model_get_item(f->files, i);
            char *p = g_file_get_path(file);
            if (p) { if (s->len) g_string_append_c(s, '\n'); g_string_append(s, p); g_free(p); }
            g_object_unref(file);
        }
        g_object_unref(f->files);
    }
    if (!s->len) { g_string_free(s, TRUE); return NULL; }
    char *out = strdup(s->str);
    g_string_free(s, TRUE);
    return out;
}

char *rw_choose_files(rw_window *owner, const char *title, int multiple, int directories, const char *const *extensions, int count) {
    GtkFileDialog *d = gtk_file_dialog_new();
    if (title && *title) gtk_file_dialog_set_title(d, title);
    if (count > 0 && !directories) {
        GtkFileFilter *filter = gtk_file_filter_new();
        for (int i = 0; i < count; i++) {
            char *pattern = g_strdup_printf("*.%s", extensions[i]);
            gtk_file_filter_add_pattern(filter, pattern);
            g_free(pattern);
        }
        GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
        g_list_store_append(filters, filter);
        gtk_file_dialog_set_filters(d, G_LIST_MODEL(filters));
        g_object_unref(filters);
        g_object_unref(filter);
    }
    FileWait f = {0};
    GtkWindow *parent = owner_window(owner);
    if (directories) {
        if (multiple) gtk_file_dialog_select_multiple_folders(d, parent, NULL, folders_done, &f);
        else gtk_file_dialog_select_folder(d, parent, NULL, folder_done, &f);
    } else if (multiple) {
        gtk_file_dialog_open_multiple(d, parent, NULL, open_many_done, &f);
    } else {
        gtk_file_dialog_open(d, parent, NULL, open_done, &f);
    }
    rwg_wait(&f.done);
    g_object_unref(d);
    return paths_of(&f);
}

char *rw_choose_save(rw_window *owner, const char *title, const char *suggested) {
    GtkFileDialog *d = gtk_file_dialog_new();
    if (title && *title) gtk_file_dialog_set_title(d, title);
    if (suggested && *suggested) gtk_file_dialog_set_initial_name(d, suggested);
    FileWait f = {0};
    gtk_file_dialog_save(d, owner_window(owner), NULL, save_done, &f);
    rwg_wait(&f.done);
    g_object_unref(d);
    return paths_of(&f);
}

// MARK: Message boxes

typedef struct { volatile int done; int button; } AlertWait;

static void alert_done(GObject *src, GAsyncResult *res, gpointer data) {
    AlertWait *a = data;
    a->button = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(src), res, NULL);
    a->done = 1;
}

int rw_message_box(rw_window *owner, const char *title, const char *message, int ok_cancel) {
    GtkAlertDialog *d = gtk_alert_dialog_new("%s", title ? title : "");
    gtk_alert_dialog_set_detail(d, message ? message : "");
    const char *ok[] = {"OK", NULL}, *both[] = {"Cancel", "OK", NULL};
    gtk_alert_dialog_set_buttons(d, ok_cancel ? both : ok);
    gtk_alert_dialog_set_cancel_button(d, 0);
    gtk_alert_dialog_set_default_button(d, ok_cancel ? 1 : 0);
    AlertWait a = {0, -1};
    gtk_alert_dialog_choose(d, owner_window(owner), NULL, alert_done, &a);
    rwg_wait(&a.done);
    g_object_unref(d);
    // As Win32's MessageBox answers: 1 OK, 0 cancelled.
    return ok_cancel ? (a.button == 1 ? 1 : 0) : 1;
}

// MARK: Tray items

struct rw_tray {
    RunwayStatusItem *item;
    void *ctx;
    char *tooltip;
};

static void tray_event(int index, void *data) {
    rw_tray *t = data;
    if (index != -1) return;   // a click (the menu is the Swift half's)
    rw_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = RW_EV_TRAY;
    ev.ctx = t->ctx;
    rwg_send_event(&ev);
}

rw_tray *rw_tray_create(const char *tooltip, void *ctx) {
    rw_tray *t = g_new0(rw_tray, 1);
    t->ctx = ctx;
    t->tooltip = g_strdup(tooltip ? tooltip : "");
    static int next = 0;
    char *id = g_strdup_printf("runway-%d-%d", (int)getpid(), ++next);
    const char *icon = g_get_prgname() ? g_get_prgname() : "application-x-executable";
    t->item = runway_status_item_new(id, t->tooltip, icon, t->tooltip, tray_event, t);
    g_free(id);
    if (!t->item) { g_free(t->tooltip); g_free(t); return NULL; }
    return t;
}

void rw_tray_update(rw_tray *t, const char *tooltip, int visible) {
    if (!t) return;
    const char *icon = g_get_prgname() ? g_get_prgname() : "application-x-executable";
    runway_status_item_set(t->item, tooltip ? tooltip : "", icon, tooltip ? tooltip : "", visible != 0);
}

void rw_tray_destroy(rw_tray *t) {
    if (!t) return;
    runway_status_item_free(t->item);
    g_free(t->tooltip);
    g_free(t);
}

#endif
