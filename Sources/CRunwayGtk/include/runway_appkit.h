#if defined(__linux__) || defined(__FreeBSD__)
// GTK helpers for Runway's AppKit view system: raw input for a window (AppKit
// hit-tests and dispatches it), drops, the menu bar and context menus.
#ifndef RUNWAY_APPKIT_H
#define RUNWAY_APPKIT_H
#include <gtk/gtk.h>

G_BEGIN_DECLS

enum {
    RUNWAY_EV_DOWN = 0, RUNWAY_EV_UP = 1, RUNWAY_EV_MOTION = 2, RUNWAY_EV_SCROLL = 3,
    RUNWAY_EV_ENTER = 4, RUNWAY_EV_LEAVE = 5, RUNWAY_EV_KEY_DOWN = 6, RUNWAY_EV_KEY_UP = 7, RUNWAY_EV_FLAGS = 8,
};

/// Modifier bits: 1 shift, 2 control, 4 alt, 8 super, 16 caps lock.
typedef struct {
    int kind;
    int button;          /* 0 left, 1 right, 2 middle */
    double x, y;         /* content widget coordinates */
    unsigned modifiers;
    double time;         /* seconds */
    double dx, dy;       /* scroll: positive dy scrolls content down */
    int precise;
    unsigned keyval, keycode;
    const char *keyname;
    const char *chars;
    int is_repeat;
} RunwayAppKitEvent;

typedef gboolean (*RunwayAppKitEventFunc)(const RunwayAppKitEvent *e, void *data);
typedef void (*RunwayBoolFunc)(gboolean value, void *data);
/// kind: 0 enter, 1 motion, 2 leave, 3 drop. Returns NSDragOperation bits (1 copy, 2 link, 16 move).
typedef int (*RunwayDropFunc)(int kind, double x, double y, const char *uris, const char *text, void *data);

/// Mouse, scroll and crossing events on `content` (bubble phase, after
/// native widgets), keys on `window` (capture phase, before them).
/// `notify` releases `data` when the window goes.
void runway_appkit_install_events(GtkWidget *window, GtkWidget *content, RunwayAppKitEventFunc fn, void *data, GDestroyNotify notify);
/// Starts an interactive move of the window (as dragging its title bar),
/// from a press of `button` (1-based) at (x, y) in the window's surface.
void runway_appkit_begin_move(GtkWidget *window, int button, double x, double y, guint32 timestamp);
/// Calls `fn` when the window becomes or stops being the active one.
void runway_appkit_install_activation(GtkWidget *window, RunwayBoolFunc fn, void *data, GDestroyNotify notify);
/// File and text drops on `content`.
void runway_appkit_install_drop(GtkWidget *content, RunwayDropFunc fn, void *data, GDestroyNotify notify);

/// Puts `bar` (a GtkPopoverMenuBar) above the window's child, or removes it (NULL).
void runway_appkit_set_menubar(GtkWidget *window, GtkWidget *bar);
/// Calls `fn` (with TRUE) when the pointer presses on `widget`, before it reacts.
void runway_appkit_on_press(GtkWidget *widget, RunwayBoolFunc fn, void *data, GDestroyNotify notify);
/// Shows `model` as a context menu at (x, y) in `parent`, with `group`'s
/// actions under the "rwc" prefix, and returns when it closes.
void runway_appkit_popup_menu(GtkWidget *parent, GMenuModel *model, GActionGroup *group, double x, double y);

/// An "activate" handler for a GSimpleAction calling fn(index).
typedef void (*RunwayIndexFunc2)(int index, void *data);
void runway_appkit_action_connect(GSimpleAction *action, RunwayIndexFunc2 fn, void *data, int index);

/// Sets a cursor from RGBA8 pixels (NULL pixels: from `name`).
void runway_appkit_set_cursor(GtkWidget *w, const char *name, const unsigned char *rgba, int width, int height, int hot_x, int hot_y);

G_END_DECLS
#endif
#endif
