// The native half of Runway's Windows backend: a flat C API over Win32,
// Direct2D, DirectWrite, WIC and the Shell, implemented in C++ (see the
// .cpp files next to this directory). The Swift half (RunwayWin32) owns the
// widget tree, hit-testing and the Mac-style look of every control; this
// layer owns windows, the message loop, drawing, text, images, the EDIT
// controls used for text input, menus and desktop services.
//
// Conventions: strings are UTF-8, coordinates and sizes are DIPs (1/96 in),
// colours are straight (non-premultiplied) RGBA in 0...1. Everything runs
// on the thread that called rw_init. The declarations carry no Windows
// types, so the header is valid (and unused) on every platform.

#ifndef RUNWAY_WIN32_H
#define RUNWAY_WIN32_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rw_window rw_window;
typedef struct rw_text rw_text;
typedef struct rw_image rw_image;
typedef struct rw_path rw_path;
typedef struct rw_edit rw_edit;
typedef struct rw_menu rw_menu;

typedef struct { float r, g, b, a; } rw_color;
typedef struct { float location; rw_color color; } rw_stop;

// Events. `ctx` is the context given when the window or edit was created
// (NULL for app-wide events such as THEME_CHANGED and WAKE).
#define RW_EV_PAINT          1   // draw now with rw_draw_*
#define RW_EV_MOUSE_DOWN     2
#define RW_EV_MOUSE_UP       3
#define RW_EV_MOUSE_MOVE     4
#define RW_EV_MOUSE_LEAVE    5
#define RW_EV_WHEEL          6   // dx, dy: content offset change in DIPs
#define RW_EV_KEY_DOWN       7   // key: virtual-key code; return 1 if handled
#define RW_EV_RESIZE         8   // dx, dy: new content size
#define RW_EV_CLOSE_REQUEST  9   // the user asked to close (the window stays until rw_window_destroy)
#define RW_EV_DESTROYED     10   // the window is gone; its rw_window* is invalid after this
#define RW_EV_DPI_CHANGED   11
#define RW_EV_THEME_CHANGED 12
#define RW_EV_WAKE          13   // rw_wake was called
#define RW_EV_TIMER         14
#define RW_EV_EDIT_CHANGED  15   // ctx: the edit's context
#define RW_EV_EDIT_SUBMIT   16   // Return in a single-line edit; return 1 if handled
#define RW_EV_EDIT_FOCUS    17
#define RW_EV_EDIT_BLUR     18
#define RW_EV_RAW_KEY       19   // any key, before anything handles it: key, flags (RW_KEY_*), text: characters, text2: key name; return 1 to swallow it
#define RW_EV_ACTIVATE      20   // button: 1 the window became active, 0 it stopped being active
#define RW_EV_MENU_COMMAND  21   // key: the menu bar item's id
#define RW_EV_MENU_OPENING  22   // a menu of the menu bar is about to open
#define RW_EV_DRAG          23   // button: 0 entered, 1 over, 2 left, 3 drop; text: file paths (newline-separated), text2: text; return RW_DROP_* bits
#define RW_EV_CHILD_MOUSE   24   // a press or release in a native child (edit): button, x, y (window DIPs), flags; return 1 to swallow it
#define RW_EV_CHILD_MOUSE_AFTER 25 // the same, after the child handled it
#define RW_EV_EDIT_KEY      26   // ctx: the edit's; key, mods before the edit handles them; return 1 to swallow
#define RW_EV_RICH_CHANGED  27   // ctx: the rich edit's
#define RW_EV_RICH_SELECTION 28  // flags: RW_KEY_REPEAT while a drag is still selecting
#define RW_EV_RICH_FOCUS    29   // button: 1 gained, 0 lost
#define RW_EV_RICH_CHAR     30   // text: typed text; return 1 if the handler inserted it
#define RW_EV_RICH_KEY      31   // key, mods; return 1 to swallow
#define RW_EV_RICH_POINTER  32   // button, x, y (the view's DIPs), flags RW_MOUSE_RELEASE, key: click count; return 1 to swallow
#define RW_EV_RICH_HEIGHT   33   // dy: the text's new height
#define RW_EV_TRAY          34   // ctx: the tray item's; button: 0 primary, 1 secondary
#define RW_EV_MOVED         35   // x, y: the window's outer top-left on the desktop (DIPs)
#define RW_EV_RICH_PAINT    36   // ctx: the rich edit's; button: 0 under the text, 1 over it; draw on rw_rich_surface()

#define RW_MOD_SHIFT 1
#define RW_MOD_CTRL  2
#define RW_MOD_ALT   4
#define RW_MOD_WIN   8

#define RW_CURSOR_ARROW 0
#define RW_CURSOR_HAND  1
#define RW_CURSOR_IBEAM 2
#define RW_CURSOR_CROSS 3
#define RW_CURSOR_SIZEWE 4
#define RW_CURSOR_SIZENS 5
#define RW_CURSOR_SIZEALL 6
#define RW_CURSOR_NO 7
#define RW_CURSOR_WAIT 8
#define RW_CURSOR_HELP 9
#define RW_CURSOR_SIZENWSE 10
#define RW_CURSOR_SIZENESW 11
#define RW_CURSOR_PROGRESS 12
#define RW_CURSOR_HIDDEN 13

typedef struct {
    int type;
    void *ctx;
    double x, y;      // pointer position, client DIPs
    double dx, dy;    // wheel delta or new size
    int button;       // 0 left, 1 right, 2 middle
    int key;          // virtual-key code
    unsigned mods;    // RW_MOD_*
    unsigned flags;   // RW_KEY_*, RW_MOUSE_*
    int clicks;       // presses: the click count
    const char *text;
    const char *text2;
} rw_event;

#define RW_KEY_UP          1
#define RW_KEY_REPEAT      2
#define RW_KEY_NATIVE_TEXT 4   // a text input has keyboard focus
#define RW_KEY_MODIFIER    8   // a modifier key alone
#define RW_MOUSE_RELEASE  16

#define RW_DROP_COPY 1
#define RW_DROP_LINK 2
#define RW_DROP_MOVE 16

typedef int (*rw_event_fn)(const rw_event *event);

// App.
int rw_init(rw_event_fn callback);      // 1 on success
void rw_run(void);                      // until rw_quit
void rw_quit(void);
void rw_wake(void);                     // posts one RW_EV_WAKE
int rw_dark_mode(void);                 // apps use the dark theme
int rw_font_available(const char *family);
void rw_free(void *p);                  // frees strings this API returns
// The unshifted character a virtual key types in the current layout, or 0.
int rw_key_char(int virtual_key);

// Windows.
rw_window *rw_window_create(const char *title, double width, double height, int resizable, rw_window *parent, int modal, void *ctx);
void rw_window_destroy(rw_window *w);
void rw_window_set_title(rw_window *w, const char *title);
void rw_window_set_content_size(rw_window *w, double width, double height);
void rw_window_get_content_size(rw_window *w, double *width, double *height);
void rw_window_set_min_size(rw_window *w, double width, double height);
void rw_window_set_resizable(rw_window *w, int resizable);
void rw_window_show(rw_window *w);
void rw_window_center(rw_window *w);
// The outer top-left on the desktop (DIPs of the window's monitor).
void rw_window_set_position(rw_window *w, double x, double y);
void rw_window_invalidate(rw_window *w);
void rw_window_set_dark(rw_window *w, int dark);
void rw_window_set_cursor(rw_window *w, int cursor);
void rw_window_capture(rw_window *w, int on);
void rw_window_set_timer(rw_window *w, int milliseconds);   // 0 stops it
double rw_window_scale(rw_window *w);
int rw_window_backdrop(rw_window *w);   // 1 if the client area shows Mica (clear to transparent)
void rw_window_focus(rw_window *w);     // keyboard focus to the window itself
// An owned, borderless popup (popovers); place it with rw_popup_place.
rw_window *rw_popup_create(rw_window *owner, void *ctx);
// x, y, width, height in the owner's client DIPs; kept on the owner's screen.
void rw_popup_place(rw_window *popup, double x, double y, double width, double height);
// Where `w`'s client origin is in `other`'s client DIPs.
void rw_window_offset_in(rw_window *w, rw_window *other, double *x, double *y);
void rw_window_set_cursor_image(rw_window *w, int width, int height, const uint8_t *rgba, int hot_x, int hot_y);
void rw_window_set_decorated(rw_window *w, int decorated);
void rw_window_begin_move(rw_window *w);
void rw_window_activate(rw_window *w);
int rw_window_is_active(rw_window *w);
void rw_window_show_inactive(rw_window *w);
void rw_window_accept_drops(rw_window *w, int on);
// The menu bar (NULL removes it); the window owns the menu afterwards. Item
// choices arrive as RW_EV_MENU_COMMAND, so ids must be 1...65535.
void rw_window_set_menubar(rw_window *w, rw_menu *m);
void rw_window_menu_item_state(rw_window *w, int id, int enabled, int checked);
// Displays: 9 values each (frame x y w h, work area x y w h, scale), DIPs.
int rw_screens(double *out, int max);
// Runs messages until *done becomes non-zero (modal alerts).
void rw_run_modal(volatile int *done);

// Drawing: only while handling RW_EV_PAINT for that window. Coordinates are
// relative to the current offset; the current paint fills and strokes.
void rw_draw_clear(rw_window *w, rw_color c);
void rw_draw_set_offset(rw_window *w, double x, double y);
void rw_draw_set_alpha(rw_window *w, float alpha);
void rw_draw_push_clip(rw_window *w, double x, double y, double width, double height);
void rw_draw_pop_clip(rw_window *w);
// A transform (applied before the offset) for what follows, until the next
// rw_draw_set_offset or rw_draw_set_transform.
void rw_draw_set_transform(rw_window *w, double a, double b, double c, double d, double tx, double ty);
// Clips to a path under the current transform; pops with rw_draw_pop_clip.
void rw_draw_push_clip_path(rw_window *w, rw_path *p);
void rw_draw_paint_color(rw_window *w, rw_color c);
void rw_draw_paint_linear(rw_window *w, double x0, double y0, double x1, double y1, const rw_stop *stops, int count);
void rw_draw_paint_radial(rw_window *w, double cx, double cy, double r0, double r1, const rw_stop *stops, int count);
void rw_draw_set_dash(rw_window *w, const float *dashes, int count);   // count 0: solid
void rw_draw_set_round_caps(rw_window *w, int round);                  // round caps and joins for strokes
void rw_draw_rect(rw_window *w, int fill, double x, double y, double width, double height, double radius, double line_width);
void rw_draw_ellipse(rw_window *w, int fill, double x, double y, double width, double height, double line_width);
void rw_draw_line(rw_window *w, double x0, double y0, double x1, double y1, double line_width);
void rw_draw_path(rw_window *w, int fill, rw_path *p, double line_width);
void rw_draw_text(rw_window *w, rw_text *t, double x, double y, double width, double height, rw_color color);
void rw_draw_image(rw_window *w, rw_image *img, double x, double y, double width, double height);

// Paths (device-independent; build once, draw many times).
rw_path *rw_path_create(void);
void rw_path_move(rw_path *p, double x, double y);
void rw_path_line(rw_path *p, double x, double y);
void rw_path_quad(rw_path *p, double cx, double cy, double x, double y);
void rw_path_cubic(rw_path *p, double c1x, double c1y, double c2x, double c2y, double x, double y);
void rw_path_close(rw_path *p);
void rw_path_set_even_odd(rw_path *p, int on);
void rw_path_free(rw_path *p);

// Text (DirectWrite). A run with family NULL uses the UI font.
typedef struct {
    const char *text;
    const char *family;
    float size;
    int weight;           // 100...900
    int italic;
    int tabular_digits;
    int underline;
    int strikethrough;
    int has_color;
    rw_color color;
} rw_text_run;

#define RW_ALIGN_LEADING  0
#define RW_ALIGN_CENTER   1
#define RW_ALIGN_TRAILING 2
#define RW_TRUNCATE_HEAD   0
#define RW_TRUNCATE_MIDDLE 1
#define RW_TRUNCATE_TAIL   2

rw_text *rw_text_create(const rw_text_run *runs, int count, int alignment, int line_limit, int truncation);
void rw_text_free(rw_text *t);
// Size wrapped to max_width (<= 0: unlimited); honours the line limit.
void rw_text_measure(rw_text *t, double max_width, double *width, double *height);
// Line baselines from the top, wrapped to max_width; returns how many.
int rw_text_baselines(rw_text *t, double max_width, double *out, int max);

// Images (WIC). Pixels are kept premultiplied BGRA; GPU copies are made per window.
rw_image *rw_image_load_file(const char *path);
rw_image *rw_image_from_rgba(int width, int height, const uint8_t *rgba);
void rw_image_size(rw_image *img, int *width, int *height);
void rw_image_free(rw_image *img);

// Text input: an EDIT control placed over a custom-drawn field.
rw_edit *rw_edit_create(rw_window *w, int multiline, void *ctx);
void rw_edit_destroy(rw_edit *e);
// frame and clip in window DIPs; the part outside clip is cut away.
void rw_edit_set_frame(rw_edit *e, double x, double y, double width, double height,
                       double clip_x, double clip_y, double clip_width, double clip_height, int visible);
void rw_edit_set_text(rw_edit *e, const char *text);
char *rw_edit_copy_text(rw_edit *e);
void rw_edit_set_style(rw_edit *e, float size, int weight, rw_color text, rw_color background, int password);
void rw_edit_set_placeholder(rw_edit *e, const char *text);
void rw_edit_set_enabled(rw_edit *e, int enabled);
void rw_edit_focus(rw_edit *e, int select_all);
int rw_edit_has_focus(rw_edit *e);
void rw_edit_set_alignment(rw_edit *e, int alignment);   // RW_ALIGN_*
void rw_edit_set_readonly(rw_edit *e, int readonly);

// Rich text: a RichEdit control over a custom-drawn view. Offsets are UTF-16
// units of the text with "\n" line breaks.
typedef struct rw_rich rw_rich;
typedef struct {
    const char *text;
    const char *family;     // NULL: the UI font
    float size;
    int weight;
    int italic;
    int has_color; rw_color color;
    int has_background; rw_color background;
    int underline;          // 0 none, 1 single, 2 thick, 3 double
    int strikethrough;
    float baseline_offset;
    int hidden;
    int has_paragraph;
    int alignment;          // RW_ALIGN_*, 3 justified
    float line_spacing, paragraph_spacing, spacing_before, first_indent, head_indent, tail_indent, line_height_multiple;
} rw_rich_run;
rw_rich *rw_rich_create(rw_window *w, void *ctx);
void rw_rich_destroy(rw_rich *r);
void rw_rich_set_frame(rw_rich *r, double x, double y, double width, double height,
                       double clip_x, double clip_y, double clip_width, double clip_height, int visible);
void rw_rich_configure(rw_rich *r, int editable, int wraps, double left, double top, double right, double bottom,
                       rw_color background, const rw_rich_run *typing, int takes_typing);
void rw_rich_set_runs(rw_rich *r, const rw_rich_run *runs, int count);
void rw_rich_replace(rw_rich *r, int start, int end, const rw_rich_run *runs, int count);
void rw_rich_get_selection(rw_rich *r, int *start, int *end);
void rw_rich_set_selection(rw_rich *r, int start, int end);
void rw_rich_undo(rw_rich *r, int redo);
double rw_rich_height(rw_rich *r, double width);
void rw_rich_char_rect(rw_rich *r, int index, double *x, double *y, double *width, double *height);
int rw_rich_char_index(rw_rich *r, double x, double y);
// step: 0 character, 1 word, 2 line, 3 line end, 4 paragraph, 5 paragraph end, 6 page, 7 document.
void rw_rich_move(rw_rich *r, int step, int count, int extend);
void rw_rich_focus(rw_rich *r);
int rw_rich_has_focus(rw_rich *r);
char *rw_rich_copy_text(rw_rich *r);
// Drawing under and over the text (RW_EV_RICH_PAINT); under it, the view
// paints its background itself.
void rw_rich_set_layers(rw_rich *r, int below, int above);
// The surface to draw on while handling RW_EV_RICH_PAINT.
rw_window *rw_rich_surface(rw_rich *r);

// Tray icons (Shell notification area).
typedef struct rw_tray rw_tray;
rw_tray *rw_tray_create(const char *tooltip, void *ctx);
void rw_tray_update(rw_tray *t, const char *tooltip, int visible);
void rw_tray_destroy(rw_tray *t);

// Popup menus; ids must be > 0. rw_menu_popup returns the chosen id or 0.
rw_menu *rw_menu_create(void);
rw_menu *rw_menubar_create(void);       // a menu bar's top level
void rw_menu_add(rw_menu *m, const char *title, int id, int enabled, int checked);
void rw_menu_add_separator(rw_menu *m);
rw_menu *rw_menu_add_submenu(rw_menu *m, const char *title, int enabled);
int rw_menu_popup(rw_menu *m, rw_window *w, double x, double y);
void rw_menu_free(rw_menu *m);

// Services.
int rw_choose_color(rw_window *owner, rw_color initial, rw_color *result);
void rw_clipboard_set_text(const char *text);
void rw_clipboard_set_files(const char *const *paths, int count);
char *rw_clipboard_get_text(void);
int rw_shell_open(const char *target);
void rw_reveal(const char *const *paths, int count);
int rw_play_sound(const char *name);
void rw_beep(void);
// Newline-separated paths, or NULL when cancelled.
char *rw_choose_files(rw_window *owner, const char *title, int multiple, int directories, const char *const *extensions, int count);
char *rw_choose_save(rw_window *owner, const char *title, const char *suggested_name);
int rw_message_box(rw_window *owner, const char *title, const char *message, int ok_cancel);

#ifdef __cplusplus
}
#endif

#endif
