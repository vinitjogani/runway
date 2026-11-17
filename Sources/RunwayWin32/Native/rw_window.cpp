// App start-up, the message loop, top-level windows and their input.
#ifdef _WIN32
#include "rw_internal.h"

RwGlobals rwG;

// libdispatch's main queue on Windows signals an event when it has work;
// CoreFoundation's run loop waits on it the same way. Draining it from our
// loop keeps `Task { @MainActor in … }` and DispatchQueue.main working.
// Looked up at run time so a libdispatch without these exports still links.
typedef HANDLE (*RwMainQueueHandleFn)(void);
typedef void (*RwMainQueueDrainFn)(void *);
static RwMainQueueHandleFn mainQueueHandle = nullptr;
static RwMainQueueDrainFn mainQueueDrain = nullptr;

static void findMainQueue() {
    HMODULE d = GetModuleHandleW(L"dispatch.dll");
    if (!d) d = LoadLibraryW(L"dispatch.dll");
    if (!d) return;
    mainQueueHandle = (RwMainQueueHandleFn)(void *)GetProcAddress(d, "_dispatch_get_main_queue_handle_4CF");
    mainQueueDrain = (RwMainQueueDrainFn)(void *)GetProcAddress(d, "_dispatch_main_queue_callback_4CF");
    if (!mainQueueHandle || !mainQueueDrain) { mainQueueHandle = nullptr; mainQueueDrain = nullptr; }
}

// DWM attributes newer than some SDKs (values from dwmapi.h, Windows 11 SDK).
static const DWORD kDwmUseImmersiveDarkMode = 20;     // DWMWA_USE_IMMERSIVE_DARK_MODE (Win10 20H1+)
static const DWORD kDwmUseImmersiveDarkModeOld = 19;  // the same before 20H1
static const DWORD kDwmSystemBackdropType = 38;       // DWMWA_SYSTEMBACKDROP_TYPE (Win11 22H2+)
static const int kDwmBackdropMainWindow = 2;          // DWMSBT_MAINWINDOW (Mica)

static const wchar_t *kWindowClass = L"RunwayWindow";
static const wchar_t *kMessageClass = L"RunwayMessages";
static const UINT kWakeMessage = WM_APP + 1;

// MARK: Strings

std::wstring rwWiden(const char *s) {
    if (!s || !*s) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    if (n <= 0) return std::wstring();
    std::wstring out((size_t)n - 1, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s, -1, &out[0], n);
    return out;
}

char *rwNarrowDup(const wchar_t *s, int length) {
    if (!s) s = L"";
    int n = WideCharToMultiByte(CP_UTF8, 0, s, length, nullptr, 0, nullptr, nullptr);
    char *out = (char *)malloc((size_t)(n > 0 ? n : 0) + 1);
    if (!out) return nullptr;
    if (n > 0) WideCharToMultiByte(CP_UTF8, 0, s, length, out, n, nullptr, nullptr);
    out[n > 0 ? n : 0] = 0;
    if (length < 0 && n > 0) out[n - 1] = 0;
    return out;
}

/// A path from Swift's URL as a Windows path: backslashes, no leading slash
/// before a drive letter ("/C:/x" -> "C:\x").
std::wstring rwNativePath(const char *path) {
    std::wstring p = rwWiden(path);
    if (p.size() >= 3 && p[0] == L'/' && p[2] == L':') p.erase(0, 1);
    for (auto &ch : p) if (ch == L'/') ch = L'\\';
    return p;
}

extern "C" void rw_free(void *p) { free(p); }

extern "C" int rw_key_char(int vk) {
    UINT c = MapVirtualKeyW((UINT)vk, MAPVK_VK_TO_CHAR);
    if (c & 0x80000000u) c &= 0x7FFFFFFFu;   // dead key: still report its character
    return (int)(c & 0xFFFF);
}

// MARK: Events

int rwSendEvent(rw_event &ev) {
    if (!rwG.callback) return 0;
    return rwG.callback(&ev);
}

int rwSend(int type, void *ctx) {
    rw_event ev = {};
    ev.type = type;
    ev.ctx = ctx;
    return rwSendEvent(ev);
}

static unsigned currentMods() {
    unsigned m = 0;
    if (GetKeyState(VK_SHIFT) < 0) m |= RW_MOD_SHIFT;
    if (GetKeyState(VK_CONTROL) < 0) m |= RW_MOD_CTRL;
    if (GetKeyState(VK_MENU) < 0) m |= RW_MOD_ALT;
    if (GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0) m |= RW_MOD_WIN;
    return m;
}

// MARK: Theme

extern "C" int rw_dark_mode(void) {
    DWORD value = 1, size = sizeof(value);
    LSTATUS s = RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                             L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size);
    return s == ERROR_SUCCESS && value == 0 ? 1 : 0;
}

/// Popup menus and scroll bars follow the app theme only after this
/// undocumented uxtheme call (ordinal 135: SetPreferredAppMode on 1903+,
/// AllowDarkModeForApp on 1809; both take 1 as "allow dark"). It is what
/// Explorer and many apps use; if it is missing nothing happens.
static void allowDarkMenus() {
    HMODULE ux = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!ux) return;
    typedef int (WINAPI *SetPreferredAppModeFn)(int);
    typedef void (WINAPI *FlushMenuThemesFn)(void);
    auto setMode = (SetPreferredAppModeFn)(void *)GetProcAddress(ux, MAKEINTRESOURCEA(135));
    auto flush = (FlushMenuThemesFn)(void *)GetProcAddress(ux, MAKEINTRESOURCEA(136));
    if (setMode) setMode(1);
    if (flush) flush();
}

static void applyWindowTheme(rw_window *w) {
    BOOL dark = w->dark ? TRUE : FALSE;
    if (FAILED(DwmSetWindowAttribute(w->hwnd, kDwmUseImmersiveDarkMode, &dark, sizeof(dark))))
        DwmSetWindowAttribute(w->hwnd, kDwmUseImmersiveDarkModeOld, &dark, sizeof(dark));
    rwEditsApplyTheme(w);
    InvalidateRect(w->hwnd, nullptr, FALSE);
}

/// Mica behind the title bar, and behind the whole window when
/// RUNWAY_WIN32_MICA=full (the client area is then cleared to transparent).
static void applyBackdrop(rw_window *w) {
    int type = kDwmBackdropMainWindow;
    wchar_t env[16] = {0};
    DWORD n = GetEnvironmentVariableW(L"RUNWAY_WIN32_MICA", env, 16);
    if (n > 0 && lstrcmpiW(env, L"off") == 0) return;
    if (FAILED(DwmSetWindowAttribute(w->hwnd, kDwmSystemBackdropType, &type, sizeof(type)))) return;
    if (n > 0 && lstrcmpiW(env, L"full") == 0) {
        MARGINS m = {-1, -1, -1, -1};
        if (SUCCEEDED(DwmExtendFrameIntoClientArea(w->hwnd, &m))) w->backdrop = true;
    }
}

// MARK: Init and the loop

static LRESULT CALLBACK messageProc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    if (m == kWakeMessage) { rwSend(RW_EV_WAKE, nullptr); return 0; }
    return DefWindowProcW(h, m, wp, lp);
}

static LRESULT CALLBACK windowProc(HWND h, UINT m, WPARAM wp, LPARAM lp);

/// Common Controls 6 (cue banners, themed EDITs) without an exe manifest:
/// activate a context made from a minimal manifest for the whole process.
static void activateCommonControls6() {
    static const char manifest[] =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n"
        "<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\">\r\n"
        "<dependency><dependentAssembly><assemblyIdentity type=\"win32\" name=\"Microsoft.Windows.Common-Controls\" "
        "version=\"6.0.0.0\" processorArchitecture=\"*\" publicKeyToken=\"6595b64144ccf1df\" language=\"*\"/>"
        "</dependentAssembly></dependency></assembly>\r\n";
    wchar_t dir[MAX_PATH], path[MAX_PATH];
    if (!GetTempPathW(MAX_PATH, dir)) return;
    if (!GetTempFileNameW(dir, L"rwm", 0, path)) return;
    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(f, manifest, (DWORD)(sizeof(manifest) - 1), &written, nullptr);
    CloseHandle(f);
    ACTCTXW ctx = {};
    ctx.cbSize = sizeof(ctx);
    ctx.lpSource = path;
    HANDLE act = CreateActCtxW(&ctx);
    DeleteFileW(path);
    if (act == INVALID_HANDLE_VALUE) return;
    ULONG_PTR cookie = 0;
    ActivateActCtx(act, &cookie);   // kept active for the life of the process
}

extern "C" int rw_init(rw_event_fn callback) {
    rwG.callback = callback;
    rwG.instance = GetModuleHandleW(nullptr);
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    activateCommonControls6();
    allowDarkMenus();
    findMainQueue();

    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &rwG.d2d))) return 0;
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), (IUnknown **)&rwG.dwrite))) return 0;
    if (rw_font_available("Segoe UI Variable Text")) rwG.uiFamily = L"Segoe UI Variable Text";

    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = windowProc;
    wc.hInstance = rwG.instance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hIcon = LoadIconW(rwG.instance, MAKEINTRESOURCEW(1));
    if (!wc.hIcon) wc.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wc.lpszClassName = kWindowClass;
    RegisterClassExW(&wc);

    WNDCLASSEXW mc = {};
    mc.cbSize = sizeof(mc);
    mc.lpfnWndProc = messageProc;
    mc.hInstance = rwG.instance;
    mc.lpszClassName = kMessageClass;
    RegisterClassExW(&mc);
    rwG.messageWindow = CreateWindowExW(0, kMessageClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, rwG.instance, nullptr);
    return rwG.messageWindow ? 1 : 0;
}

extern "C" int rw_font_available(const char *family) {
    if (!rwG.dwrite) return 0;
    IDWriteFontCollection *fonts = nullptr;
    if (FAILED(rwG.dwrite->GetSystemFontCollection(&fonts, FALSE))) return 0;
    UINT32 index = 0;
    BOOL exists = FALSE;
    std::wstring name = rwWiden(family);
    fonts->FindFamilyName(name.c_str(), &index, &exists);
    fonts->Release();
    return exists ? 1 : 0;
}

static bool pumpMessages(volatile int *done) {
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) {
            if (done) PostQuitMessage((int)msg.wParam);   // let the outer loop see it too
            return false;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
        if (done && *done) return true;
    }
    return true;
}

static void runLoop(volatile int *done) {
    HANDLE mainQueue = mainQueueHandle ? mainQueueHandle() : nullptr;
    for (;;) {
        if (done && *done) return;
        DWORD n = mainQueue ? 1 : 0;
        DWORD r = MsgWaitForMultipleObjectsEx(n, mainQueue ? &mainQueue : nullptr, INFINITE, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (mainQueue && r == WAIT_OBJECT_0) {
            ResetEvent(mainQueue);
            mainQueueDrain(nullptr);
        }
        if (!pumpMessages(done)) return;
    }
}

extern "C" void rw_run(void) { runLoop(nullptr); }
extern "C" void rw_run_modal(volatile int *done) { runLoop(done); }
extern "C" void rw_quit(void) { PostQuitMessage(0); }
extern "C" void rw_wake(void) { PostMessageW(rwG.messageWindow, kWakeMessage, 0, 0); }

// MARK: Windows

static DWORD windowStyle(bool resizable) {
    return resizable ? WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN
                     : (WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN);
}

/// Outer window size for a content size in DIPs.
static SIZE outerSize(DWORD style, UINT dpi, double width, double height) {
    RECT r = {0, 0, (LONG)lround(width * dpi / 96.0), (LONG)lround(height * dpi / 96.0)};
    AdjustWindowRectExForDpi(&r, style, FALSE, 0, dpi);
    SIZE s = {r.right - r.left, r.bottom - r.top};
    return s;
}

extern "C" rw_window *rw_window_create(const char *title, double width, double height, int resizable, rw_window *parent, int modal, void *ctx) {
    rw_window *w = new rw_window();
    w->ctx = ctx;
    w->parent = parent;
    w->modal = modal != 0;
    w->resizable = resizable != 0;
    w->dark = rw_dark_mode() != 0;
    w->cursor = LoadCursorW(nullptr, IDC_ARROW);
    DWORD style = windowStyle(w->resizable);
    UINT dpi = parent ? GetDpiForWindow(parent->hwnd) : GetDpiForSystem();
    SIZE s = outerSize(style, dpi, width, height);
    std::wstring t = rwWiden(title);
    HWND h = CreateWindowExW(0, kWindowClass, t.c_str(), style, CW_USEDEFAULT, CW_USEDEFAULT, s.cx, s.cy,
                             parent ? parent->hwnd : nullptr, nullptr, rwG.instance, w);
    if (!h) { delete w; return nullptr; }
    w->dpi = GetDpiForWindow(h);
    if (w->dpi != dpi) {
        s = outerSize(style, w->dpi, width, height);
        SetWindowPos(h, nullptr, 0, 0, s.cx, s.cy, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
    applyWindowTheme(w);
    applyBackdrop(w);
    return w;
}

extern "C" void rw_window_destroy(rw_window *w) {
    if (!w || !w->hwnd) return;
    if (w->modal && w->parent && w->parent->hwnd) EnableWindow(w->parent->hwnd, TRUE);
    DestroyWindow(w->hwnd);   // WM_NCDESTROY frees w
}

extern "C" void rw_window_set_title(rw_window *w, const char *title) {
    std::wstring t = rwWiden(title);
    SetWindowTextW(w->hwnd, t.c_str());
}

extern "C" void rw_window_set_content_size(rw_window *w, double width, double height) {
    DWORD style = (DWORD)GetWindowLongPtrW(w->hwnd, GWL_STYLE);
    SIZE s = outerSize(style, w->dpi, width, height);
    SetWindowPos(w->hwnd, nullptr, 0, 0, s.cx, s.cy, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

extern "C" void rw_window_get_content_size(rw_window *w, double *width, double *height) {
    RECT r;
    GetClientRect(w->hwnd, &r);
    *width = r.right / w->scale();
    *height = r.bottom / w->scale();
}

extern "C" void rw_window_set_min_size(rw_window *w, double width, double height) {
    w->minWidth = width;
    w->minHeight = height;
}

extern "C" void rw_window_set_resizable(rw_window *w, int resizable) {
    w->resizable = resizable != 0;
    LONG_PTR style = GetWindowLongPtrW(w->hwnd, GWL_STYLE);
    LONG_PTR keep = style & (WS_VISIBLE | WS_MINIMIZE | WS_MAXIMIZE | WS_DISABLED);
    SetWindowLongPtrW(w->hwnd, GWL_STYLE, (LONG_PTR)windowStyle(w->resizable) | keep);
    SetWindowPos(w->hwnd, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

extern "C" void rw_window_center(rw_window *w) {
    RECT r, area;
    GetWindowRect(w->hwnd, &r);
    if (w->parent && w->parent->hwnd) {
        GetWindowRect(w->parent->hwnd, &area);
    } else {
        MONITORINFO mi = {};
        mi.cbSize = sizeof(mi);
        GetMonitorInfoW(MonitorFromWindow(w->hwnd, MONITOR_DEFAULTTONEAREST), &mi);
        area = mi.rcWork;
    }
    int width = r.right - r.left, height = r.bottom - r.top;
    int x = area.left + (area.right - area.left - width) / 2;
    int y = area.top + (area.bottom - area.top - height) / 3;   // a little above centre, like the Mac
    SetWindowPos(w->hwnd, nullptr, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

extern "C" void rw_window_show(rw_window *w) {
    if (!w->shown) {
        w->shown = true;
        if (w->parent) rw_window_center(w);
        if (w->modal && w->parent && w->parent->hwnd) EnableWindow(w->parent->hwnd, FALSE);
    }
    ShowWindow(w->hwnd, IsIconic(w->hwnd) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(w->hwnd);
}

extern "C" void rw_window_invalidate(rw_window *w) {
    if (w && w->hwnd && !w->painting) InvalidateRect(w->hwnd, nullptr, FALSE);
}

extern "C" void rw_window_set_dark(rw_window *w, int dark) {
    w->dark = dark != 0;
    applyWindowTheme(w);
}

extern "C" void rw_window_set_cursor(rw_window *w, int cursor) {
    LPCWSTR id = cursor == RW_CURSOR_HAND ? IDC_HAND : cursor == RW_CURSOR_IBEAM ? IDC_IBEAM : IDC_ARROW;
    HCURSOR c = LoadCursorW(nullptr, id);
    if (c != w->cursor) {
        w->cursor = c;
        POINT p;
        GetCursorPos(&p);
        if (WindowFromPoint(p) == w->hwnd) SetCursor(c);
    }
}

extern "C" void rw_window_capture(rw_window *w, int on) {
    if (on) SetCapture(w->hwnd);
    else if (GetCapture() == w->hwnd) ReleaseCapture();
}

extern "C" void rw_window_set_timer(rw_window *w, int ms) {
    if (ms > 0) {
        if (!w->timer) w->timer = SetTimer(w->hwnd, 1, (UINT)ms, nullptr);
    } else if (w->timer) {
        KillTimer(w->hwnd, 1);
        w->timer = 0;
    }
}

extern "C" double rw_window_scale(rw_window *w) { return w ? w->scale() : 1.0; }
extern "C" int rw_window_backdrop(rw_window *w) { return w && w->backdrop ? 1 : 0; }
extern "C" void rw_window_focus(rw_window *w) { if (w && w->hwnd) SetFocus(w->hwnd); }

// MARK: The window procedure

static void pointerEvent(rw_window *w, int type, LPARAM lp, int button) {
    rw_event ev = {};
    ev.type = type;
    ev.ctx = w->ctx;
    ev.x = GET_X_LPARAM(lp) / w->scale();
    ev.y = GET_Y_LPARAM(lp) / w->scale();
    ev.button = button;
    ev.mods = currentMods();
    rwSendEvent(ev);
}

static void wheelEvent(rw_window *w, WPARAM wp, LPARAM lp, bool horizontal) {
    POINT p = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
    ScreenToClient(w->hwnd, &p);
    UINT lines = 3;
    SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
    if (lines == WHEEL_PAGESCROLL || lines == 0) lines = 3;
    double notches = GET_WHEEL_DELTA_WPARAM(wp) / (double)WHEEL_DELTA;
    double amount = notches * lines * 16.0;   // DIPs: about a text line per wheel line
    rw_event ev = {};
    ev.type = RW_EV_WHEEL;
    ev.ctx = w->ctx;
    ev.x = p.x / w->scale();
    ev.y = p.y / w->scale();
    ev.mods = currentMods();
    if (horizontal) ev.dx = amount;
    else if (ev.mods & RW_MOD_SHIFT) ev.dx = -amount;
    else ev.dy = -amount;
    rwSendEvent(ev);
}

void rwPaintWindow(rw_window *w);   // rw_draw.cpp

static LRESULT CALLBACK windowProc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    rw_window *w = (rw_window *)GetWindowLongPtrW(h, GWLP_USERDATA);
    if (m == WM_NCCREATE) {
        w = (rw_window *)((CREATESTRUCTW *)lp)->lpCreateParams;
        w->hwnd = h;
        SetWindowLongPtrW(h, GWLP_USERDATA, (LONG_PTR)w);
        return DefWindowProcW(h, m, wp, lp);
    }
    if (!w) return DefWindowProcW(h, m, wp, lp);

    switch (m) {
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(h, &ps);
        rwPaintWindow(w);
        EndPaint(h, &ps);
        return 0;
    }
    case WM_SIZE: {
        UINT width = LOWORD(lp), height = HIWORD(lp);
        if (w->rt) w->rt->Resize(D2D1::SizeU(width, height));
        if (wp != SIZE_MINIMIZED) {
            rw_event ev = {};
            ev.type = RW_EV_RESIZE;
            ev.ctx = w->ctx;
            ev.dx = width / w->scale();
            ev.dy = height / w->scale();
            rwSendEvent(ev);
        }
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_DPICHANGED: {
        w->dpi = HIWORD(wp);
        if (w->rt) w->rt->SetDpi((float)w->dpi, (float)w->dpi);
        RECT *r = (RECT *)lp;
        SetWindowPos(h, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        rwEditsRefreshFonts(w);
        rwSend(RW_EV_DPI_CHANGED, w->ctx);
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_GETMINMAXINFO: {
        if (w->minWidth > 0 || w->minHeight > 0) {
            DWORD style = (DWORD)GetWindowLongPtrW(h, GWL_STYLE);
            SIZE s = outerSize(style, w->dpi, w->minWidth, w->minHeight);
            MINMAXINFO *mmi = (MINMAXINFO *)lp;
            mmi->ptMinTrackSize.x = s.cx;
            mmi->ptMinTrackSize.y = s.cy;
        }
        return 0;
    }
    case WM_SETCURSOR:
        if (LOWORD(lp) == HTCLIENT && (HWND)wp == h) { SetCursor(w->cursor); return TRUE; }
        break;
    case WM_MOUSEMOVE:
        if (!w->tracking) {
            TRACKMOUSEEVENT t = {};
            t.cbSize = sizeof(t);
            t.dwFlags = TME_LEAVE;
            t.hwndTrack = h;
            TrackMouseEvent(&t);
            w->tracking = true;
        }
        pointerEvent(w, RW_EV_MOUSE_MOVE, lp, 0);
        return 0;
    case WM_MOUSELEAVE:
        w->tracking = false;
        rwSend(RW_EV_MOUSE_LEAVE, w->ctx);
        return 0;
    case WM_LBUTTONDOWN: case WM_LBUTTONDBLCLK: pointerEvent(w, RW_EV_MOUSE_DOWN, lp, 0); return 0;
    case WM_RBUTTONDOWN: case WM_RBUTTONDBLCLK: pointerEvent(w, RW_EV_MOUSE_DOWN, lp, 1); return 0;
    case WM_MBUTTONDOWN: case WM_MBUTTONDBLCLK: pointerEvent(w, RW_EV_MOUSE_DOWN, lp, 2); return 0;
    case WM_LBUTTONUP: pointerEvent(w, RW_EV_MOUSE_UP, lp, 0); return 0;
    case WM_RBUTTONUP: pointerEvent(w, RW_EV_MOUSE_UP, lp, 1); return 0;
    case WM_MBUTTONUP: pointerEvent(w, RW_EV_MOUSE_UP, lp, 2); return 0;
    case WM_CAPTURECHANGED:
        if ((HWND)lp != h) {
            rw_event ev = {};
            ev.type = RW_EV_MOUSE_UP;
            ev.ctx = w->ctx;
            ev.x = -1e6;   // cancelled: outside everything
            ev.y = -1e6;
            ev.button = -1;
            rwSendEvent(ev);
        }
        return 0;
    case WM_MOUSEWHEEL: wheelEvent(w, wp, lp, false); return 0;
    case WM_MOUSEHWHEEL: wheelEvent(w, wp, lp, true); return 0;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN: {
        rw_event ev = {};
        ev.type = RW_EV_KEY_DOWN;
        ev.ctx = w->ctx;
        ev.key = (int)wp;
        ev.mods = currentMods();
        if (rwSendEvent(ev)) { w->swallowChar = true; return 0; }
        break;
    }
    case WM_CHAR:
    case WM_SYSCHAR:
        if (w->swallowChar) { w->swallowChar = false; return 0; }
        break;
    case WM_TIMER:
        if (wp == 1) { rwSend(RW_EV_TIMER, w->ctx); return 0; }
        break;
    case WM_SETTINGCHANGE:
        if (lp && lstrcmpiW((const wchar_t *)lp, L"ImmersiveColorSet") == 0) {
            allowDarkMenus();
            rwSend(RW_EV_THEME_CHANGED, nullptr);
        }
        break;
    case WM_COMMAND:
        if (lp) { rwEditCommand((HWND)lp, HIWORD(wp)); return 0; }
        break;
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORSTATIC: {
        bool handled = false;
        LRESULT r = rwEditColor((HWND)lp, (HDC)wp, &handled);
        if (handled) return r;
        break;
    }
    case WM_CLOSE:
        rwSend(RW_EV_CLOSE_REQUEST, w->ctx);
        return 0;
    case WM_DESTROY:
        if (w->modal && w->parent && w->parent->hwnd) EnableWindow(w->parent->hwnd, TRUE);
        if (w->timer) { KillTimer(h, 1); w->timer = 0; }
        rwSend(RW_EV_DESTROYED, w->ctx);
        return 0;
    case WM_NCDESTROY:
        rwEditsWindowGone(w);
        rwDiscardTarget(w);
        SetWindowLongPtrW(h, GWLP_USERDATA, 0);
        w->hwnd = nullptr;
        delete w;
        return DefWindowProcW(h, m, wp, lp);
    }
    return DefWindowProcW(h, m, wp, lp);
}

#endif
