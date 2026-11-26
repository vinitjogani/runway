// Text input (EDIT controls over custom-drawn fields), popup menus, the
// colour picker, the clipboard, the Shell, sounds and file dialogs.
#ifdef _WIN32
#include "rw_internal.h"

static const UINT kSetCueBanner = 0x1501;   // EM_SETCUEBANNER (Common Controls 6)

// MARK: Edits

struct rw_edit {
    HWND hwnd = nullptr;
    rw_window *window = nullptr;
    void *ctx = nullptr;
    bool multiline = false;
    bool updating = false;
    bool swallowChar = false;
    bool visible = false;
    bool clipped = false;
    RECT frame = {0, 0, 0, 0};
    WNDPROC original = nullptr;
    HFONT font = nullptr;
    HBRUSH background = nullptr;
    COLORREF textColor = RGB(0, 0, 0), backColor = RGB(255, 255, 255);
    float size = 13;
    int weight = 400;
    std::wstring placeholder;
};

static COLORREF colorRef(rw_color c) {
    auto v = [](float f) -> BYTE { return (BYTE)lroundf((f < 0 ? 0 : f > 1 ? 1 : f) * 255); };
    return RGB(v(c.r), v(c.g), v(c.b));
}

static rw_edit *editFor(HWND h) {
    return h ? (rw_edit *)GetWindowLongPtrW(h, GWLP_USERDATA) : nullptr;
}

static bool isEdit(HWND h, rw_edit *e) {
    return e && e->hwnd == h && e->window;
}

static bool editingKey(WPARAM vk) {
    switch (vk) {
    case 'C': case 'V': case 'X': case 'Z': case 'Y':
    case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN: case VK_HOME: case VK_END:
    case VK_BACK: case VK_DELETE: case VK_INSERT: case VK_PRIOR: case VK_NEXT:
    case VK_SHIFT: case VK_CONTROL: case VK_MENU:
        return true;
    }
    return false;
}

static LRESULT CALLBACK editProc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    rw_edit *e = editFor(h);
    if (!e || !e->original) return DefWindowProcW(h, m, wp, lp);
    switch (m) {
    case WM_KEYUP:
    case WM_SYSKEYUP:
        if (rwRawKey(e->window, m, wp, lp, true)) return 0;
        if (!IsWindow(h)) return 0;
        break;
    case WM_LBUTTONDOWN: case WM_LBUTTONDBLCLK: case WM_RBUTTONDOWN: case WM_MBUTTONDOWN:
    case WM_LBUTTONUP: case WM_RBUTTONUP: case WM_MBUTTONUP: {
        if (rwChildMouse(e->window, h, m, lp, false)) return 0;
        if (!IsWindow(h)) return 0;
        rw_window *win = e->window;
        LRESULT r = CallWindowProcW(e->original, h, m, wp, lp);
        if (IsWindow(h)) rwChildMouse(win, h, m, lp, true);
        return r;
    }
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN: {
        e->swallowChar = false;
        if (rwRawKey(e->window, m, wp, lp, true)) {
            if (IsWindow(h)) e->swallowChar = true;
            return 0;
        }
        if (!IsWindow(h) || editFor(h) != e) return 0;
        if (e->ctx) {
            rw_event kev = {};
            kev.type = RW_EV_EDIT_KEY;
            kev.ctx = e->ctx;
            kev.key = (int)wp;
            kev.mods = rwCurrentMods();
            if (rwSendEvent(kev)) {
                if (IsWindow(h)) e->swallowChar = true;
                return 0;
            }
            if (!IsWindow(h) || editFor(h) != e) return 0;
        }
        bool ctrl = GetKeyState(VK_CONTROL) < 0;
        if (ctrl && wp == 'A') {
            SendMessageW(h, EM_SETSEL, 0, -1);
            e->swallowChar = true;
            return 0;
        }
        if (wp == VK_RETURN && !e->multiline) {
            e->swallowChar = true;
            if ((!e->ctx || !rwSend(RW_EV_EDIT_SUBMIT, e->ctx)) && e->window) {
                rw_event ev = {};
                ev.type = RW_EV_KEY_DOWN;
                ev.ctx = e->window->ctx;
                ev.key = VK_RETURN;
                rwSendEvent(ev);
            }
            return 0;
        }
        bool forward = wp == VK_ESCAPE || (wp == VK_TAB && !e->multiline) || m == WM_SYSKEYDOWN ||
                       (ctrl && !editingKey(wp)) || (wp >= VK_F1 && wp <= VK_F24);
        if (forward && e->window) {
            rw_event ev = {};
            ev.type = RW_EV_KEY_DOWN;
            ev.ctx = e->window->ctx;
            ev.key = (int)wp;
            ev.mods = (GetKeyState(VK_SHIFT) < 0 ? RW_MOD_SHIFT : 0) | (ctrl ? RW_MOD_CTRL : 0) |
                      (GetKeyState(VK_MENU) < 0 ? RW_MOD_ALT : 0);
            HWND self = h;
            int handled = rwSendEvent(ev);
            if (!IsWindow(self)) return 0;   // the handler may have destroyed us
            if (handled || wp == VK_TAB || wp == VK_ESCAPE) { e->swallowChar = true; return 0; }
        }
        break;
    }
    case WM_CHAR:
    case WM_SYSCHAR:
        if (e->swallowChar) { e->swallowChar = false; return 0; }
        if (!e->multiline && (wp == '\r' || wp == '\n' || wp == 27 || wp == '\t')) return 0;
        if (wp < 32 && wp != '\b' && wp != '\r' && wp != '\n' && wp != '\t') return 0;   // Ctrl+letter: no beep
        break;
    case WM_NCDESTROY: {
        WNDPROC original = e->original;
        e->original = nullptr;
        e->hwnd = nullptr;
        SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)original);
        return CallWindowProcW(original, h, m, wp, lp);
    }
    }
    return CallWindowProcW(e->original, h, m, wp, lp);
}

static void editTheme(rw_edit *e) {
    if (e->hwnd && e->window) SetWindowTheme(e->hwnd, e->window->dark ? L"DarkMode_Explorer" : L"Explorer", nullptr);
}

void rwEditsApplyTheme(rw_window *w) {
    for (rw_edit *e : w->edits) editTheme(e);
}

static void editFont(rw_edit *e) {
    if (!e->hwnd || !e->window) return;
    HFONT old = e->font;
    int px = (int)lround(e->size * e->window->scale());
    e->font = CreateFontW(-px, 0, 0, 0, e->weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                          CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                          rwG.uiFamily == L"Segoe UI Variable Text" ? L"Segoe UI" : rwG.uiFamily.c_str());
    SendMessageW(e->hwnd, WM_SETFONT, (WPARAM)e->font, TRUE);
    SendMessageW(e->hwnd, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, MAKELPARAM(0, 0));
    if (old) DeleteObject(old);
}

void rwEditsRefreshFonts(rw_window *w) {
    for (rw_edit *e : w->edits) { editFont(e); e->frame = RECT{0, 0, 0, 0}; }
}

void rwEditsWindowGone(rw_window *w) {
    for (rw_edit *e : w->edits) { e->hwnd = nullptr; e->window = nullptr; }
    w->edits.clear();
}

LRESULT rwEditColor(HWND h, HDC dc, bool *handled) {
    rw_edit *e = editFor(h);
    if (!isEdit(h, e) || !e->background) { *handled = false; return 0; }
    *handled = true;
    SetTextColor(dc, e->textColor);
    SetBkColor(dc, e->backColor);
    SetBkMode(dc, OPAQUE);
    return (LRESULT)e->background;
}

void rwEditCommand(HWND h, int code) {
    rw_edit *e = editFor(h);
    if (!isEdit(h, e) || !e->ctx) return;
    if (code == EN_CHANGE && !e->updating) rwSend(RW_EV_EDIT_CHANGED, e->ctx);
    else if (code == EN_SETFOCUS) rwSend(RW_EV_EDIT_FOCUS, e->ctx);
    else if (code == EN_KILLFOCUS) rwSend(RW_EV_EDIT_BLUR, e->ctx);
}

extern "C" rw_edit *rw_edit_create(rw_window *w, int multiline, void *ctx) {
    if (!w || !w->hwnd) return nullptr;
    rw_edit *e = new rw_edit();
    e->window = w;
    e->ctx = ctx;
    e->multiline = multiline != 0;
    DWORD style = WS_CHILD | WS_CLIPSIBLINGS | (e->multiline ? (ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN) : ES_AUTOHSCROLL);
    e->hwnd = CreateWindowExW(0, L"EDIT", L"", style, 0, 0, 0, 0, w->hwnd, nullptr, rwG.instance, nullptr);
    if (!e->hwnd) { delete e; return nullptr; }
    SetWindowLongPtrW(e->hwnd, GWLP_USERDATA, (LONG_PTR)e);
    e->original = (WNDPROC)SetWindowLongPtrW(e->hwnd, GWLP_WNDPROC, (LONG_PTR)editProc);
    w->edits.push_back(e);
    editTheme(e);
    editFont(e);
    return e;
}

extern "C" void rw_edit_destroy(rw_edit *e) {
    if (!e) return;
    e->ctx = nullptr;   // its owner is going away: no more events
    if (e->window) {
        auto &v = e->window->edits;
        for (size_t i = 0; i < v.size(); i++) if (v[i] == e) { v.erase(v.begin() + (long)i); break; }
    }
    if (e->hwnd) {
        if (GetFocus() == e->hwnd && e->window) SetFocus(e->window->hwnd);
        DestroyWindow(e->hwnd);   // WM_NCDESTROY restores the procedure
    }
    if (e->font) DeleteObject(e->font);
    if (e->background) DeleteObject(e->background);
    delete e;
}

extern "C" void rw_edit_set_frame(rw_edit *e, double x, double y, double width, double height,
                                  double cx, double cy, double cw, double ch, int visible) {
    if (!e || !e->hwnd || !e->window) return;
    double s = e->window->scale();
    RECT r = {(LONG)lround(x * s), (LONG)lround(y * s), (LONG)lround((x + width) * s), (LONG)lround((y + height) * s)};
    RECT clip = {(LONG)lround(cx * s), (LONG)lround(cy * s), (LONG)lround((cx + cw) * s), (LONG)lround((cy + ch) * s)};
    RECT visibleRect;
    bool show = visible && IntersectRect(&visibleRect, &r, &clip) && r.right > r.left && r.bottom > r.top;
    if (!show) {
        if (e->visible) {
            if (GetFocus() == e->hwnd) SetFocus(e->window->hwnd);
            ShowWindow(e->hwnd, SW_HIDE);
            e->visible = false;
        }
        return;
    }
    if (!EqualRect(&r, &e->frame) || !e->visible) {
        SetWindowPos(e->hwnd, HWND_TOP, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        e->frame = r;
        e->visible = true;
    }
    bool clipped = !EqualRect(&visibleRect, &r);
    if (clipped) {
        HRGN rgn = CreateRectRgn(visibleRect.left - r.left, visibleRect.top - r.top, visibleRect.right - r.left, visibleRect.bottom - r.top);
        SetWindowRgn(e->hwnd, rgn, TRUE);   // the system owns rgn now
        e->clipped = true;
    } else if (e->clipped) {
        SetWindowRgn(e->hwnd, nullptr, TRUE);
        e->clipped = false;
    }
}

extern "C" void rw_edit_set_text(rw_edit *e, const char *text) {
    if (!e || !e->hwnd) return;
    std::wstring t = rwWiden(text);
    if (e->multiline) {
        // EDIT controls want CRLF line breaks.
        std::wstring crlf;
        crlf.reserve(t.size());
        for (size_t i = 0; i < t.size(); i++) {
            if (t[i] == L'\n' && (i == 0 || t[i - 1] != L'\r')) crlf += L'\r';
            crlf += t[i];
        }
        t.swap(crlf);
    }
    e->updating = true;
    SetWindowTextW(e->hwnd, t.c_str());
    e->updating = false;
    int n = GetWindowTextLengthW(e->hwnd);
    SendMessageW(e->hwnd, EM_SETSEL, (WPARAM)n, (LPARAM)n);
}

extern "C" char *rw_edit_copy_text(rw_edit *e) {
    if (!e || !e->hwnd) return rwNarrowDup(L"");
    int n = GetWindowTextLengthW(e->hwnd);
    std::wstring t((size_t)n + 1, L'\0');
    GetWindowTextW(e->hwnd, &t[0], n + 1);
    t.resize((size_t)n);
    if (e->multiline) {
        std::wstring lf;
        lf.reserve(t.size());
        for (wchar_t c : t) if (c != L'\r') lf += c;
        t.swap(lf);
    }
    return rwNarrowDup(t.c_str());
}

extern "C" void rw_edit_set_style(rw_edit *e, float size, int weight, rw_color text, rw_color background, int password) {
    if (!e || !e->hwnd) return;
    if (size != e->size || weight != e->weight) {
        e->size = size;
        e->weight = weight;
        editFont(e);
    }
    COLORREF fg = colorRef(text), bg = colorRef(background);
    if (!e->background || fg != e->textColor || bg != e->backColor) {
        e->textColor = fg;
        e->backColor = bg;
        if (e->background) DeleteObject(e->background);
        e->background = CreateSolidBrush(bg);
        InvalidateRect(e->hwnd, nullptr, TRUE);
    }
    if (!e->multiline) {
        WPARAM ch = password ? (WPARAM)0x25CF : 0;
        if ((WPARAM)SendMessageW(e->hwnd, EM_GETPASSWORDCHAR, 0, 0) != ch) {
            SendMessageW(e->hwnd, EM_SETPASSWORDCHAR, ch, 0);
            InvalidateRect(e->hwnd, nullptr, TRUE);
        }
    }
}

extern "C" void rw_edit_set_placeholder(rw_edit *e, const char *text) {
    if (!e || !e->hwnd) return;
    std::wstring t = rwWiden(text);
    if (t == e->placeholder) return;
    e->placeholder = t;
    SendMessageW(e->hwnd, kSetCueBanner, TRUE, (LPARAM)e->placeholder.c_str());
}

extern "C" void rw_edit_set_enabled(rw_edit *e, int enabled) {
    if (e && e->hwnd && (IsWindowEnabled(e->hwnd) != 0) != (enabled != 0)) EnableWindow(e->hwnd, enabled ? TRUE : FALSE);
}

extern "C" void rw_edit_set_alignment(rw_edit *e, int alignment) {
    if (!e || !e->hwnd) return;
    LONG_PTR style = GetWindowLongPtrW(e->hwnd, GWL_STYLE);
    LONG_PTR next = (style & ~(LONG_PTR)(ES_CENTER | ES_RIGHT)) |
                    (alignment == RW_ALIGN_CENTER ? ES_CENTER : alignment == RW_ALIGN_TRAILING ? ES_RIGHT : ES_LEFT);
    if (next == style) return;
    SetWindowLongPtrW(e->hwnd, GWL_STYLE, next);
    InvalidateRect(e->hwnd, nullptr, TRUE);
}

extern "C" void rw_edit_set_readonly(rw_edit *e, int readonly) {
    if (!e || !e->hwnd) return;
    bool now = (GetWindowLongPtrW(e->hwnd, GWL_STYLE) & ES_READONLY) != 0;
    if (now != (readonly != 0)) SendMessageW(e->hwnd, EM_SETREADONLY, readonly ? TRUE : FALSE, 0);
}

extern "C" void rw_edit_focus(rw_edit *e, int selectAll) {
    if (!e || !e->hwnd) return;
    SetFocus(e->hwnd);
    if (selectAll) SendMessageW(e->hwnd, EM_SETSEL, 0, -1);
}

extern "C" int rw_edit_has_focus(rw_edit *e) {
    return e && e->hwnd && GetFocus() == e->hwnd ? 1 : 0;
}

// MARK: Menus

struct rw_menu {
    HMENU handle = nullptr;
    bool owned = true;
    std::vector<rw_menu *> children;
};

/// Menu titles treat "&" as a mnemonic marker; show it literally.
static std::wstring menuTitle(const char *title) {
    std::wstring t = rwWiden(title), out;
    for (wchar_t c : t) { if (c == L'&') out += L'&'; out += c; }
    return out;
}

extern "C" rw_menu *rw_menu_create(void) {
    rw_menu *m = new rw_menu();
    m->handle = CreatePopupMenu();
    return m;
}

extern "C" void rw_menu_add(rw_menu *m, const char *title, int id, int enabled, int checked) {
    std::wstring t = menuTitle(title);
    AppendMenuW(m->handle, MF_STRING | (enabled ? 0 : MF_GRAYED) | (checked ? MF_CHECKED : 0), (UINT_PTR)id, t.c_str());
}

extern "C" void rw_menu_add_separator(rw_menu *m) { AppendMenuW(m->handle, MF_SEPARATOR, 0, nullptr); }

extern "C" rw_menu *rw_menu_add_submenu(rw_menu *m, const char *title, int enabled) {
    rw_menu *child = new rw_menu();
    child->handle = CreatePopupMenu();
    child->owned = false;   // destroyed with its parent
    std::wstring t = menuTitle(title);
    AppendMenuW(m->handle, MF_POPUP | (enabled ? 0 : MF_GRAYED), (UINT_PTR)child->handle, t.c_str());
    m->children.push_back(child);
    return child;
}

extern "C" int rw_menu_popup(rw_menu *m, rw_window *w, double x, double y) {
    if (!m || !w || !w->hwnd) return 0;
    POINT p = {(LONG)lround(x * w->scale()), (LONG)lround(y * w->scale())};
    ClientToScreen(w->hwnd, &p);
    UINT flags = TPM_RETURNCMD | TPM_NONOTIFY | TPM_LEFTALIGN | TPM_TOPALIGN | TPM_LEFTBUTTON;
    if (GetSystemMetrics(SM_MENUDROPALIGNMENT)) flags = (flags & ~TPM_LEFTALIGN) | TPM_RIGHTALIGN;
    return (int)TrackPopupMenuEx(m->handle, flags, p.x, p.y, w->hwnd, nullptr);
}

static void freeMenu(rw_menu *m) {
    for (rw_menu *c : m->children) freeMenu(c);
    if (m->owned && m->handle) DestroyMenu(m->handle);
    delete m;
}

extern "C" void rw_menu_free(rw_menu *m) { if (m) freeMenu(m); }

extern "C" rw_menu *rw_menubar_create(void) {
    rw_menu *m = new rw_menu();
    m->handle = CreateMenu();
    return m;
}

HMENU rwMenuHandle(rw_menu *m) { return m->handle; }

/// Frees the wrappers of a menu whose handle something else now owns.
void rwMenuRelease(rw_menu *m) {
    for (rw_menu *c : m->children) rwMenuRelease(c);
    delete m;
}

// MARK: Colour

extern "C" int rw_choose_color(rw_window *owner, rw_color initial, rw_color *result) {
    static COLORREF custom[16] = {0};
    CHOOSECOLORW cc = {};
    cc.lStructSize = sizeof(cc);
    cc.hwndOwner = owner ? owner->hwnd : nullptr;
    cc.rgbResult = colorRef(initial);
    cc.lpCustColors = custom;
    cc.Flags = CC_FULLOPEN | CC_RGBINIT | CC_ANYCOLOR;
    if (!ChooseColorW(&cc)) return 0;
    result->r = GetRValue(cc.rgbResult) / 255.0f;
    result->g = GetGValue(cc.rgbResult) / 255.0f;
    result->b = GetBValue(cc.rgbResult) / 255.0f;
    result->a = initial.a;
    return 1;
}

// MARK: Clipboard

static bool openClipboard() {
    for (int i = 0; i < 10; i++) {
        if (OpenClipboard(rwG.messageWindow)) return true;
        Sleep(5);
    }
    return false;
}

static HGLOBAL globalText(const std::wstring &t) {
    HGLOBAL g = GlobalAlloc(GMEM_MOVEABLE, (t.size() + 1) * sizeof(wchar_t));
    if (!g) return nullptr;
    void *p = GlobalLock(g);
    memcpy(p, t.c_str(), (t.size() + 1) * sizeof(wchar_t));
    GlobalUnlock(g);
    return g;
}

static std::wstring crlfText(const char *text) {
    std::wstring t = rwWiden(text), out;
    for (size_t i = 0; i < t.size(); i++) {
        if (t[i] == L'\n' && (i == 0 || t[i - 1] != L'\r')) out += L'\r';
        out += t[i];
    }
    return out;
}

extern "C" void rw_clipboard_set_text(const char *text) {
    if (!openClipboard()) return;
    EmptyClipboard();
    if (HGLOBAL g = globalText(crlfText(text))) {
        if (!SetClipboardData(CF_UNICODETEXT, g)) GlobalFree(g);
    }
    CloseClipboard();
}

extern "C" void rw_clipboard_set_files(const char *const *paths, int count) {
    std::wstring list, text;
    for (int i = 0; i < count; i++) {
        std::wstring p = rwNativePath(paths[i]);
        list += p;
        list += L'\0';
        if (i) text += L"\r\n";
        text += p;
    }
    list += L'\0';
    size_t bytes = sizeof(DROPFILES) + list.size() * sizeof(wchar_t);
    HGLOBAL drop = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
    if (!drop) return;
    DROPFILES *df = (DROPFILES *)GlobalLock(drop);
    df->pFiles = sizeof(DROPFILES);
    df->fWide = TRUE;
    memcpy((BYTE *)df + sizeof(DROPFILES), list.data(), list.size() * sizeof(wchar_t));
    GlobalUnlock(drop);
    if (!openClipboard()) { GlobalFree(drop); return; }
    EmptyClipboard();
    if (!SetClipboardData(CF_HDROP, drop)) GlobalFree(drop);
    // Explorer pastes a copy, not a move.
    UINT effectFormat = RegisterClipboardFormatW(L"Preferred DropEffect");
    if (HGLOBAL effect = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD))) {
        *(DWORD *)GlobalLock(effect) = DROPEFFECT_COPY;
        GlobalUnlock(effect);
        if (!SetClipboardData(effectFormat, effect)) GlobalFree(effect);
    }
    if (HGLOBAL g = globalText(text)) {
        if (!SetClipboardData(CF_UNICODETEXT, g)) GlobalFree(g);
    }
    CloseClipboard();
}

extern "C" char *rw_clipboard_get_text(void) {
    if (!openClipboard()) return nullptr;
    char *out = nullptr;
    if (HANDLE h = GetClipboardData(CF_UNICODETEXT)) {
        if (const wchar_t *p = (const wchar_t *)GlobalLock(h)) {
            std::wstring t;
            for (const wchar_t *c = p; *c; c++) if (*c != L'\r') t += *c;
            out = rwNarrowDup(t.c_str());
            GlobalUnlock(h);
        }
    } else if (HANDLE d = GetClipboardData(CF_HDROP)) {
        HDROP drop = (HDROP)d;
        UINT n = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        std::wstring t;
        for (UINT i = 0; i < n; i++) {
            UINT len = DragQueryFileW(drop, i, nullptr, 0);
            std::wstring p((size_t)len + 1, L'\0');
            DragQueryFileW(drop, i, &p[0], len + 1);
            p.resize(len);
            if (i) t += L'\n';
            t += p;
        }
        out = rwNarrowDup(t.c_str());
    }
    CloseClipboard();
    return out;
}

// MARK: Shell

extern "C" int rw_shell_open(const char *target) {
    std::wstring t = rwWiden(target);
    HINSTANCE r = ShellExecuteW(nullptr, L"open", t.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    return (INT_PTR)r > 32 ? 1 : 0;
}

extern "C" void rw_reveal(const char *const *paths, int count) {
    // Group by folder so each Explorer window selects all of its items.
    std::vector<std::wstring> folders;
    std::vector<std::vector<std::wstring>> items;
    for (int i = 0; i < count; i++) {
        std::wstring p = rwNativePath(paths[i]);
        while (p.size() > 3 && p.back() == L'\\') p.pop_back();
        size_t slash = p.find_last_of(L'\\');
        std::wstring folder = slash == std::wstring::npos ? p : p.substr(0, slash == 2 ? 3 : slash);
        size_t k = 0;
        while (k < folders.size() && folders[k] != folder) k++;
        if (k == folders.size()) { folders.push_back(folder); items.push_back(std::vector<std::wstring>()); }
        items[k].push_back(p);
    }
    for (size_t k = 0; k < folders.size(); k++) {
        PIDLIST_ABSOLUTE folder = ILCreateFromPathW(folders[k].c_str());
        if (!folder) continue;
        std::vector<PIDLIST_ABSOLUTE> full;
        std::vector<PCUITEMID_CHILD> children;
        for (const auto &p : items[k]) {
            if (PIDLIST_ABSOLUTE pidl = ILCreateFromPathW(p.c_str())) {
                full.push_back(pidl);
                children.push_back((PCUITEMID_CHILD)ILFindLastID(pidl));
            }
        }
        if (!children.empty()) SHOpenFolderAndSelectItems(folder, (UINT)children.size(), children.data(), 0);
        else ShellExecuteW(nullptr, L"open", folders[k].c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        for (auto pidl : full) ILFree(pidl);
        ILFree(folder);
    }
}

// MARK: Sounds

extern "C" int rw_play_sound(const char *name) {
    std::wstring n = rwWiden(name);
    bool file = n.find(L'\\') != std::wstring::npos || n.find(L'/') != std::wstring::npos ||
                (n.size() > 4 && lstrcmpiW(n.c_str() + n.size() - 4, L".wav") == 0);
    if (file) n = rwNativePath(name);
    DWORD flags = SND_ASYNC | SND_NODEFAULT | (file ? SND_FILENAME : SND_ALIAS);
    return PlaySoundW(n.c_str(), nullptr, flags) ? 1 : 0;
}

extern "C" void rw_beep(void) { MessageBeep(MB_OK); }

// MARK: File dialogs

static const CLSID kFileOpenDialog = {0xDC1C5A9C, 0xE88A, 0x4DDE, {0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7}};
static const CLSID kFileSaveDialog = {0xC0B4E2F3, 0xBA21, 0x4773, {0x8D, 0xBA, 0x33, 0x5E, 0xC9, 0x46, 0xEB, 0x8B}};

static std::wstring itemPath(IShellItem *item) {
    std::wstring out;
    PWSTR p = nullptr;
    if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &p)) && p) {
        out = p;
        CoTaskMemFree(p);
    }
    return out;
}

extern "C" char *rw_choose_files(rw_window *owner, const char *title, int multiple, int directories, const char *const *extensions, int count) {
    IFileOpenDialog *d = nullptr;
    if (FAILED(CoCreateInstance(kFileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, __uuidof(IFileOpenDialog), (void **)&d))) return nullptr;
    FILEOPENDIALOGOPTIONS opts = 0;
    d->GetOptions(&opts);
    opts |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
    if (multiple) opts |= FOS_ALLOWMULTISELECT;
    if (directories) opts |= FOS_PICKFOLDERS;
    else opts |= FOS_FILEMUSTEXIST;
    d->SetOptions(opts);
    std::wstring t = rwWiden(title);
    if (!t.empty()) d->SetTitle(t.c_str());
    std::wstring spec;
    for (int i = 0; i < count; i++) {
        std::wstring e = rwWiden(extensions[i]);
        while (!e.empty() && (e[0] == L'.' || e[0] == L'*')) e.erase(0, 1);
        if (e.empty()) continue;
        if (!spec.empty()) spec += L';';
        spec += L"*." + e;
    }
    if (!spec.empty() && !directories) {
        COMDLG_FILTERSPEC types[2] = {{L"Supported Files", spec.c_str()}, {L"All Files", L"*.*"}};
        d->SetFileTypes(2, types);
    }
    char *result = nullptr;
    if (SUCCEEDED(d->Show(owner ? owner->hwnd : nullptr))) {
        IShellItemArray *items = nullptr;
        if (SUCCEEDED(d->GetResults(&items)) && items) {
            DWORD n = 0;
            items->GetCount(&n);
            std::wstring all;
            for (DWORD i = 0; i < n; i++) {
                IShellItem *item = nullptr;
                if (SUCCEEDED(items->GetItemAt(i, &item)) && item) {
                    std::wstring p = itemPath(item);
                    if (!p.empty()) { if (!all.empty()) all += L'\n'; all += p; }
                    item->Release();
                }
            }
            items->Release();
            if (!all.empty()) result = rwNarrowDup(all.c_str());
        }
    }
    d->Release();
    return result;
}

extern "C" char *rw_choose_save(rw_window *owner, const char *title, const char *suggested) {
    IFileSaveDialog *d = nullptr;
    if (FAILED(CoCreateInstance(kFileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, __uuidof(IFileSaveDialog), (void **)&d))) return nullptr;
    FILEOPENDIALOGOPTIONS opts = 0;
    d->GetOptions(&opts);
    d->SetOptions(opts | FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT);
    std::wstring t = rwWiden(title), name = rwWiden(suggested);
    if (!t.empty()) d->SetTitle(t.c_str());
    if (!name.empty()) {
        d->SetFileName(name.c_str());
        size_t dot = name.find_last_of(L'.');
        if (dot != std::wstring::npos && dot + 1 < name.size()) d->SetDefaultExtension(name.c_str() + dot + 1);
    }
    char *result = nullptr;
    if (SUCCEEDED(d->Show(owner ? owner->hwnd : nullptr))) {
        IShellItem *item = nullptr;
        if (SUCCEEDED(d->GetResult(&item)) && item) {
            std::wstring p = itemPath(item);
            if (!p.empty()) result = rwNarrowDup(p.c_str());
            item->Release();
        }
    }
    d->Release();
    return result;
}

extern "C" int rw_message_box(rw_window *owner, const char *title, const char *message, int okCancel) {
    std::wstring t = rwWiden(title), m = rwWiden(message);
    int r = MessageBoxW(owner ? owner->hwnd : nullptr, m.c_str(), t.c_str(), (okCancel ? MB_OKCANCEL : MB_OK) | MB_ICONINFORMATION);
    return r == IDOK ? 0 : 1;
}

#endif
