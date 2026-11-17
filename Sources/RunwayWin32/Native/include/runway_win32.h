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

#define RW_MOD_SHIFT 1
#define RW_MOD_CTRL  2
#define RW_MOD_ALT   4
#define RW_MOD_WIN   8

#define RW_CURSOR_ARROW 0
#define RW_CURSOR_HAND  1
#define RW_CURSOR_IBEAM 2

typedef struct {
    int type;
    void *ctx;
    double x, y;      // pointer position, client DIPs
    double dx, dy;    // wheel delta or new size
    int button;       // 0 left, 1 right, 2 middle
    int key;          // virtual-key code
    unsigned mods;    // RW_MOD_*
} rw_event;

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
void rw_window_invalidate(rw_window *w);
void rw_window_set_dark(rw_window *w, int dark);
void rw_window_set_cursor(rw_window *w, int cursor);
void rw_window_capture(rw_window *w, int on);
void rw_window_set_timer(rw_window *w, int milliseconds);   // 0 stops it
double rw_window_scale(rw_window *w);
int rw_window_backdrop(rw_window *w);   // 1 if the client area shows Mica (clear to transparent)
void rw_window_focus(rw_window *w);     // keyboard focus to the window itself
// Runs messages until *done becomes non-zero (modal alerts).
void rw_run_modal(volatile int *done);

// Drawing: only while handling RW_EV_PAINT for that window. Coordinates are
// relative to the current offset; the current paint fills and strokes.
void rw_draw_clear(rw_window *w, rw_color c);
void rw_draw_set_offset(rw_window *w, double x, double y);
void rw_draw_set_alpha(rw_window *w, float alpha);
void rw_draw_push_clip(rw_window *w, double x, double y, double width, double height);
void rw_draw_pop_clip(rw_window *w);
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

// Popup menus; ids must be > 0. rw_menu_popup returns the chosen id or 0.
rw_menu *rw_menu_create(void);
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
