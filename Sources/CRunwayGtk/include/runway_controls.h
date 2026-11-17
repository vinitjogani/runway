#if defined(__linux__) || defined(__FreeBSD__)
// Helpers for Runway's AppKit controls on GTK 4: text tags (GObject
// property varargs Swift can't call), text measuring, pop-up menus at a
// point, and a system tray item over D-Bus (StatusNotifierItem with a
// com.canonical.dbusmenu menu).
#ifndef RUNWAY_CONTROLS_H
#define RUNWAY_CONTROLS_H
#include <gtk/gtk.h>

G_BEGIN_DECLS

/// A text tag with the given attributes; NULL/negative values are unset.
/// `font` is a Pango font description; colours are "#rrggbbaa".
/// justification: 0 left, 1 right, 2 center, 3 fill, -1 unset.
GtkTextTag *runway_text_tag_new(GtkTextBuffer *buffer, const char *font, const char *fg, const char *bg,
                                gboolean underline, gboolean strike, int rise_pango, double letter_spacing_pango,
                                int justification, int left_margin, int indent, int right_margin,
                                int pixels_above, int pixels_below, int pixels_inside);

/// The height of Pango markup laid out at `width` (pixels) in `widget`'s font context.
int runway_markup_height(GtkWidget *widget, const char *markup, int width, gboolean wrap);

/// Pops up a menu (as runway_menu_button_set builds them) at a point in a canvas.
typedef void (*RunwayAKIndexFunc)(int index, void *user_data);
void runway_popup_menu(GtkWidget *canvas, int x, int y, const char *const *titles, const int *kinds, const int *depths,
                       const gboolean *enabled, const gboolean *checked, int count, RunwayAKIndexFunc fn, void *user_data);

/// A StatusNotifierItem. Returns NULL when no tray (StatusNotifierWatcher)
/// is on the session bus. Menu items are flat: kinds 0 item, 1 separator,
/// 2 submenu start, 3 submenu end.
typedef struct RunwayStatusItem RunwayStatusItem;
typedef void (*RunwayStatusFunc)(int index, void *user_data);   // index -1: activate; -2: menu about to show
RunwayStatusItem *runway_status_item_new(const char *id, const char *title, const char *icon_name, const char *tooltip,
                                         RunwayStatusFunc fn, void *user_data);
void runway_status_item_set(RunwayStatusItem *item, const char *title, const char *icon_name, const char *tooltip, gboolean visible);
void runway_status_item_set_menu(RunwayStatusItem *item, const char *const *titles, const int *kinds,
                                 const gboolean *enabled, const gboolean *checked, int count);
void runway_status_item_free(RunwayStatusItem *item);

/// Whether a widget is a GtkPopover (canvases present those rather than place them).
gboolean runway_is_popover(GtkWidget *w);

// MARK: NSTextView's text view (runway_textview.c)

typedef struct _RunwayTextView RunwayTextView;
typedef struct { GtkTextViewClass parent_class; } RunwayTextViewClass;

typedef struct {
    /// Paints layer 0 (below the text) or 1 (above) on `cr`, in the view's coordinates.
    void (*draw)(int layer, cairo_t *cr, void *data);
    /// A press (kind 0) or release (1) in the view; TRUE consumes it.
    gboolean (*pointer)(int kind, double x, double y, int button, unsigned modifiers, double time, void *data);
    /// Text the user typed, pasted or dropped (the buffer is left alone); TRUE if taken.
    gboolean (*insert)(const char *text, void *data);
    /// A deletion the user made in the view with nothing inserted after it (character offsets).
    void (*delete_range)(int start, int end, void *data);
    /// The selection the user made (character offsets), and whether a drag is still making it.
    void (*selection)(int start, int end, gboolean dragging, void *data);
    /// The laid-out text's height changed.
    void (*height)(int height, void *data);
    void *data;
    GDestroyNotify notify;
} RunwayTextViewCallbacks;

GtkWidget *runway_text_view_new(void);
void runway_text_view_set_callbacks(GtkWidget *view, const RunwayTextViewCallbacks *callbacks);
/// Which layers have drawing (redraws).
void runway_text_view_set_layers(GtkWidget *view, gboolean below, gboolean above);
/// While on, buffer changes are the program's own and pass through.
void runway_text_view_set_programmatic(GtkWidget *view, gboolean on);
/// step: 0 characters, 1 words, 2 display lines, 3 display line ends, 4 paragraphs, 5 paragraph ends, 6 pages, 7 buffer ends.
void runway_text_view_move(GtkWidget *view, int step, int count, gboolean extend);
/// A character's layout in the view: x, y, width, height, line top, line bottom, baseline.
void runway_text_view_char_layout(GtkWidget *view, int offset, double *out);
/// A character's box in the view: x, y, width, height.
void runway_text_view_char_rect(GtkWidget *view, int offset, double *out);
/// The laid-out text's height, with the bottom margin, in the view.
int runway_text_view_content_height(GtkWidget *view);

/// A tag's left and right margins (pixels).
void runway_text_tag_set_margins(GtkTextTag *tag, int left, int right);

/// The width of `text` in a Pango font description.
double runway_text_width(GtkWidget *widget, const char *font, const char *text);

/// A text tag with what runway_text_tag_new doesn't set: invisible text, a
/// line height multiple, underline and strikethrough colours ("#rrggbbaa"),
/// underline style (1 single, 2 thick, 3 double).
void runway_text_tag_set_more(GtkTextTag *tag, gboolean invisible, double line_height, const char *underline_rgba,
                              const char *strike_rgba, int underline_style);

G_END_DECLS
#endif
#endif
