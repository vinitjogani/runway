// What AppKit's view system needs beyond SwiftUI's widgets: raw keys with
// their names and characters, the menu bar, popups for popovers, cursors,
// drag and drop, screens, window moves, rich text (a RichEdit control) and
// tray icons.
#ifdef _WIN32
#include "rw_internal.h"
#include <stdio.h>

unsigned rwCurrentMods() {
    unsigned m = 0;
    if (GetKeyState(VK_SHIFT) < 0) m |= RW_MOD_SHIFT;
    if (GetKeyState(VK_CONTROL) < 0) m |= RW_MOD_CTRL;
    if (GetKeyState(VK_MENU) < 0) m |= RW_MOD_ALT;
    if (GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0) m |= RW_MOD_WIN;
    return m;
}

// MARK: Raw keys

/// The X11 keysym name AppKit's tables use for a virtual key.
static const char *keyName(WPARAM vk, bool shift, bool extended, wchar_t ch) {
    static char buf[8];
    switch (vk) {
    case VK_RETURN: return extended ? "KP_Enter" : "Return";
    case VK_BACK: return "BackSpace";
    case VK_TAB: return shift ? "ISO_Left_Tab" : "Tab";
    case VK_ESCAPE: return "Escape";
    case VK_SPACE: return "space";
    case VK_LEFT: return "Left";
    case VK_RIGHT: return "Right";
    case VK_UP: return "Up";
    case VK_DOWN: return "Down";
    case VK_PRIOR: return "Page_Up";
    case VK_NEXT: return "Page_Down";
    case VK_HOME: return "Home";
    case VK_END: return "End";
    case VK_DELETE: return "Delete";
    case VK_INSERT: return "Insert";
    case VK_HELP: return "Help";
    case VK_SHIFT: case VK_LSHIFT: return "Shift_L";
    case VK_RSHIFT: return "Shift_R";
    case VK_CONTROL: case VK_LCONTROL: return extended ? "Control_R" : "Control_L";
    case VK_RCONTROL: return "Control_R";
    case VK_MENU: case VK_LMENU: return extended ? "Alt_R" : "Alt_L";
    case VK_RMENU: return "Alt_R";
    case VK_LWIN: return "Super_L";
    case VK_RWIN: return "Super_R";
    case VK_CAPITAL: return "Caps_Lock";
    case VK_DECIMAL: return "KP_Decimal";
    case VK_MULTIPLY: return "KP_Multiply";
    case VK_ADD: return "KP_Add";
    case VK_SUBTRACT: return "KP_Subtract";
    case VK_DIVIDE: return "KP_Divide";
    case VK_APPS: return "Menu";
    }
    if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9) { snprintf(buf, sizeof buf, "KP_%d", (int)(vk - VK_NUMPAD0)); return buf; }
    if (vk >= VK_F1 && vk <= VK_F24) { snprintf(buf, sizeof buf, "F%d", (int)(vk - VK_F1 + 1)); return buf; }
    if (vk >= '0' && vk <= '9') { buf[0] = (char)vk; buf[1] = 0; return buf; }
    if (vk >= 'A' && vk <= 'Z') { buf[0] = (char)(shift ? vk : vk + 32); buf[1] = 0; return buf; }
    switch (ch) {
    case L',': return "comma";
    case L'.': return "period";
    case L'/': return "slash";
    case L';': return "semicolon";
    case L'\'': return "apostrophe";
    case L'[': return "bracketleft";
    case L']': return "bracketright";
    case L'\\': return "backslash";
    case L'-': return "minus";
    case L'=': return "equal";
    case L'`': return "grave";
    }
    if (ch > 32 && ch < 127) { buf[0] = (char)ch; buf[1] = 0; return buf; }
    return "";
}

static bool isModifierKey(WPARAM vk) {
    switch (vk) {
    case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT: case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL:
    case VK_MENU: case VK_LMENU: case VK_RMENU: case VK_LWIN: case VK_RWIN: case VK_CAPITAL:
        return true;
    }
    return false;
}

/// What a key types with Shift (and AltGr) but without Ctrl or Alt, as on
/// the Mac, where ⌘A reports "a".
static std::wstring keyCharacters(WPARAM vk, LPARAM lp) {
    BYTE state[256];
    if (!GetKeyboardState(state)) return std::wstring();
    bool altGr = (state[VK_CONTROL] & 0x80) && (state[VK_MENU] & 0x80) && (state[VK_RMENU] & 0x80);
    if (!altGr) {
        state[VK_CONTROL] = state[VK_LCONTROL] = state[VK_RCONTROL] = 0;
        state[VK_MENU] = state[VK_LMENU] = state[VK_RMENU] = 0;
    }
    wchar_t out[8] = {0};
    UINT scan = (UINT)((lp >> 16) & 0xFF);
    // Flag 4: leave the keyboard state (dead keys) alone (Windows 10 1607+).
    int n = ToUnicodeEx((UINT)vk, scan, state, out, 8, 4, GetKeyboardLayout(0));
    if (n <= 0) return std::wstring();
    if (out[0] < 32 || out[0] == 127) return std::wstring();
    return std::wstring(out, (size_t)n);
}

bool rwRawKey(rw_window *w, UINT msg, WPARAM wp, LPARAM lp, bool nativeText) {
    if (!w || !w->ctx) return false;
    bool up = msg == WM_KEYUP || msg == WM_SYSKEYUP;
    rw_event ev = {};
    ev.type = RW_EV_RAW_KEY;
    ev.ctx = w->ctx;
    ev.key = (int)wp;
    ev.mods = rwCurrentMods();
    bool extended = (lp >> 24) & 1;
    if (up) ev.flags |= RW_KEY_UP;
    if (nativeText) ev.flags |= RW_KEY_NATIVE_TEXT;
    if (!up && ((lp >> 30) & 1)) ev.flags |= RW_KEY_REPEAT;
    std::wstring chars;
    if (isModifierKey(wp)) {
        ev.flags |= RW_KEY_MODIFIER;
        // The state after this press or release.
        unsigned bit = 0;
        switch (wp) {
        case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT: bit = RW_MOD_SHIFT; break;
        case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL: bit = RW_MOD_CTRL; break;
        case VK_MENU: case VK_LMENU: case VK_RMENU: bit = RW_MOD_ALT; break;
        case VK_LWIN: case VK_RWIN: bit = RW_MOD_WIN; break;
        }
        if (up) ev.mods &= ~bit; else ev.mods |= bit;
    } else {
        chars = keyCharacters(wp, lp);
    }
    if (GetKeyState(VK_CAPITAL) & 1) ev.mods |= 16;
    UINT plain = MapVirtualKeyW((UINT)wp, MAPVK_VK_TO_CHAR) & 0xFFFF;
    char *text = rwNarrowDup(chars.c_str());
    ev.text = text;
    ev.text2 = keyName(wp, (ev.mods & RW_MOD_SHIFT) != 0, extended, (wchar_t)plain);
    int r = rwSendEvent(ev);
    free(text);
    return r != 0;
}

bool rwChildMouse(rw_window *w, HWND child, UINT msg, LPARAM lp, bool after) {
    if (!w || !w->ctx || !w->hwnd) return false;
    POINT p = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
    MapWindowPoints(child, w->hwnd, &p, 1);
    rw_event ev = {};
    ev.type = after ? RW_EV_CHILD_MOUSE_AFTER : RW_EV_CHILD_MOUSE;
    ev.ctx = w->ctx;
    ev.x = p.x / w->scale();
    ev.y = p.y / w->scale();
    ev.mods = rwCurrentMods();
    switch (msg) {
    case WM_LBUTTONDOWN: case WM_LBUTTONDBLCLK: ev.button = 0; break;
    case WM_RBUTTONDOWN: case WM_RBUTTONDBLCLK: ev.button = 1; break;
    case WM_MBUTTONDOWN: case WM_MBUTTONDBLCLK: ev.button = 2; break;
    case WM_LBUTTONUP: ev.button = 0; ev.flags = RW_MOUSE_RELEASE; break;
    case WM_RBUTTONUP: ev.button = 1; ev.flags = RW_MOUSE_RELEASE; break;
    case WM_MBUTTONUP: ev.button = 2; ev.flags = RW_MOUSE_RELEASE; break;
    default: return false;
    }
    return rwSendEvent(ev) != 0;
}

// MARK: Windows

static const wchar_t *kPopupClass = L"RunwayPopup";

extern "C" rw_window *rw_popup_create(rw_window *owner, void *ctx) {
    static bool registered = false;
    if (!registered) {
        WNDCLASSEXW wc = {};
        wc.cbSize = sizeof(wc);
        GetClassInfoExW(rwG.instance, L"RunwayWindow", &wc);
        wc.cbSize = sizeof(wc);
        wc.style = CS_DROPSHADOW;
        wc.lpszClassName = kPopupClass;
        wc.hInstance = rwG.instance;
        RegisterClassExW(&wc);
        registered = true;
    }
    if (!owner || !owner->hwnd) return nullptr;
    rw_window *w = new rw_window();
    w->ctx = ctx;
    w->parent = owner;
    w->popup = true;
    w->decorated = false;
    w->dark = owner->dark;
    w->cursor = LoadCursorW(nullptr, IDC_ARROW);
    HWND h = CreateWindowExW(WS_EX_TOOLWINDOW, kPopupClass, L"", WS_POPUP | WS_CLIPCHILDREN, 0, 0, 10, 10,
                             owner->hwnd, nullptr, rwG.instance, w);
    if (!h) { delete w; return nullptr; }
    w->dpi = GetDpiForWindow(h);
    w->shown = true;   // placed by its owner, never centred
    int corners = 3;   // DWMWA_WINDOW_CORNER_PREFERENCE (33): small rounded corners (Windows 11)
    DwmSetWindowAttribute(h, 33, &corners, sizeof(corners));
    return w;
}

extern "C" void rw_popup_place(rw_window *w, double x, double y, double width, double height) {
    if (!w || !w->hwnd || !w->parent || !w->parent->hwnd) return;
    double s = w->parent->scale();
    POINT p = {(LONG)lround(x * s), (LONG)lround(y * s)};
    ClientToScreen(w->parent->hwnd, &p);
    LONG cw = (LONG)lround(width * s), ch = (LONG)lround(height * s);
    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    GetMonitorInfoW(MonitorFromWindow(w->parent->hwnd, MONITOR_DEFAULTTONEAREST), &mi);
    RECT a = mi.rcWork;
    if (p.x + cw > a.right) p.x = a.right - cw;
    if (p.y + ch > a.bottom) p.y = a.bottom - ch;
    if (p.x < a.left) p.x = a.left;
    if (p.y < a.top) p.y = a.top;
    SetWindowPos(w->hwnd, HWND_TOP, p.x, p.y, cw, ch, SWP_NOACTIVATE);
}

extern "C" void rw_window_offset_in(rw_window *w, rw_window *other, double *x, double *y) {
    *x = 0; *y = 0;
    if (!w || !w->hwnd || !other || !other->hwnd) return;
    POINT p = {0, 0};
    MapWindowPoints(w->hwnd, other->hwnd, &p, 1);
    *x = p.x / other->scale();
    *y = p.y / other->scale();
}

extern "C" void rw_window_set_cursor_image(rw_window *w, int width, int height, const uint8_t *rgba, int hotX, int hotY) {
    if (!w || !rgba || width <= 0 || height <= 0) return;
    BITMAPV5HEADER bi = {};
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = width;
    bi.bV5Height = -height;
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;
    void *bits = nullptr;
    HDC dc = GetDC(nullptr);
    HBITMAP color = CreateDIBSection(dc, (BITMAPINFO *)&bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    ReleaseDC(nullptr, dc);
    if (!color) return;
    uint8_t *d = (uint8_t *)bits;
    for (int i = 0; i < width * height; i++) {
        d[i * 4 + 0] = rgba[i * 4 + 2];
        d[i * 4 + 1] = rgba[i * 4 + 1];
        d[i * 4 + 2] = rgba[i * 4 + 0];
        d[i * 4 + 3] = rgba[i * 4 + 3];
    }
    HBITMAP mask = CreateBitmap(width, height, 1, 1, nullptr);
    ICONINFO ii = {};
    ii.fIcon = FALSE;
    ii.xHotspot = (DWORD)hotX;
    ii.yHotspot = (DWORD)hotY;
    ii.hbmMask = mask;
    ii.hbmColor = color;
    HCURSOR c = (HCURSOR)CreateIconIndirect(&ii);
    DeleteObject(color);
    DeleteObject(mask);
    if (!c) return;
    if (w->ownedCursor) DestroyCursor(w->ownedCursor);
    w->ownedCursor = c;
    w->cursor = c;
    POINT p;
    GetCursorPos(&p);
    if (WindowFromPoint(p) == w->hwnd) SetCursor(c);
}

static DWORD decoratedStyle(rw_window *w) {
    if (!w->decorated) return WS_POPUP | WS_CLIPCHILDREN | (w->resizable ? WS_THICKFRAME : 0);
    return w->resizable ? WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN
                        : (WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN);
}

extern "C" void rw_window_set_decorated(rw_window *w, int decorated) {
    if (!w || !w->hwnd || w->popup || w->decorated == (decorated != 0)) return;
    RECT r;
    GetClientRect(w->hwnd, &r);
    double width = r.right / w->scale(), height = r.bottom / w->scale();
    w->decorated = decorated != 0;
    LONG_PTR style = GetWindowLongPtrW(w->hwnd, GWL_STYLE);
    LONG_PTR keep = style & (WS_VISIBLE | WS_MINIMIZE | WS_MAXIMIZE | WS_DISABLED);
    SetWindowLongPtrW(w->hwnd, GWL_STYLE, (LONG_PTR)decoratedStyle(w) | keep);
    SIZE s = rwOuterSize(w->hwnd, decoratedStyle(w), w->dpi, width, height);
    SetWindowPos(w->hwnd, nullptr, 0, 0, s.cx, s.cy, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

extern "C" void rw_window_begin_move(rw_window *w) {
    if (!w || !w->hwnd) return;
    ReleaseCapture();
    SendMessageW(w->hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
}

extern "C" void rw_window_activate(rw_window *w) {
    if (!w || !w->hwnd) return;
    if (IsIconic(w->hwnd)) ShowWindow(w->hwnd, SW_RESTORE);
    SetForegroundWindow(w->hwnd);
    SetActiveWindow(w->hwnd);
}

extern "C" int rw_window_is_active(rw_window *w) {
    return w && w->hwnd && GetActiveWindow() == w->hwnd ? 1 : 0;
}

extern "C" void rw_window_show_inactive(rw_window *w) {
    if (!w || !w->hwnd) return;
    w->shown = true;
    ShowWindow(w->hwnd, SW_SHOWNOACTIVATE);
}

// MARK: Menu bar

extern "C" void rw_window_set_menubar(rw_window *w, rw_menu *m) {
    if (!w || !w->hwnd) return;
    RECT r;
    GetClientRect(w->hwnd, &r);
    double width = r.right / w->scale(), height = r.bottom / w->scale();
    HMENU old = GetMenu(w->hwnd);
    HMENU next = m ? rwMenuHandle(m) : nullptr;
    SetMenu(w->hwnd, next);
    if (old && old != next) DestroyMenu(old);
    // The window owns the menu now; free only the wrappers.
    if (m) rwMenuRelease(m);
    if (!w->popup) {
        DWORD style = (DWORD)GetWindowLongPtrW(w->hwnd, GWL_STYLE);
        SIZE s = rwOuterSize(w->hwnd, style, w->dpi, width, height);
        SetWindowPos(w->hwnd, nullptr, 0, 0, s.cx, s.cy, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
    DrawMenuBar(w->hwnd);
}

extern "C" void rw_window_menu_item_state(rw_window *w, int id, int enabled, int checked) {
    if (!w || !w->hwnd) return;
    HMENU m = GetMenu(w->hwnd);
    if (!m) return;
    EnableMenuItem(m, (UINT)id, MF_BYCOMMAND | (enabled ? MF_ENABLED : MF_GRAYED));
    CheckMenuItem(m, (UINT)id, MF_BYCOMMAND | (checked ? MF_CHECKED : MF_UNCHECKED));
}

// MARK: Screens

struct ScreenList { double *out; int max; int count; };

static BOOL CALLBACK screenProc(HMONITOR mon, HDC, LPRECT, LPARAM data) {
    ScreenList *l = (ScreenList *)data;
    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(mon, &mi)) return TRUE;
    UINT dx = 96, dy = 96;
    typedef HRESULT (WINAPI *GetDpiForMonitorFn)(HMONITOR, int, UINT *, UINT *);
    static GetDpiForMonitorFn getDpi = nullptr;
    static bool looked = false;
    if (!looked) {
        looked = true;
        HMODULE shcore = LoadLibraryW(L"shcore.dll");
        if (shcore) getDpi = (GetDpiForMonitorFn)(void *)GetProcAddress(shcore, "GetDpiForMonitor");
    }
    if (!getDpi || FAILED(getDpi(mon, 0, &dx, &dy))) dx = GetDpiForSystem();
    double s = dx / 96.0;
    if (l->count < l->max) {
        double *o = l->out + l->count * 9;
        o[0] = mi.rcMonitor.left / s; o[1] = mi.rcMonitor.top / s;
        o[2] = (mi.rcMonitor.right - mi.rcMonitor.left) / s; o[3] = (mi.rcMonitor.bottom - mi.rcMonitor.top) / s;
        o[4] = mi.rcWork.left / s; o[5] = mi.rcWork.top / s;
        o[6] = (mi.rcWork.right - mi.rcWork.left) / s; o[7] = (mi.rcWork.bottom - mi.rcWork.top) / s;
        o[8] = s;
        // The primary display first, as NSScreen.screens has it.
        if ((mi.dwFlags & MONITORINFOF_PRIMARY) && l->count > 0) {
            for (int i = 0; i < 9; i++) { double t = l->out[i]; l->out[i] = o[i]; o[i] = t; }
        }
    }
    l->count++;
    return TRUE;
}

extern "C" int rw_screens(double *out, int max) {
    ScreenList l = {out, max, 0};
    EnumDisplayMonitors(nullptr, nullptr, screenProc, (LPARAM)&l);
    return l.count < max ? l.count : max;
}

// MARK: Drag and drop

struct RwDropTarget : public IDropTarget {
    LONG refs = 1;
    rw_window *w;
    std::string files, text;
    explicit RwDropTarget(rw_window *window) : w(window) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (riid == IID_IUnknown || riid == IID_IDropTarget) { *out = static_cast<IDropTarget *>(this); AddRef(); return S_OK; }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG n = InterlockedDecrement(&refs);
        if (n == 0) delete this;
        return (ULONG)n;
    }

    void read(IDataObject *data) {
        files.clear();
        text.clear();
        FORMATETC f = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        STGMEDIUM m = {};
        if (SUCCEEDED(data->GetData(&f, &m))) {
            HDROP drop = (HDROP)GlobalLock(m.hGlobal);
            if (drop) {
                UINT n = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
                for (UINT i = 0; i < n; i++) {
                    UINT len = DragQueryFileW(drop, i, nullptr, 0);
                    std::wstring p((size_t)len + 1, L'\0');
                    DragQueryFileW(drop, i, &p[0], len + 1);
                    p.resize(len);
                    char *u = rwNarrowDup(p.c_str());
                    if (!files.empty()) files += '\n';
                    files += u;
                    free(u);
                }
                GlobalUnlock(m.hGlobal);
            }
            ReleaseStgMedium(&m);
        }
        FORMATETC t = {CF_UNICODETEXT, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        if (SUCCEEDED(data->GetData(&t, &m))) {
            const wchar_t *s = (const wchar_t *)GlobalLock(m.hGlobal);
            if (s) { char *u = rwNarrowDup(s); text = u; free(u); GlobalUnlock(m.hGlobal); }
            ReleaseStgMedium(&m);
        }
    }

    DWORD send(int kind, POINTL pt, DWORD allowed) {
        if (!w || !w->hwnd || !w->ctx) return DROPEFFECT_NONE;
        POINT p = {pt.x, pt.y};
        ScreenToClient(w->hwnd, &p);
        rw_event ev = {};
        ev.type = RW_EV_DRAG;
        ev.ctx = w->ctx;
        ev.button = kind;
        ev.x = p.x / w->scale();
        ev.y = p.y / w->scale();
        ev.mods = rwCurrentMods();
        ev.text = files.c_str();
        ev.text2 = text.c_str();
        int ops = rwSendEvent(ev);
        DWORD effect = DROPEFFECT_NONE;
        if ((ops & RW_DROP_COPY) && (allowed & DROPEFFECT_COPY)) effect = DROPEFFECT_COPY;
        else if ((ops & RW_DROP_MOVE) && (allowed & DROPEFFECT_MOVE)) effect = DROPEFFECT_MOVE;
        else if ((ops & RW_DROP_LINK) && (allowed & DROPEFFECT_LINK)) effect = DROPEFFECT_LINK;
        else if (ops && (allowed & DROPEFFECT_COPY)) effect = DROPEFFECT_COPY;
        return effect;
    }

    HRESULT STDMETHODCALLTYPE DragEnter(IDataObject *data, DWORD, POINTL pt, DWORD *effect) override {
        read(data);
        *effect = send(0, pt, *effect);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL pt, DWORD *effect) override {
        *effect = send(1, pt, *effect);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragLeave() override {
        POINTL pt = {0, 0};
        send(2, pt, 0);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Drop(IDataObject *data, DWORD, POINTL pt, DWORD *effect) override {
        read(data);
        *effect = send(3, pt, *effect);
        return S_OK;
    }
};

extern "C" void rw_window_accept_drops(rw_window *w, int on) {
    if (!w || !w->hwnd) return;
    if (on && !w->drop) {
        RwDropTarget *t = new RwDropTarget(w);
        if (SUCCEEDED(RegisterDragDrop(w->hwnd, t))) w->drop = t;
        else t->Release();
    } else if (!on && w->drop) {
        rwDropRevoke(w);
    }
}

void rwDropRevoke(rw_window *w) {
    if (!w->drop) return;
    RevokeDragDrop(w->hwnd);
    w->drop->w = nullptr;
    w->drop->Release();
    w->drop = nullptr;
}

// MARK: Rich text

struct rw_rich {
    HWND hwnd = nullptr;
    rw_window *window = nullptr;
    void *ctx = nullptr;
    WNDPROC original = nullptr;
    bool updating = false;
    bool swallowChar = false;
    bool visible = false;
    bool clipped = false;
    bool takesTyping = false;
    bool editable = true;
    bool wraps = true;
    wchar_t pendingHigh = 0;
    RECT frame = {0, 0, 0, 0};
    double insets[4] = {5, 0, 5, 0};   // left, top, right, bottom (DIPs)
    double lastHeight = -1;
    int clicks = 0;
    DWORD lastClickTime = 0;
    POINT lastClick = {0, 0};
    std::wstring text;                 // the text as last reported, "\n" breaks
    LONG anchor = -1;                  // the fixed end of a selection rw_rich_move extended
    CHARRANGE lastSel = {-1, -1};
    int layers = 0;                    // 1 below the text, 2 above it
    rw_window *surface = nullptr;      // a drawing surface for the layers
};

static const wchar_t *kRichProp = L"rw.rich";

static rw_rich *richFor(HWND h) { return h ? (rw_rich *)GetPropW(h, kRichProp) : nullptr; }

static COLORREF richColor(rw_color c) {
    auto v = [](float f) -> BYTE { return (BYTE)lroundf((f < 0 ? 0 : f > 1 ? 1 : f) * 255); };
    return RGB(v(c.r), v(c.g), v(c.b));
}

static std::wstring richText(rw_rich *r) {
    GETTEXTLENGTHEX gl = {GTL_DEFAULT | GTL_NUMCHARS, 1200};
    LONG n = (LONG)SendMessageW(r->hwnd, EM_GETTEXTLENGTHEX, (WPARAM)&gl, 0);
    if (n < 0) n = 0;
    std::wstring t((size_t)n + 1, L'\0');
    GETTEXTEX gt = {};
    gt.cb = (DWORD)((n + 1) * sizeof(wchar_t));
    gt.flags = GT_DEFAULT;
    gt.codepage = 1200;
    LONG got = (LONG)SendMessageW(r->hwnd, EM_GETTEXTEX, (WPARAM)&gt, (LPARAM)&t[0]);
    if (got < 0) got = 0;
    t.resize((size_t)got);
    // Paragraphs end in "\r" inside RichEdit; "\r\n" from older versions.
    std::wstring out;
    out.reserve(t.size());
    for (size_t i = 0; i < t.size(); i++) {
        if (t[i] == L'\r') { out += L'\n'; if (i + 1 < t.size() && t[i + 1] == L'\n') i++; }
        else out += t[i];
    }
    return out;
}

static void applyRect(rw_rich *r) {
    if (!r->hwnd || !r->window) return;
    RECT c;
    GetClientRect(r->hwnd, &c);
    double s = r->window->scale();
    RECT f = {(LONG)lround(r->insets[0] * s), (LONG)lround(r->insets[1] * s),
              c.right - (LONG)lround(r->insets[2] * s), c.bottom - (LONG)lround(r->insets[3] * s)};
    if (f.right < f.left) f.right = f.left;
    if (f.bottom < f.top) f.bottom = f.top;
    SendMessageW(r->hwnd, EM_SETRECT, 0, (LPARAM)&f);
}

static void applyZoom(rw_rich *r) {
    if (!r->hwnd || !r->window) return;
    UINT dpi = r->window->dpi;
    if (dpi == 96) SendMessageW(r->hwnd, EM_SETZOOM, 0, 0);
    else SendMessageW(r->hwnd, EM_SETZOOM, dpi, 96);
}

void rwRichRefresh(rw_window *w) {
    for (rw_rich *r : w->riches) { applyZoom(r); applyRect(r); r->frame = RECT{0, 0, 0, 0}; }
}

void rwRichWindowGone(rw_window *w) {
    for (rw_rich *r : w->riches) { r->hwnd = nullptr; r->window = nullptr; }
    w->riches.clear();
}

static void sendRich(rw_rich *r, int type, int button = 0) {
    if (!r->ctx) return;
    rw_event ev = {};
    ev.type = type;
    ev.ctx = r->ctx;
    ev.button = button;
    rwSendEvent(ev);
}

static void reportHeight(rw_rich *r) {
    if (!r->ctx || !r->hwnd) return;
    RECT c;
    GetClientRect(r->hwnd, &c);
    double width = c.right / (r->window ? r->window->scale() : 1.0);
    double h = rw_rich_height(r, width);
    if (fabs(h - r->lastHeight) < 0.5) return;
    r->lastHeight = h;
    rw_event ev = {};
    ev.type = RW_EV_RICH_HEIGHT;
    ev.ctx = r->ctx;
    ev.dy = h;
    rwSendEvent(ev);
}

/// The view with drawing under and over its text: the background and the
/// layer under the text into a memory DC, RichEdit's text over them
/// (WM_PRINTCLIENT; the control is transparent), then that and the layer
/// over the text onto the window in one pass.
static void paintLayered(rw_rich *r, HWND h, WNDPROC original) {
    PAINTSTRUCT ps;
    HDC target = BeginPaint(h, &ps);
    RECT rc;
    GetClientRect(h, &rc);
    int width = rc.right > 0 ? rc.right : 1, height = rc.bottom > 0 ? rc.bottom : 1;
    rc.right = width;
    rc.bottom = height;
    if (!r->surface) { r->surface = new rw_window(); r->surface->hwnd = h; }
    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = width;
    bi.bmiHeader.biHeight = -height;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    void *bits = nullptr;
    HDC mem = CreateCompatibleDC(target);
    HBITMAP dib = mem ? CreateDIBSection(target, &bi, DIB_RGB_COLORS, &bits, nullptr, 0) : nullptr;
    if (!dib) {
        if (mem) DeleteDC(mem);
        EndPaint(h, &ps);
        CallWindowProcW(original, h, WM_PAINT, 0, 0);
        return;
    }
    HGDIOBJ old = SelectObject(mem, dib);
    rwPaintDC(r->surface, mem, rc, r->window->dpi, nullptr, RW_EV_RICH_PAINT, r->ctx, 0);
    GdiFlush();
    SendMessageW(h, WM_PRINTCLIENT, (WPARAM)mem, PRF_CLIENT);
    GdiFlush();
    if (r->layers & 2) {
        rwPaintDC(r->surface, target, rc, r->window->dpi, bits, RW_EV_RICH_PAINT, r->ctx, 1);
    } else {
        BitBlt(target, 0, 0, width, height, mem, 0, 0, SRCCOPY);
    }
    SelectObject(mem, old);
    DeleteObject(dib);
    DeleteDC(mem);
    EndPaint(h, &ps);
}

static LRESULT CALLBACK richProc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    rw_rich *r = richFor(h);
    if (!r || !r->original) return DefWindowProcW(h, m, wp, lp);
    WNDPROC original = r->original;
    switch (m) {
    case WM_KEYDOWN: case WM_SYSKEYDOWN: case WM_KEYUP: case WM_SYSKEYUP: {
        bool down = m == WM_KEYDOWN || m == WM_SYSKEYDOWN;
        if (down) r->swallowChar = false;
        rw_window *w = r->window;
        if (rwRawKey(w, m, wp, lp, true)) {
            if (!IsWindow(h)) return 0;
            if (down) r->swallowChar = true;
            return 0;
        }
        if (!IsWindow(h) || richFor(h) != r) return 0;
        if (down && r->ctx) {
            rw_event ev = {};
            ev.type = RW_EV_RICH_KEY;
            ev.ctx = r->ctx;
            ev.key = (int)wp;
            ev.mods = rwCurrentMods();
            if (rwSendEvent(ev)) {
                if (IsWindow(h)) r->swallowChar = true;
                return 0;
            }
            if (!IsWindow(h)) return 0;
        }
        break;
    }
    case WM_CHAR: case WM_SYSCHAR: {
        if (r->swallowChar) { r->swallowChar = false; return 0; }
        if (m == WM_SYSCHAR) break;
        wchar_t c = (wchar_t)wp;
        if (c < 32 && c != L'\t' && c != L'\r') return 0;   // Ctrl+letter: no stray control characters
        if (r->takesTyping && r->ctx) {
            if (IS_HIGH_SURROGATE(c)) { r->pendingHigh = c; return 0; }
            std::wstring s;
            if (IS_LOW_SURROGATE(c) && r->pendingHigh) s += r->pendingHigh;
            r->pendingHigh = 0;
            s += (c == L'\r') ? L'\n' : c;
            char *u = rwNarrowDup(s.c_str());
            rw_event ev = {};
            ev.type = RW_EV_RICH_CHAR;
            ev.ctx = r->ctx;
            ev.text = u;
            int taken = rwSendEvent(ev);
            free(u);
            if (taken) return 0;
            if (!IsWindow(h)) return 0;
            if (!r->editable) return 0;
        }
        break;
    }
    case WM_LBUTTONDOWN: case WM_LBUTTONDBLCLK: case WM_RBUTTONDOWN: case WM_MBUTTONDOWN:
    case WM_LBUTTONUP: case WM_RBUTTONUP: case WM_MBUTTONUP: {
        bool up = m == WM_LBUTTONUP || m == WM_RBUTTONUP || m == WM_MBUTTONUP;
        if (rwChildMouse(r->window, h, m, lp, false)) return 0;
        if (!IsWindow(h) || richFor(h) != r) return 0;
        if (!up) {
            POINT p = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
            DWORD now = GetMessageTime();
            if (now - r->lastClickTime <= GetDoubleClickTime() && abs(p.x - r->lastClick.x) < 5 && abs(p.y - r->lastClick.y) < 5) r->clicks++;
            else r->clicks = 1;
            r->lastClickTime = now;
            r->lastClick = p;
        }
        if (r->ctx && r->window) {
            rw_event ev = {};
            ev.type = RW_EV_RICH_POINTER;
            ev.ctx = r->ctx;
            ev.x = GET_X_LPARAM(lp) / r->window->scale();
            ev.y = GET_Y_LPARAM(lp) / r->window->scale();
            ev.button = (m == WM_RBUTTONDOWN || m == WM_RBUTTONUP) ? 1 : (m == WM_MBUTTONDOWN || m == WM_MBUTTONUP) ? 2 : 0;
            ev.flags = up ? RW_MOUSE_RELEASE : 0;
            ev.clicks = r->clicks;
            ev.mods = rwCurrentMods();
            if (rwSendEvent(ev)) return 0;
            if (!IsWindow(h)) return 0;
        }
        if (m == WM_RBUTTONDOWN || m == WM_RBUTTONUP) return 0;   // no native context menu
        break;
    }
    case WM_PAINT:
        if (r->layers && r->window) {
            paintLayered(r, h, original);
            return 0;
        }
        break;
    case WM_MOUSEWHEEL: case WM_MOUSEHWHEEL:
        // The view is as tall as its text: the scroll view around it scrolls.
        if (r->window && r->window->hwnd) return SendMessageW(r->window->hwnd, m, wp, lp);
        return 0;
    case WM_SETFOCUS:
        sendRich(r, RW_EV_RICH_FOCUS, 1);
        if (!IsWindow(h)) return 0;
        break;
    case WM_KILLFOCUS:
        sendRich(r, RW_EV_RICH_FOCUS, 0);
        if (!IsWindow(h)) return 0;
        break;
    case WM_NCDESTROY:
        r->original = nullptr;
        r->hwnd = nullptr;
        RemovePropW(h, kRichProp);
        SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)original);
        return CallWindowProcW(original, h, m, wp, lp);
    }
    return CallWindowProcW(original, h, m, wp, lp);
}

bool rwRichCommand(HWND h, int code) {
    rw_rich *r = richFor(h);
    if (!r) return false;
    if (code == EN_CHANGE && !r->updating) {
        sendRich(r, RW_EV_RICH_CHANGED);
        if (richFor(h) == r) reportHeight(r);
    }
    return true;
}

bool rwRichNotify(rw_window *w, NMHDR *hdr, LRESULT *result) {
    (void)w;
    rw_rich *r = richFor(hdr->hwndFrom);
    if (!r) return false;
    *result = 0;
    if (hdr->code == EN_SELCHANGE && !r->updating && r->ctx) {
        rw_event ev = {};
        ev.type = RW_EV_RICH_SELECTION;
        ev.ctx = r->ctx;
        if (GetKeyState(VK_LBUTTON) < 0) ev.flags = RW_KEY_REPEAT;
        rwSendEvent(ev);
    }
    return true;
}

static HMODULE loadRichEdit(const wchar_t **cls) {
    static HMODULE lib = nullptr;
    static const wchar_t *name = nullptr;
    if (!lib) {
        lib = LoadLibraryW(L"msftedit.dll");
        if (lib) name = L"RICHEDIT50W";
        else { lib = LoadLibraryW(L"riched20.dll"); if (lib) name = L"RichEdit20W"; }
    }
    *cls = name;
    return lib;
}

extern "C" rw_rich *rw_rich_create(rw_window *w, void *ctx) {
    if (!w || !w->hwnd) return nullptr;
    const wchar_t *cls = nullptr;
    if (!loadRichEdit(&cls)) return nullptr;
    rw_rich *r = new rw_rich();
    r->window = w;
    r->ctx = ctx;
    DWORD style = WS_CHILD | WS_CLIPSIBLINGS | ES_MULTILINE | ES_WANTRETURN | ES_NOHIDESEL;
    r->hwnd = CreateWindowExW(0, cls, L"", style, 0, 0, 0, 0, w->hwnd, nullptr, rwG.instance, nullptr);
    if (!r->hwnd) { delete r; return nullptr; }
    SetPropW(r->hwnd, kRichProp, r);
    r->original = (WNDPROC)SetWindowLongPtrW(r->hwnd, GWLP_WNDPROC, (LONG_PTR)richProc);
    SendMessageW(r->hwnd, EM_SETEVENTMASK, 0, ENM_CHANGE | ENM_SELCHANGE);
    SendMessageW(r->hwnd, EM_SETTEXTMODE, TM_RICHTEXT | TM_MULTILEVELUNDO, 0);
    SendMessageW(r->hwnd, EM_SETUNDOLIMIT, 100, 0);
    SendMessageW(r->hwnd, EM_SETTARGETDEVICE, 0, 0);   // wrap to the window
    applyZoom(r);
    w->riches.push_back(r);
    return r;
}

extern "C" void rw_rich_destroy(rw_rich *r) {
    if (!r) return;
    r->ctx = nullptr;
    if (r->surface) { rwDiscardTarget(r->surface); delete r->surface; r->surface = nullptr; }
    if (r->window) {
        auto &v = r->window->riches;
        for (size_t i = 0; i < v.size(); i++) if (v[i] == r) { v.erase(v.begin() + (long)i); break; }
    }
    if (r->hwnd) {
        if (GetFocus() == r->hwnd && r->window) SetFocus(r->window->hwnd);
        DestroyWindow(r->hwnd);
    }
    delete r;
}

extern "C" void rw_rich_set_frame(rw_rich *r, double x, double y, double width, double height,
                                  double cx, double cy, double cw, double ch, int visible) {
    if (!r || !r->hwnd || !r->window) return;
    double s = r->window->scale();
    RECT f = {(LONG)lround(x * s), (LONG)lround(y * s), (LONG)lround((x + width) * s), (LONG)lround((y + height) * s)};
    RECT clip = {(LONG)lround(cx * s), (LONG)lround(cy * s), (LONG)lround((cx + cw) * s), (LONG)lround((cy + ch) * s)};
    RECT vis;
    bool show = visible && IntersectRect(&vis, &f, &clip) && f.right > f.left && f.bottom > f.top;
    if (!show) {
        if (r->visible) {
            if (GetFocus() == r->hwnd) SetFocus(r->window->hwnd);
            ShowWindow(r->hwnd, SW_HIDE);
            r->visible = false;
        }
        return;
    }
    bool resized = (f.right - f.left) != (r->frame.right - r->frame.left) || (f.bottom - f.top) != (r->frame.bottom - r->frame.top);
    if (!EqualRect(&f, &r->frame) || !r->visible) {
        SetWindowPos(r->hwnd, HWND_TOP, f.left, f.top, f.right - f.left, f.bottom - f.top, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        r->frame = f;
        r->visible = true;
    }
    if (resized) {
        applyRect(r);
        POINT origin = {0, 0};
        SendMessageW(r->hwnd, EM_SETSCROLLPOS, 0, (LPARAM)&origin);
    }
    bool clipped = !EqualRect(&vis, &f);
    if (clipped) {
        HRGN rgn = CreateRectRgn(vis.left - f.left, vis.top - f.top, vis.right - f.left, vis.bottom - f.top);
        SetWindowRgn(r->hwnd, rgn, TRUE);
        r->clipped = true;
    } else if (r->clipped) {
        SetWindowRgn(r->hwnd, nullptr, TRUE);
        r->clipped = false;
    }
}

static void charFormat(const rw_rich_run &run, CHARFORMAT2W &cf) {
    memset(&cf, 0, sizeof cf);
    cf.cbSize = sizeof cf;
    cf.dwMask = CFM_FACE | CFM_SIZE | CFM_WEIGHT | CFM_BOLD | CFM_ITALIC | CFM_COLOR | CFM_BACKCOLOR | CFM_UNDERLINE |
                CFM_UNDERLINETYPE | CFM_STRIKEOUT | CFM_OFFSET | CFM_HIDDEN;
    std::wstring face = run.family && *run.family ? rwWiden(run.family) : rwG.uiFamily;
    if (face == L"Segoe UI Variable Text") face = L"Segoe UI";   // GDI has no variable faces
    wcsncpy(cf.szFaceName, face.c_str(), LF_FACESIZE - 1);
    cf.yHeight = (LONG)lround((run.size > 0 ? run.size : 13) * 15);   // DIPs to twips
    cf.wWeight = (WORD)(run.weight > 0 ? run.weight : 400);
    if (cf.wWeight >= 600) cf.dwEffects |= CFE_BOLD;
    if (run.italic) cf.dwEffects |= CFE_ITALIC;
    if (run.has_color) cf.crTextColor = richColor(run.color); else cf.dwEffects |= CFE_AUTOCOLOR;
    if (run.has_background && run.background.a > 0.01f) cf.crBackColor = richColor(run.background); else cf.dwEffects |= CFE_AUTOBACKCOLOR;
    if (run.underline) {
        cf.dwEffects |= CFE_UNDERLINE;
        cf.bUnderlineType = run.underline == 3 ? CFU_UNDERLINEDOUBLE : run.underline == 2 ? CFU_UNDERLINETHICK : CFU_UNDERLINE;
    }
    if (run.strikethrough) cf.dwEffects |= CFE_STRIKEOUT;
    cf.yOffset = (LONG)lround(run.baseline_offset * 15);
    if (run.hidden) cf.dwEffects |= CFE_HIDDEN;
}

static void paraFormat(const rw_rich_run &run, PARAFORMAT2 &pf) {
    memset(&pf, 0, sizeof pf);
    pf.cbSize = sizeof pf;
    pf.dwMask = PFM_ALIGNMENT | PFM_SPACEBEFORE | PFM_SPACEAFTER | PFM_STARTINDENT | PFM_OFFSET | PFM_RIGHTINDENT | PFM_LINESPACING;
    pf.wAlignment = run.alignment == RW_ALIGN_CENTER ? PFA_CENTER : run.alignment == RW_ALIGN_TRAILING ? PFA_RIGHT
                  : run.alignment == 3 ? PFA_JUSTIFY : PFA_LEFT;
    pf.dySpaceBefore = (LONG)lround(run.spacing_before * 15);
    pf.dySpaceAfter = (LONG)lround(run.paragraph_spacing * 15);
    pf.dxStartIndent = (LONG)lround(run.first_indent * 15);
    pf.dxOffset = (LONG)lround((run.head_indent - run.first_indent) * 15);
    pf.dxRightIndent = run.tail_indent < 0 ? (LONG)lround(-run.tail_indent * 15) : 0;
    if (run.line_height_multiple > 0) {
        pf.bLineSpacingRule = 5;   // dyLineSpacing / 20 lines
        pf.dyLineSpacing = (LONG)lround(run.line_height_multiple * 20);
    } else if (run.line_spacing > 0) {
        pf.bLineSpacingRule = 4;   // exactly: the natural height plus the spacing
        pf.dyLineSpacing = (LONG)lround((run.size * 1.25 + run.line_spacing) * 15);
    } else {
        pf.bLineSpacingRule = 0;
    }
}

static void formatRuns(rw_rich *r, LONG start, const rw_rich_run *runs, int count) {
    LONG at = start;
    for (int i = 0; i < count; i++) {
        std::wstring t = rwWiden(runs[i].text);
        LONG len = 0;
        for (size_t k = 0; k < t.size(); k++) { if (t[k] == L'\r' && k + 1 < t.size() && t[k + 1] == L'\n') continue; len++; }
        if (len == 0) continue;
        CHARRANGE cr = {at, at + len};
        SendMessageW(r->hwnd, EM_EXSETSEL, 0, (LPARAM)&cr);
        CHARFORMAT2W cf;
        charFormat(runs[i], cf);
        SendMessageW(r->hwnd, EM_SETCHARFORMAT, SCF_SELECTION, (LPARAM)&cf);
        if (runs[i].has_paragraph) {
            PARAFORMAT2 pf;
            paraFormat(runs[i], pf);
            SendMessageW(r->hwnd, EM_SETPARAFORMAT, 0, (LPARAM)&pf);
        }
        at += len;
    }
}

static std::wstring joined(const rw_rich_run *runs, int count) {
    std::wstring all;
    for (int i = 0; i < count; i++) all += rwWiden(runs[i].text);
    std::wstring out;
    out.reserve(all.size());
    for (size_t k = 0; k < all.size(); k++) {
        if (all[k] == L'\r' && k + 1 < all.size() && all[k + 1] == L'\n') continue;
        out += all[k] == L'\n' ? L'\r' : all[k];
    }
    return out;
}

/// Runs `body` with redraw and change events off, keeping the selection.
template <class F> static void quietly(rw_rich *r, bool keepSelection, F body) {
    r->updating = true;
    CHARRANGE sel;
    SendMessageW(r->hwnd, EM_EXGETSEL, 0, (LPARAM)&sel);
    POINT scroll;
    SendMessageW(r->hwnd, EM_GETSCROLLPOS, 0, (LPARAM)&scroll);
    SendMessageW(r->hwnd, WM_SETREDRAW, FALSE, 0);
    body();
    if (keepSelection) SendMessageW(r->hwnd, EM_EXSETSEL, 0, (LPARAM)&sel);
    SendMessageW(r->hwnd, EM_SETSCROLLPOS, 0, (LPARAM)&scroll);
    SendMessageW(r->hwnd, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(r->hwnd, nullptr, TRUE);
    r->updating = false;
    r->text = richText(r);
}

extern "C" void rw_rich_configure(rw_rich *r, int editable, int wraps, double left, double top, double right, double bottom,
                                  rw_color background, const rw_rich_run *typing, int takesTyping) {
    if (!r || !r->hwnd) return;
    r->editable = editable != 0;
    r->takesTyping = takesTyping != 0;
    SendMessageW(r->hwnd, EM_SETREADONLY, editable ? FALSE : TRUE, 0);
    if ((wraps != 0) != r->wraps) {
        r->wraps = wraps != 0;
        SendMessageW(r->hwnd, EM_SETTARGETDEVICE, 0, wraps ? 0 : 1);
    }
    r->insets[0] = left; r->insets[1] = top; r->insets[2] = right; r->insets[3] = bottom;
    applyRect(r);
    SendMessageW(r->hwnd, EM_SETBKGNDCOLOR, 0, (LPARAM)richColor(background));
    if (typing) {
        CHARFORMAT2W cf;
        charFormat(*typing, cf);
        r->updating = true;
        if (GetWindowTextLengthW(r->hwnd) == 0) SendMessageW(r->hwnd, EM_SETCHARFORMAT, SCF_ALL, (LPARAM)&cf);
        SendMessageW(r->hwnd, EM_SETCHARFORMAT, SCF_DEFAULT, (LPARAM)&cf);
        r->updating = false;
    }
}

extern "C" void rw_rich_set_runs(rw_rich *r, const rw_rich_run *runs, int count) {
    if (!r || !r->hwnd) return;
    std::wstring text = joined(runs, count);
    quietly(r, true, [&] {
        SETTEXTEX st = {ST_DEFAULT | ST_KEEPUNDO, 1200};
        st.flags = ST_DEFAULT;
        SendMessageW(r->hwnd, EM_SETTEXTEX, (WPARAM)&st, (LPARAM)text.c_str());
        formatRuns(r, 0, runs, count);
    });
    reportHeight(r);
}

extern "C" void rw_rich_replace(rw_rich *r, int start, int end, const rw_rich_run *runs, int count) {
    if (!r || !r->hwnd) return;
    std::wstring text = joined(runs, count);
    quietly(r, false, [&] {
        CHARRANGE cr = {start, end};
        SendMessageW(r->hwnd, EM_EXSETSEL, 0, (LPARAM)&cr);
        SendMessageW(r->hwnd, EM_REPLACESEL, FALSE, (LPARAM)text.c_str());
        formatRuns(r, start, runs, count);
        CHARRANGE after = {start + (LONG)text.size(), start + (LONG)text.size()};
        SendMessageW(r->hwnd, EM_EXSETSEL, 0, (LPARAM)&after);
    });
    reportHeight(r);
}

extern "C" void rw_rich_get_selection(rw_rich *r, int *start, int *end) {
    *start = 0; *end = 0;
    if (!r || !r->hwnd) return;
    CHARRANGE cr;
    SendMessageW(r->hwnd, EM_EXGETSEL, 0, (LPARAM)&cr);
    *start = cr.cpMin;
    *end = cr.cpMax < 0 ? (int)r->text.size() : cr.cpMax;
}

extern "C" void rw_rich_set_selection(rw_rich *r, int start, int end) {
    if (!r || !r->hwnd) return;
    r->updating = true;
    CHARRANGE cr = {start, end};
    SendMessageW(r->hwnd, EM_EXSETSEL, 0, (LPARAM)&cr);
    r->updating = false;
}

extern "C" void rw_rich_undo(rw_rich *r, int redo) {
    if (!r || !r->hwnd) return;
    SendMessageW(r->hwnd, redo ? EM_REDO : EM_UNDO, 0, 0);
}

extern "C" double rw_rich_height(rw_rich *r, double width) {
    if (!r || !r->hwnd) return 0;
    double inner = width - r->insets[0] - r->insets[2];
    if (inner < 1) inner = 1;
    HDC dc = GetDC(r->hwnd);
    FORMATRANGE fr = {};
    fr.hdc = dc;
    fr.hdcTarget = dc;
    fr.rc.left = 0;
    fr.rc.top = 0;
    fr.rc.right = r->wraps ? (LONG)lround(inner * 15) : 0x0FFFFFFF;
    fr.rc.bottom = 0x0FFFFFFF;
    fr.rcPage = fr.rc;
    fr.chrg.cpMin = 0;
    fr.chrg.cpMax = -1;
    LRESULT next = SendMessageW(r->hwnd, EM_FORMATRANGE, FALSE, (LPARAM)&fr);
    SendMessageW(r->hwnd, EM_FORMATRANGE, FALSE, 0);
    ReleaseDC(r->hwnd, dc);
    double h = fr.rc.bottom / 15.0;
    (void)next;
    if (h <= 0 || h > 1e6) {
        // Measure from the layout instead: the last character's line.
        int n = (int)r->text.size();
        double x, y, w, lh;
        rw_rich_char_rect(r, n, &x, &y, &w, &lh);
        h = y + lh - r->insets[1];
    }
    if (h < 0) h = 0;
    return ceil(h + r->insets[1] + r->insets[3]);
}

extern "C" void rw_rich_char_rect(rw_rich *r, int index, double *x, double *y, double *width, double *height) {
    *x = 0; *y = 0; *width = 0; *height = 0;
    if (!r || !r->hwnd || !r->window) return;
    double s = r->window->scale();
    int n = (int)r->text.size();
    if (index < 0) index = 0;
    if (index > n) index = n;
    POINTL p = {0, 0};
    SendMessageW(r->hwnd, EM_POSFROMCHAR, (WPARAM)&p, index);
    // The line's height: from this line's top to the next line's.
    LONG line = (LONG)SendMessageW(r->hwnd, EM_EXLINEFROMCHAR, 0, index);
    LONG nextStart = (LONG)SendMessageW(r->hwnd, EM_LINEINDEX, line + 1, 0);
    double lh = 0;
    if (nextStart > 0) {
        POINTL q = {0, 0};
        SendMessageW(r->hwnd, EM_POSFROMCHAR, (WPARAM)&q, nextStart);
        if (q.y > p.y) lh = (q.y - p.y) / s;
    }
    if (lh <= 0) {
        CHARFORMAT2W cf = {};
        cf.cbSize = sizeof cf;
        SendMessageW(r->hwnd, EM_GETCHARFORMAT, SCF_DEFAULT, (LPARAM)&cf);
        lh = (cf.yHeight > 0 ? cf.yHeight / 15.0 : 13) * 1.3;
    }
    double w = 0;
    if (index < n) {
        POINTL q = {0, 0};
        SendMessageW(r->hwnd, EM_POSFROMCHAR, (WPARAM)&q, index + 1);
        if (q.y == p.y && q.x > p.x) w = (q.x - p.x) / s;
    }
    *x = p.x / s;
    *y = p.y / s;
    *width = w;
    *height = lh;
}

extern "C" int rw_rich_char_index(rw_rich *r, double x, double y) {
    if (!r || !r->hwnd || !r->window) return 0;
    double s = r->window->scale();
    POINTL p = {(LONG)lround(x * s), (LONG)lround(y * s)};
    return (int)SendMessageW(r->hwnd, EM_CHARFROMPOS, 0, (LPARAM)&p);
}

extern "C" void rw_rich_move(rw_rich *r, int step, int count, int extend) {
    if (!r || !r->hwnd || count == 0) return;
    const std::wstring &t = r->text;
    LONG n = (LONG)t.size();
    CHARRANGE sel;
    SendMessageW(r->hwnd, EM_EXGETSEL, 0, (LPARAM)&sel);
    // The selection's fixed end and the end that moves: as this view last
    // left them, or (a selection made some other way) its start and end.
    LONG fixed = sel.cpMin, caret = sel.cpMax;
    if (r->lastSel.cpMin == sel.cpMin && r->lastSel.cpMax == sel.cpMax && r->anchor >= 0) {
        fixed = r->anchor;
        caret = fixed == sel.cpMin ? sel.cpMax : sel.cpMin;
    } else if (extend && count < 0 && sel.cpMin == sel.cpMax) {
        fixed = caret = sel.cpMin;
    }
    if (!extend && sel.cpMin != sel.cpMax && step == 0) {
        caret = count < 0 ? sel.cpMin : sel.cpMax;
        count = 0;
    }
    bool forward = count > 0;
    int times = count < 0 ? -count : count;
    for (int i = 0; i < times; i++) {
        switch (step) {
        case 0:
            caret += forward ? 1 : -1;
            break;
        case 1:
            caret = (LONG)SendMessageW(r->hwnd, EM_FINDWORDBREAK, forward ? WB_MOVEWORDRIGHT : WB_MOVEWORDLEFT, caret);
            break;
        case 2: case 6: {
            POINTL p = {0, 0};
            SendMessageW(r->hwnd, EM_POSFROMCHAR, (WPARAM)&p, caret);
            LONG line = (LONG)SendMessageW(r->hwnd, EM_EXLINEFROMCHAR, 0, caret);
            LONG lines = (LONG)SendMessageW(r->hwnd, EM_GETLINECOUNT, 0, 0);
            LONG by = 1;
            if (step == 6 && r->window) {
                RECT c;
                GetClientRect(r->window->hwnd, &c);
                double x, y, w, lh;
                rw_rich_char_rect(r, caret, &x, &y, &w, &lh);
                by = lh > 0 ? (LONG)(c.bottom / r->window->scale() / lh) : 20;
                if (by < 1) by = 1;
            }
            LONG target = line + (forward ? by : -by);
            if (target < 0) { caret = 0; break; }
            if (target >= lines) { caret = n; break; }
            LONG start = (LONG)SendMessageW(r->hwnd, EM_LINEINDEX, target, 0);
            POINTL q = {0, 0};
            SendMessageW(r->hwnd, EM_POSFROMCHAR, (WPARAM)&q, start);
            POINTL at = {p.x, q.y + 1};
            caret = (LONG)SendMessageW(r->hwnd, EM_CHARFROMPOS, 0, (LPARAM)&at);
            break;
        }
        case 3: {
            LONG line = (LONG)SendMessageW(r->hwnd, EM_EXLINEFROMCHAR, 0, caret);
            LONG start = (LONG)SendMessageW(r->hwnd, EM_LINEINDEX, line, 0);
            if (!forward) { caret = start; break; }
            LONG len = (LONG)SendMessageW(r->hwnd, EM_LINELENGTH, start, 0);
            caret = start + len;
            break;
        }
        case 4: case 5: {
            if (forward) {
                LONG k = caret;
                if (step == 4 && k < n && t[(size_t)k] == L'\n') k++;
                while (k < n && t[(size_t)k] != L'\n') k++;
                caret = (step == 4 && k < n) ? k + 1 : k;
            } else {
                LONG k = caret;
                if (k > 0 && t[(size_t)k - 1] == L'\n' && step == 4) k--;
                while (k > 0 && t[(size_t)k - 1] != L'\n') k--;
                caret = k;
            }
            break;
        }
        case 7:
            caret = forward ? n : 0;
            break;
        }
        if (caret < 0) caret = 0;
        if (caret > n) caret = n;
    }
    CHARRANGE out;
    if (extend) {
        out.cpMin = caret < fixed ? caret : fixed;
        out.cpMax = caret < fixed ? fixed : caret;
        r->anchor = fixed;
    } else {
        out.cpMin = out.cpMax = caret;
        r->anchor = -1;
    }
    r->lastSel = out;
    SendMessageW(r->hwnd, EM_EXSETSEL, 0, (LPARAM)&out);
    SendMessageW(r->hwnd, EM_SCROLLCARET, 0, 0);
}

extern "C" void rw_rich_set_layers(rw_rich *r, int below, int above) {
    if (!r || !r->hwnd) return;
    int layers = (below ? 1 : 0) | (above ? 2 : 0);
    // Under the text the view paints its own background, so RichEdit doesn't.
    LONG_PTR ex = GetWindowLongPtrW(r->hwnd, GWL_EXSTYLE);
    LONG_PTR next = layers ? (ex | WS_EX_TRANSPARENT) : (ex & ~(LONG_PTR)WS_EX_TRANSPARENT);
    if (next != ex) SetWindowLongPtrW(r->hwnd, GWL_EXSTYLE, next);
    r->layers = layers;
    InvalidateRect(r->hwnd, nullptr, TRUE);
}

extern "C" rw_window *rw_rich_surface(rw_rich *r) { return r ? r->surface : nullptr; }

extern "C" void rw_rich_focus(rw_rich *r) { if (r && r->hwnd) SetFocus(r->hwnd); }
extern "C" int rw_rich_has_focus(rw_rich *r) { return r && r->hwnd && GetFocus() == r->hwnd ? 1 : 0; }

extern "C" char *rw_rich_copy_text(rw_rich *r) {
    if (!r || !r->hwnd) return rwNarrowDup(L"");
    r->text = richText(r);
    return rwNarrowDup(r->text.c_str());
}

// MARK: Tray icons

const UINT rwTrayMessageId = WM_APP + 2;

struct rw_tray {
    UINT id = 0;
    void *ctx = nullptr;
    bool added = false;
};
static std::vector<rw_tray *> trays;

static void trayData(rw_tray *t, NOTIFYICONDATAW &d, const char *tooltip) {
    memset(&d, 0, sizeof d);
    d.cbSize = sizeof d;
    d.hWnd = rwG.messageWindow;
    d.uID = t->id;
    d.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    d.uCallbackMessage = rwTrayMessageId;
    d.hIcon = LoadIconW(rwG.instance, MAKEINTRESOURCEW(1));
    if (!d.hIcon) d.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    std::wstring tip = rwWiden(tooltip);
    wcsncpy(d.szTip, tip.c_str(), 127);
}

extern "C" rw_tray *rw_tray_create(const char *tooltip, void *ctx) {
    static UINT next = 1;
    rw_tray *t = new rw_tray();
    t->id = next++;
    t->ctx = ctx;
    NOTIFYICONDATAW d;
    trayData(t, d, tooltip);
    t->added = Shell_NotifyIconW(NIM_ADD, &d) != FALSE;
    if (!t->added) { delete t; return nullptr; }
    trays.push_back(t);
    return t;
}

extern "C" void rw_tray_update(rw_tray *t, const char *tooltip, int visible) {
    if (!t) return;
    NOTIFYICONDATAW d;
    trayData(t, d, tooltip);
    if (visible && !t->added) t->added = Shell_NotifyIconW(NIM_ADD, &d) != FALSE;
    else if (!visible && t->added) { Shell_NotifyIconW(NIM_DELETE, &d); t->added = false; }
    else if (t->added) Shell_NotifyIconW(NIM_MODIFY, &d);
}

extern "C" void rw_tray_destroy(rw_tray *t) {
    if (!t) return;
    if (t->added) {
        NOTIFYICONDATAW d;
        trayData(t, d, "");
        Shell_NotifyIconW(NIM_DELETE, &d);
    }
    for (size_t i = 0; i < trays.size(); i++) if (trays[i] == t) { trays.erase(trays.begin() + (long)i); break; }
    delete t;
}

void rwTrayMessage(WPARAM wp, LPARAM lp) {
    UINT msg = (UINT)LOWORD(lp);
    for (rw_tray *t : trays) {
        if (t->id != (UINT)wp) continue;
        if (msg == WM_LBUTTONUP || msg == WM_RBUTTONUP || msg == WM_CONTEXTMENU) {
            rw_event ev = {};
            ev.type = RW_EV_TRAY;
            ev.ctx = t->ctx;
            ev.button = msg == WM_LBUTTONUP ? 0 : 1;
            rwSendEvent(ev);
        }
        return;
    }
}

#endif
