#if defined(__linux__) || defined(__FreeBSD__)
// The GLib main loop drives Swift's main-thread machinery too: the main
// dispatch queue (DispatchQueue.main, MainActor jobs) through libdispatch's
// eventfd, and RunLoop.main timers through a GSource that asks Foundation for
// its next fire date. Nothing polls: idle, the loop sleeps until a timer is
// due or the queue is woken.
#include "runway_gtk.h"
#include <glib-unix.h>
#include <unistd.h>
#include <stdint.h>

extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);

static gboolean drain_main_queue(gint fd, GIOCondition cond, gpointer data) {
    uint64_t value;
    (void)!read(fd, &value, sizeof value);   /* reset the eventfd */
    _dispatch_main_queue_callback_4CF(NULL);
    (void)cond; (void)data;
    return G_SOURCE_CONTINUE;
}

typedef struct {
    GSource source;
    RunwayTimerFunc next;
    void *data;
} TimerSource;

// Foundation's CoreFoundation (exported by libFoundation): the next timer's
// fire date, read without running the run loop.
extern void *CFRunLoopGetMain(void);
extern double CFRunLoopGetNextTimerFireDate(void *rl, const void *mode);
extern double CFAbsoluteTimeGetCurrent(void);
extern const void *kCFRunLoopDefaultMode;

/* ms until RunLoop.main's next timer: 0 when one is due, -1 for none. */
static int timer_wait_ms(void) {
    double next = CFRunLoopGetNextTimerFireDate(CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    if (next <= 0) return -1;
    double ms = (next - CFAbsoluteTimeGetCurrent()) * 1000.0;
    if (ms <= 0) return 0;
    if (ms > 86400000.0) return -1;
    return (int)ms + 1;
}

// prepare and check only look: firing a timer runs app code, which may
// iterate the main context itself (a synchronous clipboard read, a modal
// loop), and GLib forbids that from prepare/check. Timers fire in dispatch.
static gboolean timer_prepare(GSource *s, gint *timeout) {
    (void)s;
    int ms = timer_wait_ms();
    *timeout = ms;
    return ms == 0;
}
static gboolean timer_check(GSource *s) { (void)s; return timer_wait_ms() == 0; }
static gboolean timer_dispatch(GSource *s, GSourceFunc cb, gpointer d) {
    TimerSource *t = (TimerSource *)s;
    (void)t->next(t->data);   /* fires due timers (RunLoop.main.limitDate) */
    (void)cb; (void)d;
    return G_SOURCE_CONTINUE;
}
static GSourceFuncs timer_funcs = { timer_prepare, timer_check, timer_dispatch, NULL, NULL, NULL };

void runway_loop_attach(RunwayTimerFunc next_timer, void *user_data) {
    static gboolean attached = FALSE;
    if (attached) return;
    attached = TRUE;
    int fd = _dispatch_get_main_queue_handle_4CF();
    if (fd >= 0) g_unix_fd_add(fd, G_IO_IN, drain_main_queue, NULL);
    TimerSource *t = (TimerSource *)g_source_new(&timer_funcs, sizeof(TimerSource));
    t->next = next_timer;
    t->data = user_data;
    g_source_attach(&t->source, NULL);
}
#endif
