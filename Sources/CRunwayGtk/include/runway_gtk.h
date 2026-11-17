#if defined(__linux__) || defined(__FreeBSD__)
// RunwayCanvas: a GTK 4 container that places each child at an exact frame
// computed by Runway's (SwiftUI-semantics) layout engine. GTK's own boxes
// would apply GTK layout rules; SwiftUI code expects SwiftUI's.
#ifndef RUNWAY_GTK_H
#define RUNWAY_GTK_H
#include <gtk/gtk.h>

G_BEGIN_DECLS

typedef void (*RunwayResizeFunc)(int width, int height, void *user_data);
typedef void (*RunwayVoidFunc)(void *user_data);

GtkWidget *runway_canvas_new(void);
/// The Mac's activity indicator: 12 steps a second while mapped, no frame clock.
GtkWidget *runway_spinner_new(void);
/// The size the canvas asks for (its content's size). -1 keeps GTK's minimum.
void runway_canvas_set_content_size(GtkWidget *canvas, int width, int height);
/// A pass-through canvas takes no pointer input itself, only its children
/// do: what's under its empty parts gets the clicks (a toolbar over
/// full-size content).
void runway_canvas_set_pass_through(GtkWidget *canvas, int pass);
/// The smallest the canvas may be made (-1, -1: its content size): a
/// window's content, so the window can be resized smaller than it opened.
void runway_canvas_set_min_size(GtkWidget *canvas, int width, int height);
/// Adds `child` if needed and places it; children are drawn in the order placed.
void runway_canvas_place(GtkWidget *canvas, GtkWidget *child, int x, int y, int width, int height);
/// Moves `child` to the top of the drawing order.
void runway_canvas_raise(GtkWidget *canvas, GtkWidget *child);
void runway_canvas_remove(GtkWidget *canvas, GtkWidget *child);
void runway_canvas_set_resize_callback(GtkWidget *canvas, RunwayResizeFunc fn, void *user_data);
void runway_canvas_set_clip(GtkWidget *canvas, gboolean clip);

/// Signal helpers: GTK's g_signal_connect is a macro Swift can't import.
gulong runway_connect(gpointer instance, const char *signal, GCallback cb, gpointer data);
/// Run `fn` once on the main loop when idle.
void runway_idle(RunwayVoidFunc fn, void *user_data);
/// Opacity and CSS classes, so Swift needn't cast GObject types.
void runway_widget_add_css(GtkWidget *w, const char *css_class);
void runway_widget_remove_css(GtkWidget *w, const char *css_class);
/// Loads app-wide CSS once (the Flight-ish defaults Runway uses for forms).
void runway_install_css(const char *css);

/// Sets a string-valued GtkSettings property (font name, decoration layout).
void runway_settings_set_string(const char *property, const char *value);
/// Turns off the arrow on a menu button's or drop-down's popovers.
void runway_popovers_plain(GtkWidget *w);

/// Light or dark: GTK settings, GTK_THEME, or the desktop's colour-scheme.
gboolean runway_prefers_dark(void);

/// Clipboard. Reading waits for GTK's async read (with a timeout).
void runway_clipboard_set_text(const char *text);
void runway_clipboard_set_uris(const char *uri_list, const char *plain);
char *runway_clipboard_get_text(void);   /* g_free() the result */

/// Opens a URI with its default handler (GIO).
gboolean runway_open_uri(const char *uri);
/// Shows files in the file manager (org.freedesktop.FileManager1), or
/// opens the first one's folder.
void runway_reveal_uris(const char *const *uris);
void runway_beep(void);

/// Modal dialogs, run to completion. Results are newline-separated paths;
/// NULL when cancelled. g_free() them.
char *runway_choose_files(GtkWindow *parent, const char *title, gboolean multiple, gboolean folders, const char *const *extensions);
char *runway_choose_save(GtkWindow *parent, const char *title, const char *suggested);
int runway_alert(GtkWindow *parent, const char *title, const char *message, const char *const *buttons, int cancel_index, int default_index);

/// Menus: a GMenu with actions "rw.<n>", callbacks by index.
typedef void (*RunwayIndexFunc)(int index, void *user_data);
void runway_menu_button_set(GtkWidget *menu_button, const char *const *titles, const int *kinds, const int *depths,
                            const gboolean *enabled, const gboolean *checked, int count, RunwayIndexFunc fn, void *user_data);

/// Window helpers.
void runway_window_set_child(GtkWidget *window, GtkWidget *child);
GtkWidget *runway_drop_down_new(void);
/// Pop-up menu rows with a leading checkmark column (the Mac look).
void runway_drop_down_mac_menu(GtkWidget *dd);
void runway_drop_down_set_strings(GtkWidget *dd, const char *const *strings);

/// Renders a widget (a window) to a PNG through GSK; for screenshots.
gboolean runway_widget_save_png(GtkWidget *w, const char *path);
/// Opens the `index`th drop-down or menu button under `root` and returns
/// its popover (screenshots of menus).
GtkWidget *runway_debug_popup(GtkWidget *root, int index);
/// Runs `fn` once after `ms` milliseconds.
void runway_timeout(unsigned ms, RunwayVoidFunc fn, void *user_data);

/// Hooks Swift's main-thread machinery into the GLib loop: the main dispatch
/// queue (MainActor) and RunLoop.main timers. `next_timer` fires due timers and
/// returns ms until the next one (-1: none).
typedef int (*RunwayTimerFunc)(void *user_data);
void runway_loop_attach(RunwayTimerFunc next_timer, void *user_data);

// SF Symbols drawn from SVG in the widget's foreground colour (runway_symbol.c).
G_DECLARE_FINAL_TYPE(RunwaySymbol, runway_symbol, RUNWAY, SYMBOL, GObject)
GdkPaintable *runway_symbol_new(const char *svg, int size);
GtkWidget *runway_symbol_image(const char *svg, int size);

// The global menu bar over D-Bus (runway_appmenu.c).
typedef struct _RunwayAppMenu RunwayAppMenu;
typedef void (*RunwayAppMenuHostFunc)(gboolean present, void *data);
typedef void (*RunwayAppMenuShowFunc)(void *data);
RunwayAppMenu *runway_appmenu_new(GtkWidget *window, RunwayAppMenuHostFunc on_host, RunwayAppMenuShowFunc on_show, void *data);
void runway_appmenu_set(RunwayAppMenu *m, GMenuModel *model, GActionGroup *group, const char *prefix);
void runway_appmenu_changed(RunwayAppMenu *m);
gboolean runway_appmenu_has_host(RunwayAppMenu *m);
void runway_appmenu_free(RunwayAppMenu *m);

G_END_DECLS
#endif
#endif
