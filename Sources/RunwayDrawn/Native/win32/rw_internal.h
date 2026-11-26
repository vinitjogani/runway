// Shared state of the native layer. Windows only.
#ifndef RW_INTERNAL_H
#define RW_INTERNAL_H
#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef WINVER
#define WINVER 0x0A00
#endif

#include <windows.h>
#include <windowsx.h>
#include <d2d1.h>
#include <d2d1helper.h>
#include <dwrite.h>
#include <dwrite_3.h>
#include <wincodec.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <commdlg.h>
#include <mmsystem.h>
#include <ole2.h>
#include <richedit.h>
#include <commctrl.h>

#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <string>
#include <vector>
#include <unordered_map>

#include "runway_drawn.h"

// Diagnostics for development builds (-DRW_DEBUG).
#ifdef RW_DEBUG
#include <stdio.h>
#define RW_LOG(...) (fprintf(stderr, "runway-win32: " __VA_ARGS__), fputc('\n', stderr))
#else
#define RW_LOG(...) ((void)0)
#endif

template <class T> static inline void rwRelease(T *&p) {
    if (p) { p->Release(); p = nullptr; }
}

std::wstring rwWiden(const char *s);
char *rwNarrowDup(const wchar_t *s, int length = -1);
std::wstring rwNativePath(const char *path);

struct RwGlobals {
    rw_event_fn callback = nullptr;
    HINSTANCE instance = nullptr;
    ID2D1Factory *d2d = nullptr;
    IDWriteFactory *dwrite = nullptr;
    IWICImagingFactory *wic = nullptr;
    HWND messageWindow = nullptr;
    std::wstring uiFamily = L"Segoe UI";
    IDWriteFontCollection *privateFonts = nullptr;   // fonts the app brings (rw_register_fonts)
};
extern RwGlobals rwG;

int rwSend(int type, void *ctx);
int rwSendEvent(rw_event &ev);

// A gradient brush, reused while its stops stay the same.
struct RwGradient {
    std::vector<rw_stop> stops;
    bool radial = false;
    ID2D1GradientStopCollection *collection = nullptr;
    ID2D1Brush *brush = nullptr;
};

struct rw_window {
    HWND hwnd = nullptr;
    void *ctx = nullptr;
    rw_window *parent = nullptr;
    bool modal = false;
    bool resizable = true;
    bool shown = false;
    bool tracking = false;
    bool swallowChar = false;
    bool dark = false;
    bool backdrop = false;       // Mica behind a transparent client area
    double minWidth = 0, minHeight = 0;
    UINT dpi = 96;
    HCURSOR cursor = nullptr;
    UINT_PTR timer = 0;

    // Direct2D state; valid between BeginDraw and EndDraw.
    ID2D1RenderTarget *rt = nullptr;           // the window's, or a DC target (rich text layers)
    ID2D1HwndRenderTarget *hwndRt = nullptr;   // the same object for a window (not a reference of its own)
    ID2D1SolidColorBrush *solid = nullptr;
    ID2D1SolidColorBrush *textBrush = nullptr;
    ID2D1Brush *paint = nullptr;           // solid or one of gradients
    ID2D1StrokeStyle *dashStyle = nullptr;
    std::vector<float> dashes;
    float dashWidth = -1;
    bool roundCaps = false;
    std::vector<RwGradient> gradients;
    std::unordered_map<uint32_t, ID2D1SolidColorBrush *> runBrushes;
    float alpha = 1;
    rw_color paintColor = {0, 0, 0, 1};
    float offsetX = 0, offsetY = 0;
    int clipDepth = 0;
    std::vector<char> clipKinds;           // 0 rect, 1 layer (path)
    unsigned generation = 0;               // bumps when the render target is recreated
    bool painting = false;

    std::vector<rw_edit *> edits;
    std::vector<struct rw_rich *> riches;

    // AppKit support.
    bool popup = false;
    bool placed = false;                   // positioned by the app: not centred on show
    bool decorated = true;
    HCURSOR ownedCursor = nullptr;         // made from an image; destroyed with the window
    struct RwDropTarget *drop = nullptr;
    unsigned downKeys[16] = {0};           // keys held, for repeats
    int downCount = 0;
    HWND tooltip = nullptr;

    double scale() const { return dpi / 96.0; }
};

ID2D1SolidColorBrush *rwRunBrush(rw_window *w, rw_color c);
void rwDiscardTarget(rw_window *w);
void rwEditsWindowGone(rw_window *w);
void rwEditsRefreshFonts(rw_window *w);
void rwEditsApplyTheme(rw_window *w);
LRESULT rwEditColor(HWND edit, HDC dc, bool *handled);
void rwEditCommand(HWND edit, int code);

// rw_appkit.cpp
unsigned rwCurrentMods();
// A key message for the window's raw-key handler; true when it was swallowed.
bool rwRawKey(rw_window *w, UINT msg, WPARAM wp, LPARAM lp, bool nativeText);
// A press or release in a native child, offered to the window (monitors).
bool rwChildMouse(rw_window *w, HWND child, UINT msg, LPARAM lp, bool after);
bool rwRichCommand(HWND child, int code);
bool rwRichNotify(rw_window *w, NMHDR *hdr, LRESULT *result);
void rwRichWindowGone(rw_window *w);
void rwRichRefresh(rw_window *w);
void rwDropRevoke(rw_window *w);
void rwTrayMessage(WPARAM wp, LPARAM lp);
extern const UINT rwTrayMessageId;
HMENU rwMenuHandle(rw_menu *m);
void rwMenuRelease(rw_menu *m);
bool rwEnsureWIC();
/// The collection a family is in: the app's own fonts, else the system's (nullptr).
IDWriteFontCollection *rwCollectionFor(const wchar_t *family);
void rwPaintDC(rw_window *surface, HDC dc, RECT rc, UINT dpi, const void *underlay, int event, void *ctx, int button);
SIZE rwOuterSize(HWND h, DWORD style, UINT dpi, double width, double height);

#endif
#endif
