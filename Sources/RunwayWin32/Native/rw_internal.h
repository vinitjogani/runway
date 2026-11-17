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
#include <wincodec.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <commdlg.h>
#include <mmsystem.h>

#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <string>
#include <vector>
#include <unordered_map>

#include "runway_win32.h"

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
    ID2D1HwndRenderTarget *rt = nullptr;
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
    unsigned generation = 0;               // bumps when the render target is recreated
    bool painting = false;

    std::vector<rw_edit *> edits;

    double scale() const { return dpi / 96.0; }
};

ID2D1SolidColorBrush *rwRunBrush(rw_window *w, rw_color c);
void rwDiscardTarget(rw_window *w);
void rwEditsWindowGone(rw_window *w);
void rwEditsRefreshFonts(rw_window *w);
void rwEditsApplyTheme(rw_window *w);
LRESULT rwEditColor(HWND edit, HDC dc, bool *handled);
void rwEditCommand(HWND edit, int code);

#endif
#endif
