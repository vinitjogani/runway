#if defined(__linux__) || defined(__FreeBSD__)
// NSTextView's GtkTextView: GTK lays out, draws and selects the text and
// runs the input method; AppKit owns the text. Edits the user makes in the
// view (input method commits, pastes, drops) are stopped before they reach
// the buffer and handed to AppKit, which changes its text storage and sends
// the result back. Presses go to AppKit first (an NSTextView subclass may
// handle a click itself), and the layout manager's drawing is painted
// below and above the text.
#include "runway_controls.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

struct _RunwayTextView {
    GtkTextView parent_instance;
    RunwayTextViewCallbacks cb;
    gboolean programmatic;
    gboolean layers[2];
    gboolean button_down;
    gboolean selected_while_dragging;
    int pending_delete_start, pending_delete_end;
    int last_height, last_width;
    guint height_idle;
    GtkAdjustment *watched;
};

G_DEFINE_TYPE(RunwayTextView, runway_text_view, GTK_TYPE_TEXT_VIEW)

static RunwayTextView *as_view(GtkWidget *w) { return (RunwayTextView *)w; }

// MARK: Layers

static gboolean report_height(gpointer data);

/// The part of the view its scroll view shows, in the view's coordinates.
static graphene_rect_t visible_rect(GtkWidget *w) {
    int ww = gtk_widget_get_width(w), wh = gtk_widget_get_height(w);
    graphene_rect_t all = GRAPHENE_RECT_INIT(0, 0, ww, wh);
    GtkWidget *vp = gtk_widget_get_ancestor(w, GTK_TYPE_VIEWPORT);
    if (!vp) return all;
    graphene_point_t o;
    if (!gtk_widget_compute_point(vp, w, &GRAPHENE_POINT_INIT(0, 0), &o)) return all;
    graphene_rect_t v = GRAPHENE_RECT_INIT(o.x, o.y, gtk_widget_get_width(vp), gtk_widget_get_height(vp));
    graphene_rect_t out;
    if (!graphene_rect_intersection(&all, &v, &out)) return GRAPHENE_RECT_INIT(0, 0, 0, 0);
    return out;
}

static void scrolled(GtkAdjustment *adj, gpointer data) {
    (void)adj;
    gtk_widget_queue_draw(GTK_WIDGET(data));
}

/// Redraws when the scroll view the text sits in scrolls (only the visible part is painted).
static void watch_scrolling(RunwayTextView *self) {
    GtkWidget *vp = gtk_widget_get_ancestor(GTK_WIDGET(self), GTK_TYPE_VIEWPORT);
    GtkAdjustment *adj = vp ? gtk_scrollable_get_vadjustment(GTK_SCROLLABLE(vp)) : NULL;
    if (adj == self->watched) return;
    if (self->watched) {
        g_signal_handlers_disconnect_by_data(self->watched, self);
        g_object_unref(self->watched);
    }
    self->watched = adj ? g_object_ref(adj) : NULL;
    if (adj) g_signal_connect(adj, "value-changed", G_CALLBACK(scrolled), self);
}

static void runway_text_view_snapshot_layer(GtkTextView *tv, GtkTextViewLayer layer, GtkSnapshot *snapshot) {
    RunwayTextView *self = (RunwayTextView *)tv;
    int index = layer == GTK_TEXT_VIEW_LAYER_BELOW_TEXT ? 0 : 1;
    if (index == 0) {
        watch_scrolling(self);
        // Layout settles in idle steps: after drawing, see whether it moved.
        if (!self->height_idle && self->cb.height)
            self->height_idle = g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, report_height, g_object_ref(self), g_object_unref);
    }
    if (!self->layers[index] || !self->cb.draw) return;
    GtkWidget *w = GTK_WIDGET(tv);
    graphene_rect_t vis = visible_rect(w);
    if (vis.size.width <= 0 || vis.size.height <= 0) return;
    // The snapshot is in buffer coordinates here; the layers are in the view's.
    int bx = 0, by = 0;
    gtk_text_view_window_to_buffer_coords(tv, GTK_TEXT_WINDOW_WIDGET, 0, 0, &bx, &by);
    gtk_snapshot_save(snapshot);
    gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT(bx, by));
    cairo_t *cr = gtk_snapshot_append_cairo(snapshot, &vis);
    self->cb.draw(index, cr, self->cb.data);
    cairo_destroy(cr);
    gtk_snapshot_restore(snapshot);
}

void runway_text_view_set_layers(GtkWidget *w, gboolean below, gboolean above) {
    RunwayTextView *self = as_view(w);
    self->layers[0] = below;
    self->layers[1] = above;
    gtk_widget_queue_draw(w);
}

// MARK: Height

static gboolean report_height(gpointer data) {
    RunwayTextView *self = data;
    self->height_idle = 0;
    // The text's height, or the width it wraps at (lines move without the
    // height changing), changed: the layout AppKit drew decorations for moved.
    int h = runway_text_view_content_height(GTK_WIDGET(self));
    int w = gtk_widget_get_width(GTK_WIDGET(self));
    if (h != self->last_height || w != self->last_width) {
        self->last_height = h;
        self->last_width = w;
        if (self->cb.height) self->cb.height(h, self->cb.data);
    }
    return G_SOURCE_REMOVE;
}

static void runway_text_view_measure(GtkWidget *w, GtkOrientation o, int for_size, int *min, int *nat, int *min_b, int *nat_b) {
    GTK_WIDGET_CLASS(runway_text_view_parent_class)->measure(w, o, for_size, min, nat, min_b, nat_b);
    RunwayTextView *self = as_view(w);
    // The layout validates in idle steps after edits and asks to be measured
    // as its height changes: tell AppKit (which sizes the view) afterwards.
    if (o == GTK_ORIENTATION_VERTICAL && !self->height_idle && self->cb.height)
        self->height_idle = g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, report_height, g_object_ref(self), g_object_unref);
    // Its own frame is AppKit's to set.
    *min = 0;
}

int runway_text_view_content_height(GtkWidget *w) {
    GtkTextView *tv = GTK_TEXT_VIEW(w);
    GtkTextBuffer *b = gtk_text_view_get_buffer(tv);
    GtkTextIter end;
    gtk_text_buffer_get_end_iter(b, &end);
    int y = 0, h = 0;
    gtk_text_view_get_line_yrange(tv, &end, &y, &h);
    int wx = 0, wy = 0;
    gtk_text_view_buffer_to_window_coords(tv, GTK_TEXT_WINDOW_WIDGET, 0, y + h, &wx, &wy);
    return wy + gtk_text_view_get_bottom_margin(tv);
}

static void runway_text_view_size_allocate(GtkWidget *w, int width, int height, int baseline) {
    GTK_WIDGET_CLASS(runway_text_view_parent_class)->size_allocate(w, width, height, baseline);
    RunwayTextView *self = as_view(w);
    if (width != self->last_width && !self->height_idle && self->cb.height)
        self->height_idle = g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, report_height, g_object_ref(self), g_object_unref);
}

// MARK: Edits from the view

static void insert_text(GtkTextBuffer *b, GtkTextIter *at, const char *text, int len, gpointer data) {
    (void)at;
    RunwayTextView *self = data;
    if (self->programmatic || !self->cb.insert) return;
    g_signal_stop_emission_by_name(b, "insert-text");
    // A replacement: the selection the deletion before it removed is replaced by the insertion.
    self->pending_delete_start = self->pending_delete_end = -1;
    char *s = g_strndup(text, len < 0 ? strlen(text) : (size_t)len);
    self->cb.insert(s, self->cb.data);
    g_free(s);
}

static void delete_range(GtkTextBuffer *b, GtkTextIter *start, GtkTextIter *end, gpointer data) {
    RunwayTextView *self = data;
    if (self->programmatic || !self->cb.insert) return;
    g_signal_stop_emission_by_name(b, "delete-range");
    int s = gtk_text_iter_get_offset(start), e = gtk_text_iter_get_offset(end);
    self->pending_delete_start = MIN(s, e);
    self->pending_delete_end = MAX(s, e);
}

static void end_user_action(GtkTextBuffer *b, gpointer data) {
    (void)b;
    RunwayTextView *self = data;
    if (self->pending_delete_start < 0) return;
    int s = self->pending_delete_start, e = self->pending_delete_end;
    self->pending_delete_start = self->pending_delete_end = -1;
    if (self->cb.delete_range && e > s) self->cb.delete_range(s, e, self->cb.data);
}

static void mark_set(GtkTextBuffer *b, GtkTextIter *at, GtkTextMark *mark, gpointer data) {
    (void)at;
    RunwayTextView *self = data;
    if (self->programmatic || !self->cb.selection) return;
    if (mark != gtk_text_buffer_get_insert(b) && mark != gtk_text_buffer_get_selection_bound(b)) return;
    GtkTextIter x, y;
    gtk_text_buffer_get_iter_at_mark(b, &x, gtk_text_buffer_get_insert(b));
    gtk_text_buffer_get_iter_at_mark(b, &y, gtk_text_buffer_get_selection_bound(b));
    int a = gtk_text_iter_get_offset(&x), c = gtk_text_iter_get_offset(&y);
    if (self->button_down) self->selected_while_dragging = TRUE;
    self->cb.selection(MIN(a, c), MAX(a, c), self->button_down, self->cb.data);
}

void runway_text_view_set_programmatic(GtkWidget *w, gboolean on) { as_view(w)->programmatic = on; }

// MARK: Presses

static unsigned modifiers_of(GdkModifierType s) {
    unsigned m = 0;
    if (s & GDK_SHIFT_MASK) m |= 1;
    if (s & GDK_CONTROL_MASK) m |= 2;
    if (s & GDK_ALT_MASK) m |= 4;
    if (s & (GDK_SUPER_MASK | GDK_META_MASK)) m |= 8;
    return m;
}

static gboolean legacy_event(GtkEventControllerLegacy *c, GdkEvent *ev, gpointer data) {
    RunwayTextView *self = data;
    GdkEventType t = gdk_event_get_event_type(ev);
    if (t != GDK_BUTTON_PRESS && t != GDK_BUTTON_RELEASE) return FALSE;
    double ex = 0, ey = 0;
    if (!gdk_event_get_position(ev, &ex, &ey)) return FALSE;
    GtkWidget *w = GTK_WIDGET(self);
    GtkNative *native = gtk_widget_get_native(w);
    if (!native) return FALSE;
    double sx = 0, sy = 0;
    gtk_native_get_surface_transform(native, &sx, &sy);
    graphene_point_t p;
    if (!gtk_widget_compute_point(GTK_WIDGET(native), w, &GRAPHENE_POINT_INIT(ex - sx, ey - sy), &p)) return FALSE;
    guint b = gdk_button_event_get_button(ev);
    int button = b == 1 ? 0 : b == 3 ? 1 : b == 2 ? 2 : (int)b - 1;
    gboolean press = t == GDK_BUTTON_PRESS;
    if (button == 0) self->button_down = press;
    gboolean consumed = FALSE;
    if (self->cb.pointer)
        consumed = self->cb.pointer(press ? 0 : 1, p.x, p.y, button, modifiers_of(gdk_event_get_modifier_state(ev)),
                                    gdk_event_get_time(ev) / 1000.0, self->cb.data);
    if (!press && button == 0 && self->selected_while_dragging) {
        // The drag's selection is final now.
        self->selected_while_dragging = FALSE;
        GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(self));
        mark_set(buf, NULL, gtk_text_buffer_get_insert(buf), self);
    }
    (void)c;
    return consumed;
}

// MARK: Caret movement

void runway_text_view_move(GtkWidget *w, int step, int count, gboolean extend) {
    static const GtkMovementStep steps[] = {
        GTK_MOVEMENT_LOGICAL_POSITIONS, GTK_MOVEMENT_WORDS, GTK_MOVEMENT_DISPLAY_LINES, GTK_MOVEMENT_DISPLAY_LINE_ENDS,
        GTK_MOVEMENT_PARAGRAPHS, GTK_MOVEMENT_PARAGRAPH_ENDS, GTK_MOVEMENT_PAGES, GTK_MOVEMENT_BUFFER_ENDS,
    };
    if (step < 0 || step > 7) return;
    g_signal_emit_by_name(w, "move-cursor", steps[step], count, extend);
}

// MARK: Geometry

/// The ascent and descent of the font at an iterator (its tags' font, else the view's).
static void font_metrics(GtkTextView *tv, const GtkTextIter *it, double *ascent, double *descent) {
    PangoContext *ctx = gtk_widget_get_pango_context(GTK_WIDGET(tv));
    PangoFontDescription *desc = pango_font_description_copy(pango_context_get_font_description(ctx));
    GSList *tags = gtk_text_iter_get_tags(it);
    int best = -1;
    for (GSList *l = tags; l; l = l->next) {
        GtkTextTag *t = l->data;
        gboolean set = FALSE;
        g_object_get(t, "size-set", &set, NULL);
        int prio = gtk_text_tag_get_priority(t);
        if (!set || prio < best) continue;
        PangoFontDescription *d = NULL;
        g_object_get(t, "font-desc", &d, NULL);
        if (d) {
            pango_font_description_free(desc);
            desc = d;
            best = prio;
        }
    }
    g_slist_free(tags);
    PangoFontMetrics *m = pango_context_get_metrics(ctx, desc, NULL);
    *ascent = pango_font_metrics_get_ascent(m) / (double)PANGO_SCALE;
    *descent = pango_font_metrics_get_descent(m) / (double)PANGO_SCALE;
    pango_font_metrics_unref(m);
    pango_font_description_free(desc);
}

/// A character's box in buffer coordinates. gtk_text_view_get_iter_location
/// alone is wrong with invisible text earlier on the line: GTK 4 looks the
/// iterator's line index up in the layout, which holds only the visible
/// text. So it's asked for the iterator whose index is this character's
/// index in the visible text (an invisible character gets the box of the
/// visible one after it, with no width).
static void char_box(GtkTextView *tv, const GtkTextIter *it, GdkRectangle *r) {
    int visible = gtk_text_iter_get_visible_line_index(it);
    GtkTextIter q = *it;
    gtk_text_iter_set_line_offset(&q, 0);
    while (gtk_text_iter_get_line_index(&q) < visible && !gtk_text_iter_ends_line(&q)) gtk_text_iter_forward_char(&q);
    if (gtk_text_iter_get_line_index(&q) == visible) {
        gtk_text_view_get_iter_location(tv, &q, r);
    } else {
        // No character starts there (multibyte text): the caret's place.
        gtk_text_view_get_cursor_locations(tv, it, r, NULL);
    }
    GtkTextIter n = *it;
    if (!gtk_text_iter_ends_line(it) && gtk_text_iter_forward_char(&n) && gtk_text_iter_get_line(&n) == gtk_text_iter_get_line(it)
        && gtk_text_iter_get_visible_line_index(&n) == visible)
        r->width = 0;
}

void runway_text_view_char_rect(GtkWidget *w, int offset, double *out) {
    GtkTextView *tv = GTK_TEXT_VIEW(w);
    GtkTextIter it;
    gtk_text_buffer_get_iter_at_offset(gtk_text_view_get_buffer(tv), &it, offset);
    GdkRectangle r;
    char_box(tv, &it, &r);
    int x = 0, y = 0;
    gtk_text_view_buffer_to_window_coords(tv, GTK_TEXT_WINDOW_WIDGET, r.x, r.y, &x, &y);
    out[0] = x; out[1] = y; out[2] = r.width; out[3] = r.height;
}

void runway_text_view_char_layout(GtkWidget *w, int offset, double *out) {
    GtkTextView *tv = GTK_TEXT_VIEW(w);
    GtkTextBuffer *b = gtk_text_view_get_buffer(tv);
    GtkTextIter it;
    gtk_text_buffer_get_iter_at_offset(b, &it, offset);
    GdkRectangle r, first, last;
    char_box(tv, &it, &r);
    // The paragraph's first and last display lines.
    GtkTextIter ps = it, pe = it;
    gtk_text_iter_set_line_offset(&ps, 0);
    if (!gtk_text_iter_ends_line(&pe)) gtk_text_iter_forward_to_line_end(&pe);
    gtk_text_view_get_cursor_locations(tv, &ps, &first, NULL);
    gtk_text_view_get_cursor_locations(tv, &pe, &last, NULL);
    int ly = 0, lh = 0;
    gtk_text_view_get_line_yrange(tv, &it, &ly, &lh);
    int top = r.y == first.y ? ly : r.y;
    int bottom = r.y == last.y ? ly + lh : r.y + r.height;
    // The baseline: the line's font centred in the line's height, as Pango
    // spreads extra line height above and below.
    GtkTextIter rs = it;
    if (!gtk_text_view_starts_display_line(tv, &rs)) gtk_text_view_backward_display_line_start(tv, &rs);
    double asc = 0, desc = 0;
    font_metrics(tv, &rs, &asc, &desc);
    double baseline = r.y + (r.height - (asc + desc)) / 2 + asc;
    int x = 0, y = 0, t = 0, bt = 0;
    gtk_text_view_buffer_to_window_coords(tv, GTK_TEXT_WINDOW_WIDGET, r.x, r.y, &x, &y);
    gtk_text_view_buffer_to_window_coords(tv, GTK_TEXT_WINDOW_WIDGET, 0, top, NULL, &t);
    gtk_text_view_buffer_to_window_coords(tv, GTK_TEXT_WINDOW_WIDGET, 0, bottom, NULL, &bt);
    out[0] = x; out[1] = y; out[2] = r.width; out[3] = r.height;
    out[4] = t; out[5] = bt; out[6] = baseline + (y - r.y);
}

// MARK: The class

static void runway_text_view_dispose(GObject *o) {
    RunwayTextView *self = (RunwayTextView *)o;
    if (self->watched) {
        g_signal_handlers_disconnect_by_data(self->watched, self);
        g_clear_object(&self->watched);
    }
    if (self->height_idle) { g_source_remove(self->height_idle); self->height_idle = 0; }
    G_OBJECT_CLASS(runway_text_view_parent_class)->dispose(o);
}

static void runway_text_view_finalize(GObject *o) {
    RunwayTextView *self = (RunwayTextView *)o;
    if (self->cb.notify) self->cb.notify(self->cb.data);
    G_OBJECT_CLASS(runway_text_view_parent_class)->finalize(o);
}

static void runway_text_view_class_init(RunwayTextViewClass *klass) {
    GTK_TEXT_VIEW_CLASS(klass)->snapshot_layer = runway_text_view_snapshot_layer;
    GTK_WIDGET_CLASS(klass)->measure = runway_text_view_measure;
    GTK_WIDGET_CLASS(klass)->size_allocate = runway_text_view_size_allocate;
    G_OBJECT_CLASS(klass)->dispose = runway_text_view_dispose;
    G_OBJECT_CLASS(klass)->finalize = runway_text_view_finalize;
}

static void runway_text_view_init(RunwayTextView *self) {
    self->pending_delete_start = self->pending_delete_end = -1;
    self->last_height = -1;
    GtkTextBuffer *b = gtk_text_view_get_buffer(GTK_TEXT_VIEW(self));
    g_signal_connect(b, "insert-text", G_CALLBACK(insert_text), self);
    g_signal_connect(b, "delete-range", G_CALLBACK(delete_range), self);
    g_signal_connect(b, "end-user-action", G_CALLBACK(end_user_action), self);
    g_signal_connect_after(b, "mark-set", G_CALLBACK(mark_set), self);
    GtkEventController *legacy = gtk_event_controller_legacy_new();
    gtk_event_controller_set_propagation_phase(legacy, GTK_PHASE_CAPTURE);
    g_signal_connect(legacy, "event", G_CALLBACK(legacy_event), self);
    gtk_widget_add_controller(GTK_WIDGET(self), legacy);
}

GtkWidget *runway_text_view_new(void) { return g_object_new(runway_text_view_get_type(), NULL); }

void runway_text_view_set_callbacks(GtkWidget *w, const RunwayTextViewCallbacks *cb) {
    RunwayTextView *self = as_view(w);
    if (self->cb.notify) self->cb.notify(self->cb.data);
    self->cb = *cb;
}
#endif
