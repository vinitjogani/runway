#include "runway_webkit.h"
#include <stddef.h>
#include <string.h>

#if defined(__linux__) && __has_include(<webkit/webkit.h>)
#include <webkit/webkit.h>

int rw_available(void) { return 1; }

void *rw_ucm_new(void) { return webkit_user_content_manager_new(); }
void rw_unref(void *object) { if (object) g_object_unref(object); }

void *rw_webview_new(void *ucm, int javascript, int developer_extras) {
    WebKitSettings *settings = webkit_settings_new();
    webkit_settings_set_enable_javascript(settings, javascript ? TRUE : FALSE);
    webkit_settings_set_enable_developer_extras(settings, developer_extras ? TRUE : FALSE);
    GtkWidget *w = GTK_WIDGET(g_object_new(WEBKIT_TYPE_WEB_VIEW, "user-content-manager", ucm, "settings", settings, NULL));
    g_object_unref(settings);
    g_object_ref_sink(w);
    return w;
}

typedef struct JSCall { rw_js_cb cb; void *ctx; } JSCall;

static void js_done(GObject *source, GAsyncResult *res, gpointer data) {
    JSCall *c = (JSCall *)data;
    GError *e = NULL;
    JSCValue *v = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(source), res, &e);
    if (!v) {
        c->cb(c->ctx, NULL, e ? e->message : "JavaScript failed");
    } else {
        char *json = jsc_value_is_undefined(v) ? NULL : jsc_value_to_json(v, 0);
        c->cb(c->ctx, json ? json : "null", NULL);
        g_free(json);
        g_object_unref(v);
    }
    if (e) g_error_free(e);
    g_free(c);
}

void rw_evaluate(void *view, const char *script, rw_js_cb cb, void *ctx) {
    JSCall *c = g_new0(JSCall, 1);
    c->cb = cb;
    c->ctx = ctx;
    webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(view), script, -1, NULL, NULL, NULL, js_done, c);
}

typedef struct LoadCtx { rw_load_cb cb; void *ctx; } LoadCtx;

static void on_load_changed(WebKitWebView *v, WebKitLoadEvent ev, gpointer data) {
    LoadCtx *l = (LoadCtx *)data;
    int e = ev == WEBKIT_LOAD_STARTED ? RW_LOAD_STARTED : ev == WEBKIT_LOAD_REDIRECTED ? RW_LOAD_REDIRECTED
          : ev == WEBKIT_LOAD_COMMITTED ? RW_LOAD_COMMITTED : RW_LOAD_FINISHED;
    l->cb(l->ctx, e, webkit_web_view_get_uri(v), NULL, 0);
}

static gboolean on_load_failed(WebKitWebView *v, WebKitLoadEvent ev, gchar *uri, GError *error, gpointer data) {
    LoadCtx *l = (LoadCtx *)data;
    l->cb(l->ctx, RW_LOAD_FAILED, uri, error ? error->message : "load failed", error ? error->code : 0);
    return FALSE;
}

void rw_connect_load(void *view, rw_load_cb cb, void *ctx) {
    LoadCtx *l = g_new0(LoadCtx, 1);
    l->cb = cb;
    l->ctx = ctx;
    g_signal_connect_data(view, "load-changed", G_CALLBACK(on_load_changed), l, NULL, 0);
    g_signal_connect_data(view, "load-failed", G_CALLBACK(on_load_failed), l, (GClosureNotify)g_free, 0);
}

typedef struct PolicyCtx { rw_policy_cb cb; void *ctx; } PolicyCtx;

static gboolean on_decide(WebKitWebView *v, WebKitPolicyDecision *d, WebKitPolicyDecisionType type, gpointer data) {
    PolicyCtx *p = (PolicyCtx *)data;
    if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) return FALSE;
    WebKitNavigationAction *a = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(d));
    WebKitURIRequest *r = webkit_navigation_action_get_request(a);
    int nav;
    switch (webkit_navigation_action_get_navigation_type(a)) {
    case WEBKIT_NAVIGATION_TYPE_LINK_CLICKED: nav = RW_NAV_LINK; break;
    case WEBKIT_NAVIGATION_TYPE_FORM_SUBMITTED: nav = RW_NAV_FORM; break;
    case WEBKIT_NAVIGATION_TYPE_BACK_FORWARD: nav = RW_NAV_BACK_FORWARD; break;
    case WEBKIT_NAVIGATION_TYPE_RELOAD: nav = RW_NAV_RELOAD; break;
    case WEBKIT_NAVIGATION_TYPE_FORM_RESUBMITTED: nav = RW_NAV_RESUBMIT; break;
    default: nav = RW_NAV_OTHER; break;
    }
    g_object_ref(d);
    if (!p->cb(p->ctx, d, webkit_uri_request_get_uri(r), type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION, nav)) {
        g_object_unref(d);
        return FALSE;
    }
    return TRUE;
}

void rw_connect_policy(void *view, rw_policy_cb cb, void *ctx) {
    PolicyCtx *p = g_new0(PolicyCtx, 1);
    p->cb = cb;
    p->ctx = ctx;
    g_signal_connect_data(view, "decide-policy", G_CALLBACK(on_decide), p, (GClosureNotify)g_free, 0);
}

void rw_policy_decide(void *decision, int allow) {
    if (allow) webkit_policy_decision_use(WEBKIT_POLICY_DECISION(decision));
    else webkit_policy_decision_ignore(WEBKIT_POLICY_DECISION(decision));
    g_object_unref(decision);
}

typedef struct MsgCtx { rw_msg_cb cb; void *ctx; char *name; } MsgCtx;

static void on_message(WebKitUserContentManager *m, JSCValue *v, gpointer data) {
    MsgCtx *c = (MsgCtx *)data;
    char *json = jsc_value_to_json(v, 0);
    c->cb(c->ctx, c->name, json ? json : "null");
    g_free(json);
}

static void free_msg(gpointer data, GClosure *closure) {
    MsgCtx *c = (MsgCtx *)data;
    g_free(c->name);
    g_free(c);
}

int rw_register_handler(void *ucm, const char *name, rw_msg_cb cb, void *ctx) {
    if (!webkit_user_content_manager_register_script_message_handler(WEBKIT_USER_CONTENT_MANAGER(ucm), name, NULL)) return 0;
    MsgCtx *c = g_new0(MsgCtx, 1);
    c->cb = cb;
    c->ctx = ctx;
    c->name = g_strdup(name);
    char *signal = g_strdup_printf("script-message-received::%s", name);
    g_signal_connect_data(ucm, signal, G_CALLBACK(on_message), c, free_msg, 0);
    g_free(signal);
    return 1;
}

void rw_unregister_handler(void *ucm, const char *name) {
    webkit_user_content_manager_unregister_script_message_handler(WEBKIT_USER_CONTENT_MANAGER(ucm), name, NULL);
}

void rw_add_user_script(void *ucm, const char *source, int at_document_start, int main_frame_only) {
    WebKitUserScript *s = webkit_user_script_new(source,
        main_frame_only ? WEBKIT_USER_CONTENT_INJECT_TOP_FRAME : WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
        at_document_start ? WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START : WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END, NULL, NULL);
    webkit_user_content_manager_add_script(WEBKIT_USER_CONTENT_MANAGER(ucm), s);
    webkit_user_script_unref(s);
}

void rw_remove_all_user_scripts(void *ucm) { webkit_user_content_manager_remove_all_scripts(WEBKIT_USER_CONTENT_MANAGER(ucm)); }

void rw_load_uri(void *view, const char *uri) { webkit_web_view_load_uri(WEBKIT_WEB_VIEW(view), uri); }
void rw_load_html(void *view, const char *html, const char *base_uri) { webkit_web_view_load_html(WEBKIT_WEB_VIEW(view), html, base_uri); }
void rw_reload(void *view) { webkit_web_view_reload(WEBKIT_WEB_VIEW(view)); }
void rw_stop(void *view) { webkit_web_view_stop_loading(WEBKIT_WEB_VIEW(view)); }
void rw_go_back(void *view) { webkit_web_view_go_back(WEBKIT_WEB_VIEW(view)); }
void rw_go_forward(void *view) { webkit_web_view_go_forward(WEBKIT_WEB_VIEW(view)); }
int rw_can_go_back(void *view) { return webkit_web_view_can_go_back(WEBKIT_WEB_VIEW(view)); }
int rw_can_go_forward(void *view) { return webkit_web_view_can_go_forward(WEBKIT_WEB_VIEW(view)); }
int rw_is_loading(void *view) { return webkit_web_view_is_loading(WEBKIT_WEB_VIEW(view)); }
double rw_progress(void *view) { return webkit_web_view_get_estimated_load_progress(WEBKIT_WEB_VIEW(view)); }
const char *rw_title(void *view) { return webkit_web_view_get_title(WEBKIT_WEB_VIEW(view)); }
const char *rw_uri(void *view) { return webkit_web_view_get_uri(WEBKIT_WEB_VIEW(view)); }
void rw_set_user_agent(void *view, const char *ua) {
    webkit_settings_set_user_agent(webkit_web_view_get_settings(WEBKIT_WEB_VIEW(view)), ua);
}
void rw_set_zoom(void *view, double zoom) { webkit_web_view_set_zoom_level(WEBKIT_WEB_VIEW(view), zoom); }
double rw_zoom(void *view) { return webkit_web_view_get_zoom_level(WEBKIT_WEB_VIEW(view)); }

#else

int rw_available(void) { return 0; }
void *rw_ucm_new(void) { return NULL; }
void rw_unref(void *o) { (void)o; }
void *rw_webview_new(void *u, int j, int d) { (void)u; (void)j; (void)d; return NULL; }
void rw_evaluate(void *v, const char *s, rw_js_cb cb, void *ctx) { (void)v; (void)s; cb(ctx, NULL, "Web views aren't available on this platform"); }
void rw_connect_load(void *v, rw_load_cb cb, void *ctx) { (void)v; (void)cb; (void)ctx; }
void rw_connect_policy(void *v, rw_policy_cb cb, void *ctx) { (void)v; (void)cb; (void)ctx; }
void rw_policy_decide(void *d, int a) { (void)d; (void)a; }
int rw_register_handler(void *u, const char *n, rw_msg_cb cb, void *ctx) { (void)u; (void)n; (void)cb; (void)ctx; return 0; }
void rw_unregister_handler(void *u, const char *n) { (void)u; (void)n; }
void rw_add_user_script(void *u, const char *s, int a, int m) { (void)u; (void)s; (void)a; (void)m; }
void rw_remove_all_user_scripts(void *u) { (void)u; }
void rw_load_uri(void *v, const char *u) { (void)v; (void)u; }
void rw_load_html(void *v, const char *h, const char *b) { (void)v; (void)h; (void)b; }
void rw_reload(void *v) { (void)v; }
void rw_stop(void *v) { (void)v; }
void rw_go_back(void *v) { (void)v; }
void rw_go_forward(void *v) { (void)v; }
int rw_can_go_back(void *v) { (void)v; return 0; }
int rw_can_go_forward(void *v) { (void)v; return 0; }
int rw_is_loading(void *v) { (void)v; return 0; }
double rw_progress(void *v) { (void)v; return 0; }
const char *rw_title(void *v) { (void)v; return NULL; }
const char *rw_uri(void *v) { (void)v; return NULL; }
void rw_set_user_agent(void *v, const char *u) { (void)v; (void)u; }
void rw_set_zoom(void *v, double z) { (void)v; (void)z; }
double rw_zoom(void *v) { (void)v; return 1; }

#endif
