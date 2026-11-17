#if defined(__linux__) || defined(__FreeBSD__)
// The Mac's twelve-spoke activity indicator, drawn directly.
//
// A CSS animation (GtkSpinner's `animation: … infinite`) ticks GDK's frame
// clock every frame for as long as the spinner is mapped: on X11 that is
// ~120 frames a second, each re-validating styles, re-allocating the window's
// widget tree and making several synchronous X round trips (about 1,800
// poll() wakeups a second and a few percent CPU for one idle spinner). The
// Mac's indicator only moves twelve times a second, so this one does exactly
// that: a 1/12 s timer while mapped (none while hidden or unmapped) that
// queues a redraw of its own few pixels. No layout, no restyle.
#include "runway_gtk.h"
#include <math.h>

#define RUNWAY_TYPE_SPINNER (runway_spinner_get_type())
G_DECLARE_FINAL_TYPE(RunwaySpinner, runway_spinner, RUNWAY, SPINNER, GtkWidget)

struct _RunwaySpinner {
    GtkWidget parent_instance;
    guint step;
    guint timer;
};

G_DEFINE_TYPE(RunwaySpinner, runway_spinner, GTK_TYPE_WIDGET)

static int spinner_size(GtkWidget *w) {
    if (gtk_widget_has_css_class(w, "rw-small")) return 16;
    if (gtk_widget_has_css_class(w, "rw-large")) return 48;
    return 32;
}

static gboolean spinner_tick(gpointer data) {
    RunwaySpinner *self = data;
    self->step = (self->step + 1) % 12;
    gtk_widget_queue_draw(GTK_WIDGET(self));
    return G_SOURCE_CONTINUE;
}

static gboolean animations_enabled(GtkWidget *w) {
    gboolean on = TRUE;
    g_object_get(gtk_widget_get_settings(w), "gtk-enable-animations", &on, NULL);
    return on;
}

static void spinner_start(RunwaySpinner *self) {
    if (self->timer || !animations_enabled(GTK_WIDGET(self))) return;
    self->timer = g_timeout_add_full(G_PRIORITY_DEFAULT, 1000 / 12, spinner_tick, self, NULL);
}

static void spinner_stop(RunwaySpinner *self) {
    if (self->timer) { g_source_remove(self->timer); self->timer = 0; }
}

static void runway_spinner_map(GtkWidget *w) {
    GTK_WIDGET_CLASS(runway_spinner_parent_class)->map(w);
    spinner_start(RUNWAY_SPINNER(w));
}

static void runway_spinner_unmap(GtkWidget *w) {
    spinner_stop(RUNWAY_SPINNER(w));
    GTK_WIDGET_CLASS(runway_spinner_parent_class)->unmap(w);
}

static void runway_spinner_measure(GtkWidget *w, GtkOrientation o, int for_size, int *min, int *nat, int *minb, int *natb) {
    *min = *nat = spinner_size(w);
    (void)o; (void)for_size; (void)minb; (void)natb;
}

static void runway_spinner_css_changed(GtkWidget *w, GtkCssStyleChange *change) {
    GTK_WIDGET_CLASS(runway_spinner_parent_class)->css_changed(w, change);
    gtk_widget_queue_resize(w);   // rw-small / rw-large pick the size
}

static void runway_spinner_snapshot(GtkWidget *w, GtkSnapshot *snapshot) {
    RunwaySpinner *self = RUNWAY_SPINNER(w);
    int width = gtk_widget_get_width(w), height = gtk_widget_get_height(w);
    double size = MIN(width, height);
    if (size <= 0) return;
    GdkRGBA color;
    gtk_widget_get_color(w, &color);
    // The Mac draws the indicator in the label colour at reduced opacity.
    double luminance = 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue;
    double base = luminance > 0.5 ? 0.7 : 0.55;

    cairo_t *cr = gtk_snapshot_append_cairo(snapshot, &GRAPHENE_RECT_INIT(0, 0, width, height));
    double scale = size / 32.0;
    cairo_translate(cr, width / 2.0, height / 2.0);
    cairo_scale(cr, scale, scale);
    cairo_set_line_width(cr, 2.7);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    for (int i = 0; i < 12; i++) {
        // Spoke i is drawn i steps behind the head (the most opaque one).
        int age = (int)((self->step + 12 - i) % 12);
        double a = (double)i * M_PI / 6 - M_PI / 2;
        double opacity = 0.18 + 0.82 * (double)(11 - age) / 11;
        cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.alpha * base * opacity);
        cairo_move_to(cr, 8.2 * cos(a), 8.2 * sin(a));
        cairo_line_to(cr, 14.0 * cos(a), 14.0 * sin(a));
        cairo_stroke(cr);
    }
    cairo_destroy(cr);
}

static void runway_spinner_dispose(GObject *o) {
    spinner_stop(RUNWAY_SPINNER(o));
    G_OBJECT_CLASS(runway_spinner_parent_class)->dispose(o);
}

static void runway_spinner_class_init(RunwaySpinnerClass *klass) {
    GtkWidgetClass *wc = GTK_WIDGET_CLASS(klass);
    wc->map = runway_spinner_map;
    wc->unmap = runway_spinner_unmap;
    wc->measure = runway_spinner_measure;
    wc->snapshot = runway_spinner_snapshot;
    wc->css_changed = runway_spinner_css_changed;
    G_OBJECT_CLASS(klass)->dispose = runway_spinner_dispose;
    gtk_widget_class_set_css_name(wc, "rw-spinner");
    gtk_widget_class_set_accessible_role(wc, GTK_ACCESSIBLE_ROLE_PROGRESS_BAR);
}

static void runway_spinner_init(RunwaySpinner *self) {
    self->step = 0;
    self->timer = 0;
    gtk_widget_set_can_target(GTK_WIDGET(self), FALSE);
}

GtkWidget *runway_spinner_new(void) { return g_object_new(RUNWAY_TYPE_SPINNER, NULL); }
#endif
