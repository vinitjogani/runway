// Shared state of the drawn backend's GTK binding: the flat C API of
// runway_drawn.h over GTK 4, Cairo and Pango, so the drawn backend's Swift
// half (the widget tree, the Mac-style painter, input routing, AppKit's
// view system) runs unchanged on Linux. Linux only.
#ifndef RW_GTK_H
#define RW_GTK_H
#if defined(__linux__) || defined(__FreeBSD__)

#include <gtk/gtk.h>
#include <pango/pangocairo.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include "runway_drawn.h"

typedef struct {
    rw_event_fn callback;
    GMainLoop *loop;
    char *ui_family;              // the UI font (NULL: GTK's)
    gboolean dark;
} RwGtk;
extern RwGtk rwg;

int rwg_send_event(rw_event *ev);
int rwg_send(int type, void *ctx);
unsigned rwg_mods(GdkModifierType s);
/// Runs the main context until *done (dialogs and menus that answer synchronously).
void rwg_wait(volatile int *done);

/// The paint (fill or stroke source) of a drawing pass.
typedef struct {
    int kind;                     // 0 colour, 1 pattern
    rw_color color;
    cairo_pattern_t *pattern;
} RwPaint;

struct rw_window {
    GtkWidget *window;            // GtkWindow, or GtkPopover for a popup
    GtkWidget *box;               // vertical: menu bar, then the overlay
    GtkWidget *overlay;
    GtkWidget *area;              // the drawing area: paint and input
    GtkWidget *fixed;             // native children (text inputs), over the area
    GtkWidget *menubar;
    GSimpleActionGroup *menu_actions;
    void *ctx;
    struct rw_window *parent;
    gboolean popup, modal, destroyed, closing;
    double width, height;         // content size (the drawing area's)
    guint timer;
    double pointer_x, pointer_y;  // last pointer position in the area
    guint32 last_time;
    GdkCursor *cursor;
    GtkDropTarget *drop;
    double popup_x, popup_y;      // where a popup's content sits in its owner

    // A drawing pass.
    cairo_t *cr;
    cairo_matrix_t base;          // the pass's starting matrix
    double offset_x, offset_y;
    cairo_matrix_t transform;     // set_transform's matrix (before the offset)
    gboolean has_transform;
    float alpha;
    RwPaint paint;
    double *dashes;
    int dash_count;
    gboolean round_caps;
    int clip_depth;
};

/// Applies the pass's current transform (offset and any set_transform).
void rwg_apply_matrix(rw_window *w);
/// A drawing surface over a Cairo context that GTK hands a native child.
void rwg_begin_surface(rw_window *s, cairo_t *cr);
void rwg_end_surface(rw_window *s);

// Native children placed over the drawing area, clipped to a rect.
GtkWidget *rwg_clipper_new(rw_window *w);
void rwg_clipper_place(rw_window *w, GtkWidget *clipper, GtkWidget *child, double x, double y, double width, double height,
                       double cx, double cy, double cw, double ch, int visible);

/// Offers a press or release in a native child to the window first
/// (AppKit's local monitors); TRUE when it was taken.
gboolean rwg_child_pointer(rw_window *w, GtkWidget *child, double x, double y, int button, gboolean release, gboolean after);

/// Windows virtual-key codes for GDK keyvals (what the Swift half's key
/// names come from), and the Mac-style characters a key types.
int rwg_vk(guint keyval);
/// Whether a native text input in `w` has keyboard focus.
gboolean rwg_native_text_focus(rw_window *w);

/// Converts between UTF-16 offsets and character offsets of a UTF-8 string.
int rwg_utf16_to_chars(const char *s, int utf16);
int rwg_chars_to_utf16(const char *s, int chars);

#endif
#endif
