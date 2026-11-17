// A small C surface over WebKitGTK 6 for Runway's WebKit: creating views
// with a content manager, JavaScript evaluation with JSON results, load and
// policy signals, script message handlers and user scripts. Without
// WebKitGTK (Windows, or a build without it) every call reports failure.
#ifndef RUNWAY_WEBKIT_H
#define RUNWAY_WEBKIT_H

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when built with WebKitGTK.
int rw_available(void);

void *rw_ucm_new(void);
void rw_unref(void *object);

/// A WebKitWebView (a GtkWidget, floating ref sunk and owned by the caller).
void *rw_webview_new(void *ucm, int javascript, int developer_extras);

typedef void (*rw_js_cb)(void *ctx, const char *json, const char *error);
void rw_evaluate(void *view, const char *script, rw_js_cb cb, void *ctx);

enum { RW_LOAD_STARTED = 0, RW_LOAD_REDIRECTED = 1, RW_LOAD_COMMITTED = 2, RW_LOAD_FINISHED = 3, RW_LOAD_FAILED = 4 };
typedef void (*rw_load_cb)(void *ctx, int event, const char *uri, const char *error, int code);
void rw_connect_load(void *view, rw_load_cb cb, void *ctx);

/// Navigation policy: return 1 when the decision will be made later with rw_policy_decide.
enum { RW_NAV_LINK = 0, RW_NAV_FORM = 1, RW_NAV_BACK_FORWARD = 2, RW_NAV_RELOAD = 3, RW_NAV_RESUBMIT = 4, RW_NAV_OTHER = 5 };
typedef int (*rw_policy_cb)(void *ctx, void *decision, const char *uri, int new_window, int nav_type);
void rw_connect_policy(void *view, rw_policy_cb cb, void *ctx);
void rw_policy_decide(void *decision, int allow);

typedef void (*rw_msg_cb)(void *ctx, const char *name, const char *json);
int rw_register_handler(void *ucm, const char *name, rw_msg_cb cb, void *ctx);
void rw_unregister_handler(void *ucm, const char *name);
void rw_add_user_script(void *ucm, const char *source, int at_document_start, int main_frame_only);
void rw_remove_all_user_scripts(void *ucm);

void rw_load_uri(void *view, const char *uri);
void rw_load_html(void *view, const char *html, const char *base_uri);
void rw_reload(void *view);
void rw_stop(void *view);
void rw_go_back(void *view);
void rw_go_forward(void *view);
int rw_can_go_back(void *view);
int rw_can_go_forward(void *view);
int rw_is_loading(void *view);
double rw_progress(void *view);
/// Strings owned by the view (valid until the next change).
const char *rw_title(void *view);
const char *rw_uri(void *view);
void rw_set_user_agent(void *view, const char *ua);
void rw_set_zoom(void *view, double zoom);
double rw_zoom(void *view);

#ifdef __cplusplus
}
#endif
#endif
