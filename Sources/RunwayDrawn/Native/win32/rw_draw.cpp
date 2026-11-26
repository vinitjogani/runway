// Direct2D drawing, DirectWrite text, WIC images and path geometry.
#ifdef _WIN32
#include "rw_internal.h"
#include <math.h>

// WIC's 32bpp premultiplied BGRA (GUID_WICPixelFormat32bppPBGRA), spelled
// out so no GUID library is needed at link time.
static const GUID kPixelFormatPBGRA = {0x6fddc324, 0x4e03, 0x4bfe, {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x10}};
static const CLSID kWICImagingFactory = {0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
// D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT (Windows 8.1+): colour emoji.
static const D2D1_DRAW_TEXT_OPTIONS kDrawTextColorFont = (D2D1_DRAW_TEXT_OPTIONS)4;
// DWRITE_WORD_WRAPPING_EMERGENCY_BREAK (Windows 8.1+): break words that do not fit.
static const DWRITE_WORD_WRAPPING kWrapEmergency = (DWRITE_WORD_WRAPPING)2;

static inline D2D1_COLOR_F color(rw_color c, float alpha) {
    return D2D1::ColorF(c.r, c.g, c.b, c.a * alpha);
}

// MARK: Render targets

static bool ensureTarget(rw_window *w) {
    if (w->rt) return true;
    RECT rc;
    GetClientRect(w->hwnd, &rc);
    D2D1_PIXEL_FORMAT format = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                                 w->backdrop ? D2D1_ALPHA_MODE_PREMULTIPLIED : D2D1_ALPHA_MODE_IGNORE);
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT, format, (float)w->dpi, (float)w->dpi);
    D2D1_HWND_RENDER_TARGET_PROPERTIES hwndProps =
        D2D1::HwndRenderTargetProperties(w->hwnd, D2D1::SizeU((UINT32)(rc.right > 0 ? rc.right : 1), (UINT32)(rc.bottom > 0 ? rc.bottom : 1)));
    HRESULT hr = rwG.d2d->CreateHwndRenderTarget(props, hwndProps, &w->hwndRt);
    if (FAILED(hr)) { RW_LOG("CreateHwndRenderTarget failed: 0x%08lx", (unsigned long)hr); return false; }
    w->rt = w->hwndRt;
    w->rt->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &w->solid);
    w->rt->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &w->textBrush);
    // Grey-scale antialiasing on transparent (Mica) surfaces and at high
    // DPI, where it is also what the Mac does; ClearType otherwise.
    w->rt->SetTextAntialiasMode(w->backdrop || w->dpi >= 144 ? D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE : D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
    static unsigned generations = 0;
    w->generation = ++generations;   // unique across windows, for image caches
    return w->rt && w->solid && w->textBrush;
}

void rwDiscardTarget(rw_window *w) {
    for (auto &g : w->gradients) { rwRelease(g.brush); rwRelease(g.collection); }
    w->gradients.clear();
    for (auto &kv : w->runBrushes) kv.second->Release();
    w->runBrushes.clear();
    rwRelease(w->dashStyle);
    w->dashes.clear();
    w->paint = nullptr;
    rwRelease(w->solid);
    rwRelease(w->textBrush);
    rwRelease(w->rt);
    w->hwndRt = nullptr;
}

/// Readies a target for a pass of rw_draw_* calls.
static void beginPass(rw_window *w) {
    w->painting = true;
    w->rt->BeginDraw();
    w->rt->SetTransform(D2D1::Matrix3x2F::Identity());
    w->alpha = 1;
    w->offsetX = w->offsetY = 0;
    w->clipDepth = 0;
    w->clipKinds.clear();
    w->paintColor = rw_color{0, 0, 0, 1};
    w->paint = w->solid;
    rw_draw_set_round_caps(w, 0);
    rw_draw_set_dash(w, nullptr, 0);
}

static HRESULT endPass(rw_window *w) {
    while (w->clipDepth > 0) rw_draw_pop_clip(w);
    HRESULT hr = w->rt->EndDraw();
    w->painting = false;
    if (FAILED(hr)) RW_LOG("EndDraw failed: 0x%08lx", (unsigned long)hr);
    return hr;
}

void rwPaintWindow(rw_window *w) {
    if (!ensureTarget(w)) return;
    beginPass(w);
    rwSend(RW_EV_PAINT, w->ctx);
    HRESULT hr = endPass(w);
    if (hr == (HRESULT)D2DERR_RECREATE_TARGET) {
        rwDiscardTarget(w);
        InvalidateRect(w->hwnd, nullptr, FALSE);
    }
}

/// A drawing surface over a device context (a native child's layers): the
/// same rw_draw_* calls through a DC render target, which replaces the
/// whole rect, so `underlay` (top-down BGRA of the rect's size, or NULL) is
/// drawn first. `event` goes to `ctx` while the pass runs.
void rwPaintDC(rw_window *surface, HDC dc, RECT rc, UINT dpi, const void *underlay, int event, void *ctx, int button) {
    if (!surface->rt) {
        D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
            D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), (float)dpi, (float)dpi);
        ID2D1DCRenderTarget *t = nullptr;
        if (FAILED(rwG.d2d->CreateDCRenderTarget(&props, &t))) return;
        surface->rt = t;
        t->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &surface->solid);
        t->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &surface->textBrush);
        static unsigned generations = 0x80000000u;
        surface->generation = ++generations;
    }
    surface->dpi = dpi;
    surface->rt->SetDpi((float)dpi, (float)dpi);
    if (FAILED(((ID2D1DCRenderTarget *)surface->rt)->BindDC(dc, &rc))) return;
    beginPass(surface);
    if (underlay) {
        UINT32 w = (UINT32)(rc.right - rc.left), h = (UINT32)(rc.bottom - rc.top);
        ID2D1Bitmap *b = nullptr;
        D2D1_BITMAP_PROPERTIES bp = D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 96, 96);
        if (SUCCEEDED(surface->rt->CreateBitmap(D2D1::SizeU(w, h), underlay, w * 4, bp, &b))) {
            D2D1_SIZE_F s = surface->rt->GetSize();
            surface->rt->DrawBitmap(b, D2D1::RectF(0, 0, s.width, s.height), 1, D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR, nullptr);
            b->Release();
        }
    }
    rw_event ev = {};
    ev.type = event;
    ev.ctx = ctx;
    ev.button = button;
    rwSendEvent(ev);
    if (endPass(surface) == (HRESULT)D2DERR_RECREATE_TARGET) rwDiscardTarget(surface);
}

ID2D1SolidColorBrush *rwRunBrush(rw_window *w, rw_color c) {
    auto byte = [](float v) -> uint32_t { return (uint32_t)lroundf((v < 0 ? 0 : v > 1 ? 1 : v) * 255); };
    float a = c.a * w->alpha;
    uint32_t key = byte(c.r) << 24 | byte(c.g) << 16 | byte(c.b) << 8 | byte(a);
    auto it = w->runBrushes.find(key);
    if (it != w->runBrushes.end()) return it->second;
    if (w->runBrushes.size() > 128) {
        for (auto &kv : w->runBrushes) kv.second->Release();
        w->runBrushes.clear();
    }
    ID2D1SolidColorBrush *b = nullptr;
    w->rt->CreateSolidColorBrush(color(c, w->alpha), &b);
    if (b) w->runBrushes[key] = b;
    return b;
}

// MARK: State

extern "C" void rw_draw_clear(rw_window *w, rw_color c) {
    if (!w->painting) return;
    w->rt->Clear(w->backdrop ? D2D1::ColorF(0, 0, 0, 0) : D2D1::ColorF(c.r, c.g, c.b, 1));
    if (w->backdrop && c.a > 0 && c.a < 1) {
        // A translucent wash over the backdrop.
        w->solid->SetColor(D2D1::ColorF(c.r, c.g, c.b, c.a));
        D2D1_SIZE_F s = w->rt->GetSize();
        w->rt->FillRectangle(D2D1::RectF(0, 0, s.width, s.height), w->solid);
    }
}

extern "C" void rw_draw_set_offset(rw_window *w, double x, double y) {
    if (!w->painting) return;
    w->offsetX = (float)x;
    w->offsetY = (float)y;
    w->rt->SetTransform(D2D1::Matrix3x2F::Translation((float)x, (float)y));
}

extern "C" void rw_draw_set_transform(rw_window *w, double a, double b, double c, double d, double tx, double ty) {
    if (!w->painting) return;
    D2D1::Matrix3x2F m((float)a, (float)b, (float)c, (float)d, (float)tx, (float)ty);
    w->rt->SetTransform(m * D2D1::Matrix3x2F::Translation(w->offsetX, w->offsetY));
}

extern "C" void rw_draw_set_alpha(rw_window *w, float alpha) {
    w->alpha = alpha < 0 ? 0 : alpha > 1 ? 1 : alpha;
    if (w->paint == w->solid && w->solid) w->solid->SetColor(color(w->paintColor, w->alpha));
    else if (w->paint) w->paint->SetOpacity(w->alpha);
}

extern "C" void rw_draw_push_clip(rw_window *w, double x, double y, double width, double height) {
    if (!w->painting) return;
    w->rt->PushAxisAlignedClip(D2D1::RectF((float)x, (float)y, (float)(x + width), (float)(y + height)), D2D1_ANTIALIAS_MODE_ALIASED);
    w->clipDepth++;
    w->clipKinds.push_back(0);
}

static ID2D1PathGeometry *pathGeometry(rw_path *p);

extern "C" void rw_draw_push_clip_path(rw_window *w, rw_path *p) {
    if (!w->painting || !p) return;
    ID2D1PathGeometry *g = pathGeometry(p);
    ID2D1Layer *layer = nullptr;
    if (!g || FAILED(w->rt->CreateLayer(nullptr, &layer))) {
        // Nothing to clip with: clip everything, keeping push and pop paired.
        w->rt->PushAxisAlignedClip(D2D1::RectF(0, 0, 0, 0), D2D1_ANTIALIAS_MODE_ALIASED);
        w->clipDepth++;
        w->clipKinds.push_back(0);
        return;
    }
    D2D1_MATRIX_3X2_F t;
    w->rt->GetTransform(&t);
    w->rt->PushLayer(D2D1::LayerParameters(D2D1::InfiniteRect(), g, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, t), layer);
    layer->Release();   // the target keeps it while pushed
    w->clipDepth++;
    w->clipKinds.push_back(1);
}

extern "C" void rw_draw_pop_clip(rw_window *w) {
    if (!w->painting || w->clipDepth == 0) return;
    char kind = w->clipKinds.empty() ? 0 : w->clipKinds.back();
    if (!w->clipKinds.empty()) w->clipKinds.pop_back();
    if (kind == 1) w->rt->PopLayer(); else w->rt->PopAxisAlignedClip();
    w->clipDepth--;
}

extern "C" void rw_draw_paint_color(rw_window *w, rw_color c) {
    if (!w->painting) return;
    w->paintColor = c;
    w->solid->SetColor(color(c, w->alpha));
    w->paint = w->solid;
}

static bool sameStops(const std::vector<rw_stop> &a, const rw_stop *b, int n) {
    if ((int)a.size() != n) return false;
    for (int i = 0; i < n; i++) {
        if (a[i].location != b[i].location || a[i].color.r != b[i].color.r || a[i].color.g != b[i].color.g ||
            a[i].color.b != b[i].color.b || a[i].color.a != b[i].color.a) return false;
    }
    return true;
}

/// A cached gradient brush for these stops (at most 16 per window).
static RwGradient *gradient(rw_window *w, const rw_stop *stops, int n, bool radial) {
    for (auto &g : w->gradients) if (g.radial == radial && sameStops(g.stops, stops, n)) return &g;
    if (w->gradients.size() >= 16) {
        RwGradient &old = w->gradients.front();
        rwRelease(old.brush);
        rwRelease(old.collection);
        w->gradients.erase(w->gradients.begin());
    }
    std::vector<D2D1_GRADIENT_STOP> d(n > 0 ? (size_t)n : 1);
    for (int i = 0; i < n; i++) d[i] = D2D1::GradientStop(stops[i].location, color(stops[i].color, 1));
    if (n == 0) d[0] = D2D1::GradientStop(0, D2D1::ColorF(0, 0, 0, 0));
    RwGradient g;
    g.stops.assign(stops, stops + n);
    g.radial = radial;
    if (FAILED(w->rt->CreateGradientStopCollection(d.data(), (UINT32)d.size(), &g.collection))) return nullptr;
    if (radial) {
        ID2D1RadialGradientBrush *b = nullptr;
        w->rt->CreateRadialGradientBrush(D2D1::RadialGradientBrushProperties(D2D1::Point2F(0, 0), D2D1::Point2F(0, 0), 1, 1), g.collection, &b);
        g.brush = b;
    } else {
        ID2D1LinearGradientBrush *b = nullptr;
        w->rt->CreateLinearGradientBrush(D2D1::LinearGradientBrushProperties(D2D1::Point2F(0, 0), D2D1::Point2F(0, 1)), g.collection, &b);
        g.brush = b;
    }
    if (!g.brush) { rwRelease(g.collection); return nullptr; }
    w->gradients.push_back(g);
    return &w->gradients.back();
}

extern "C" void rw_draw_paint_linear(rw_window *w, double x0, double y0, double x1, double y1, const rw_stop *stops, int count) {
    if (!w->painting) return;
    RwGradient *g = gradient(w, stops, count, false);
    if (!g) return;
    ID2D1LinearGradientBrush *b = (ID2D1LinearGradientBrush *)g->brush;
    b->SetStartPoint(D2D1::Point2F((float)x0, (float)y0));
    b->SetEndPoint(D2D1::Point2F((float)x1, (float)y1));
    b->SetOpacity(w->alpha);
    w->paint = b;
}

extern "C" void rw_draw_paint_radial(rw_window *w, double cx, double cy, double r0, double r1, const rw_stop *stops, int count) {
    if (!w->painting) return;
    // Direct2D's radial gradients start at the centre; an inner radius is
    // folded into the stops.
    std::vector<rw_stop> s(stops, stops + count);
    if (r1 > 0 && r0 > 0 && r0 < r1) {
        for (auto &st : s) st.location = (float)((r0 + st.location * (r1 - r0)) / r1);
    }
    RwGradient *g = gradient(w, s.data(), (int)s.size(), true);
    if (!g) return;
    ID2D1RadialGradientBrush *b = (ID2D1RadialGradientBrush *)g->brush;
    b->SetCenter(D2D1::Point2F((float)cx, (float)cy));
    b->SetGradientOriginOffset(D2D1::Point2F(0, 0));
    b->SetRadiusX((float)(r1 > 0 ? r1 : 0.001));
    b->SetRadiusY((float)(r1 > 0 ? r1 : 0.001));
    b->SetOpacity(w->alpha);
    w->paint = b;
}

extern "C" void rw_draw_set_dash(rw_window *w, const float *dashes, int count) {
    if (count <= 0) { if (w->dashStyle || !w->dashes.empty()) { rwRelease(w->dashStyle); w->dashes.clear(); } return; }
    std::vector<float> d(dashes, dashes + count);
    if (d == w->dashes && w->dashStyle) return;
    rwRelease(w->dashStyle);
    w->dashes = d;
    w->dashWidth = -1;
    // Direct2D dashes are in multiples of the stroke width; we keep them in
    // DIPs and rescale per stroke (see strokeStyleFor).
}

extern "C" void rw_draw_set_round_caps(rw_window *w, int round) {
    if (w->roundCaps == (round != 0)) return;
    w->roundCaps = round != 0;
    rwRelease(w->dashStyle);
    w->dashWidth = -1;
}

/// The stroke style for the current dashes and caps at a stroke width
/// (cached for the last width; nullptr means plain solid strokes).
static ID2D1StrokeStyle *strokeStyleFor(rw_window *w, float lineWidth) {
    if (w->dashes.empty() && !w->roundCaps) return nullptr;
    if (w->dashStyle && (w->dashes.empty() || w->dashWidth == lineWidth)) return w->dashStyle;
    rwRelease(w->dashStyle);
    std::vector<float> scaled(w->dashes);
    float lw = lineWidth > 0 ? lineWidth : 1;
    for (auto &v : scaled) v /= lw;
    D2D1_CAP_STYLE cap = w->roundCaps ? D2D1_CAP_STYLE_ROUND : D2D1_CAP_STYLE_FLAT;
    D2D1_STROKE_STYLE_PROPERTIES p = D2D1::StrokeStyleProperties(cap, cap, cap, w->roundCaps ? D2D1_LINE_JOIN_ROUND : D2D1_LINE_JOIN_MITER,
                                                                 10.0f, scaled.empty() ? D2D1_DASH_STYLE_SOLID : D2D1_DASH_STYLE_CUSTOM, 0.0f);
    rwG.d2d->CreateStrokeStyle(p, scaled.empty() ? nullptr : scaled.data(), (UINT32)scaled.size(), &w->dashStyle);
    w->dashWidth = lineWidth;
    return w->dashStyle;
}

// MARK: Shapes

extern "C" void rw_draw_rect(rw_window *w, int fill, double x, double y, double width, double height, double radius, double lineWidth) {
    if (!w->painting || !w->paint || width <= 0 || height <= 0) return;
    D2D1_RECT_F r = D2D1::RectF((float)x, (float)y, (float)(x + width), (float)(y + height));
    float rad = (float)fmin(radius, fmin(width, height) / 2);
    if (rad > 0) {
        D2D1_ROUNDED_RECT rr = D2D1::RoundedRect(r, rad, rad);
        if (fill) w->rt->FillRoundedRectangle(rr, w->paint);
        else w->rt->DrawRoundedRectangle(rr, w->paint, (float)lineWidth, strokeStyleFor(w, (float)lineWidth));
    } else {
        if (fill) w->rt->FillRectangle(r, w->paint);
        else w->rt->DrawRectangle(r, w->paint, (float)lineWidth, strokeStyleFor(w, (float)lineWidth));
    }
}

extern "C" void rw_draw_ellipse(rw_window *w, int fill, double x, double y, double width, double height, double lineWidth) {
    if (!w->painting || !w->paint || width <= 0 || height <= 0) return;
    D2D1_ELLIPSE e = D2D1::Ellipse(D2D1::Point2F((float)(x + width / 2), (float)(y + height / 2)), (float)(width / 2), (float)(height / 2));
    if (fill) w->rt->FillEllipse(e, w->paint);
    else w->rt->DrawEllipse(e, w->paint, (float)lineWidth, strokeStyleFor(w, (float)lineWidth));
}

extern "C" void rw_draw_line(rw_window *w, double x0, double y0, double x1, double y1, double lineWidth) {
    if (!w->painting || !w->paint) return;
    w->rt->DrawLine(D2D1::Point2F((float)x0, (float)y0), D2D1::Point2F((float)x1, (float)y1), w->paint, (float)lineWidth,
                    strokeStyleFor(w, (float)lineWidth));
}

// MARK: Paths

struct rw_path {
    struct Op { int kind; float v[6]; };   // 0 move, 1 line, 2 quad, 3 cubic, 4 close
    std::vector<Op> ops;
    ID2D1PathGeometry *geometry = nullptr;
    bool evenOdd = false;
};

extern "C" void rw_path_set_even_odd(rw_path *p, int on) {
    if (!p || p->evenOdd == (on != 0)) return;
    p->evenOdd = on != 0;
    rwRelease(p->geometry);
}

extern "C" rw_path *rw_path_create(void) { return new rw_path(); }

static void addOp(rw_path *p, int kind, double a, double b, double c, double d, double e, double f) {
    rw_path::Op op = {kind, {(float)a, (float)b, (float)c, (float)d, (float)e, (float)f}};
    p->ops.push_back(op);
    rwRelease(p->geometry);
}

extern "C" void rw_path_move(rw_path *p, double x, double y) { addOp(p, 0, x, y, 0, 0, 0, 0); }
extern "C" void rw_path_line(rw_path *p, double x, double y) { addOp(p, 1, x, y, 0, 0, 0, 0); }
extern "C" void rw_path_quad(rw_path *p, double cx, double cy, double x, double y) { addOp(p, 2, cx, cy, x, y, 0, 0); }
extern "C" void rw_path_cubic(rw_path *p, double c1x, double c1y, double c2x, double c2y, double x, double y) { addOp(p, 3, c1x, c1y, c2x, c2y, x, y); }
extern "C" void rw_path_close(rw_path *p) { addOp(p, 4, 0, 0, 0, 0, 0, 0); }

extern "C" void rw_path_free(rw_path *p) {
    if (!p) return;
    rwRelease(p->geometry);
    delete p;
}

static ID2D1PathGeometry *pathGeometry(rw_path *p) {
    if (p->geometry) return p->geometry;
    if (FAILED(rwG.d2d->CreatePathGeometry(&p->geometry))) return nullptr;
    ID2D1GeometrySink *sink = nullptr;
    if (FAILED(p->geometry->Open(&sink))) { rwRelease(p->geometry); return nullptr; }
    sink->SetFillMode(p->evenOdd ? D2D1_FILL_MODE_ALTERNATE : D2D1_FILL_MODE_WINDING);
    bool open = false;
    D2D1_POINT_2F start = D2D1::Point2F(0, 0), current = start;
    for (const auto &op : p->ops) {
        if (op.kind != 0 && op.kind != 4 && !open) {
            sink->BeginFigure(current, D2D1_FIGURE_BEGIN_FILLED);
            start = current;
            open = true;
        }
        switch (op.kind) {
        case 0:
            if (open) sink->EndFigure(D2D1_FIGURE_END_OPEN);
            current = D2D1::Point2F(op.v[0], op.v[1]);
            sink->BeginFigure(current, D2D1_FIGURE_BEGIN_FILLED);
            start = current;
            open = true;
            break;
        case 1:
            current = D2D1::Point2F(op.v[0], op.v[1]);
            sink->AddLine(current);
            break;
        case 2:
            current = D2D1::Point2F(op.v[2], op.v[3]);
            sink->AddQuadraticBezier(D2D1::QuadraticBezierSegment(D2D1::Point2F(op.v[0], op.v[1]), current));
            break;
        case 3:
            current = D2D1::Point2F(op.v[4], op.v[5]);
            sink->AddBezier(D2D1::BezierSegment(D2D1::Point2F(op.v[0], op.v[1]), D2D1::Point2F(op.v[2], op.v[3]), current));
            break;
        case 4:
            if (open) sink->EndFigure(D2D1_FIGURE_END_CLOSED);
            open = false;
            current = start;
            break;
        }
    }
    if (open) sink->EndFigure(D2D1_FIGURE_END_OPEN);
    sink->Close();
    sink->Release();
    return p->geometry;
}

extern "C" void rw_draw_path(rw_window *w, int fill, rw_path *p, double lineWidth) {
    if (!w->painting || !w->paint || !p || p->ops.empty()) return;
    ID2D1PathGeometry *g = pathGeometry(p);
    if (!g) return;
    if (fill) w->rt->FillGeometry(g, w->paint, nullptr);
    else w->rt->DrawGeometry(g, w->paint, (float)lineWidth, strokeStyleFor(w, (float)lineWidth));
}

// MARK: Text

struct RwRange {
    UINT32 start = 0, length = 0;
    std::wstring family;
    float size = 13;
    DWRITE_FONT_WEIGHT weight = DWRITE_FONT_WEIGHT_NORMAL;
    DWRITE_FONT_STYLE style = DWRITE_FONT_STYLE_NORMAL;
    bool tabular = false, underline = false, strikethrough = false, hasColor = false;
    rw_color color = {0, 0, 0, 1};
};

struct rw_text {
    std::wstring string;
    std::vector<RwRange> ranges;
    int alignment = RW_ALIGN_LEADING;
    int lineLimit = 0;
    int truncation = RW_TRUNCATE_TAIL;
    IDWriteTextLayout *layout = nullptr;
    float layoutWidth = -1, layoutHeight = -1;
    // Head and middle truncation: a shortened copy for one width.
    IDWriteTextLayout *shortened = nullptr;
    float shortenedWidth = -1;
    std::vector<DWRITE_LINE_METRICS> lines;
};

static IDWriteTextFormat *makeFormat(const RwRange &r) {
    IDWriteTextFormat *f = nullptr;
    HRESULT hr = rwG.dwrite->CreateTextFormat(r.family.c_str(), rwCollectionFor(r.family.c_str()), r.weight, r.style, DWRITE_FONT_STRETCH_NORMAL, r.size, L"en-us", &f);
    if (FAILED(hr)) RW_LOG("CreateTextFormat failed: 0x%08lx", (unsigned long)hr);
    return f;
}

static IDWriteTextLayout *makeLayout(rw_text *t, const std::wstring &s, bool styleRanges, float maxWidth, float maxHeight) {
    if (t->ranges.empty()) return nullptr;
    IDWriteTextFormat *format = makeFormat(t->ranges[0]);
    if (!format) return nullptr;
    IDWriteTextLayout *layout = nullptr;
    HRESULT hr = rwG.dwrite->CreateTextLayout(s.c_str(), (UINT32)s.size(), format, maxWidth, maxHeight, &layout);
    if (FAILED(hr)) RW_LOG("CreateTextLayout failed: 0x%08lx", (unsigned long)hr);
    if (!layout) { format->Release(); return nullptr; }
    layout->SetTextAlignment(t->alignment == RW_ALIGN_CENTER ? DWRITE_TEXT_ALIGNMENT_CENTER
                             : t->alignment == RW_ALIGN_TRAILING ? DWRITE_TEXT_ALIGNMENT_TRAILING : DWRITE_TEXT_ALIGNMENT_LEADING);
    if (t->lineLimit == 1) layout->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    else if (FAILED(layout->SetWordWrapping(kWrapEmergency))) layout->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
    if (t->lineLimit > 0) {
        DWRITE_TRIMMING trimming = {DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        IDWriteInlineObject *sign = nullptr;
        rwG.dwrite->CreateEllipsisTrimmingSign(format, &sign);
        layout->SetTrimming(&trimming, sign);
        if (sign) sign->Release();
    }
    for (const RwRange &r : t->ranges) {
        if (!styleRanges && &r != &t->ranges[0]) break;
        DWRITE_TEXT_RANGE range = {styleRanges ? r.start : 0, styleRanges ? r.length : (UINT32)s.size()};
        if (range.length == 0) continue;
        layout->SetFontFamilyName(r.family.c_str(), range);
        if (rwG.privateFonts) {
            // Each run in the collection its family is in.
            IDWriteFontCollection *c = rwCollectionFor(r.family.c_str());
            if (!c) {
                static IDWriteFontCollection *system = nullptr;
                if (!system) rwG.dwrite->GetSystemFontCollection(&system, FALSE);
                c = system;
            }
            if (c) layout->SetFontCollection(c, range);
        }
        layout->SetFontSize(r.size, range);
        layout->SetFontWeight(r.weight, range);
        layout->SetFontStyle(r.style, range);
        if (r.underline) layout->SetUnderline(TRUE, range);
        if (r.strikethrough) layout->SetStrikethrough(TRUE, range);
        if (r.tabular) {
            IDWriteTypography *typo = nullptr;
            if (SUCCEEDED(rwG.dwrite->CreateTypography(&typo))) {
                DWRITE_FONT_FEATURE feature = {DWRITE_FONT_FEATURE_TAG_TABULAR_FIGURES, 1};
                typo->AddFontFeature(feature);
                layout->SetTypography(typo, range);
                typo->Release();
            }
        }
    }
    format->Release();
    return layout;
}

extern "C" rw_text *rw_text_create(const rw_text_run *runs, int count, int alignment, int lineLimit, int truncation) {
    rw_text *t = new rw_text();
    t->alignment = alignment;
    t->lineLimit = lineLimit > 0 ? lineLimit : 0;
    t->truncation = truncation;
    for (int i = 0; i < count; i++) {
        RwRange r;
        std::wstring s = rwWiden(runs[i].text);
        r.start = (UINT32)t->string.size();
        r.length = (UINT32)s.size();
        t->string += s;
        r.family = runs[i].family && *runs[i].family ? rwWiden(runs[i].family) : rwG.uiFamily;
        r.size = runs[i].size > 0 ? runs[i].size : 13;
        int weight = runs[i].weight < 1 ? 400 : runs[i].weight > 999 ? 999 : runs[i].weight;
        r.weight = (DWRITE_FONT_WEIGHT)weight;
        r.style = runs[i].italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL;
        r.tabular = runs[i].tabular_digits != 0;
        r.underline = runs[i].underline != 0;
        r.strikethrough = runs[i].strikethrough != 0;
        r.hasColor = runs[i].has_color != 0;
        r.color = runs[i].color;
        t->ranges.push_back(r);
    }
    if (t->ranges.empty()) {
        RwRange r;
        r.family = rwG.uiFamily;
        t->ranges.push_back(r);
    }
    return t;
}

extern "C" void rw_text_free(rw_text *t) {
    if (!t) return;
    rwRelease(t->layout);
    rwRelease(t->shortened);
    delete t;
}

static IDWriteTextLayout *layoutFor(rw_text *t, float maxWidth, float maxHeight) {
    if (!t->layout) {
        t->layout = makeLayout(t, t->string, true, maxWidth, maxHeight);
        t->layoutWidth = maxWidth;
        t->layoutHeight = maxHeight;
        return t->layout;
    }
    if (t->layoutWidth != maxWidth) { t->layout->SetMaxWidth(maxWidth); t->layoutWidth = maxWidth; }
    if (t->layoutHeight != maxHeight) { t->layout->SetMaxHeight(maxHeight); t->layoutHeight = maxHeight; }
    return t->layout;
}

/// The height of the first `limit` lines of the current layout.
static float limitedHeight(rw_text *t, IDWriteTextLayout *layout, float fullHeight) {
    if (t->lineLimit <= 0) return fullHeight;
    UINT32 count = 0;
    layout->GetLineMetrics(nullptr, 0, &count);
    if (count <= (UINT32)t->lineLimit) return fullHeight;
    t->lines.resize(count);
    if (FAILED(layout->GetLineMetrics(t->lines.data(), count, &count))) return fullHeight;
    float h = 0;
    for (int i = 0; i < t->lineLimit && i < (int)count; i++) h += t->lines[i].height;
    return h;
}

static const float kUnbounded = 100000.0f;

extern "C" void rw_text_measure(rw_text *t, double maxWidth, double *width, double *height) {
    *width = 0;
    *height = 0;
    float mw = maxWidth > 0 ? (float)maxWidth : kUnbounded;
    IDWriteTextLayout *layout = layoutFor(t, mw, kUnbounded);
    if (!layout) return;
    DWRITE_TEXT_METRICS m;
    HRESULT hr = layout->GetMetrics(&m);
    if (FAILED(hr)) { RW_LOG("GetMetrics failed: 0x%08lx", (unsigned long)hr); return; }
    double w = maxWidth > 0 ? m.width : m.widthIncludingTrailingWhitespace;
    if (maxWidth > 0 && w > maxWidth) w = maxWidth;
    *width = w;
    *height = limitedHeight(t, layout, m.height);
}

extern "C" int rw_text_baselines(rw_text *t, double maxWidth, double *out, int max) {
    float mw = maxWidth > 0 ? (float)maxWidth : kUnbounded;
    IDWriteTextLayout *layout = layoutFor(t, mw, kUnbounded);
    if (!layout) return 0;
    UINT32 n = 0;
    layout->GetLineMetrics(nullptr, 0, &n);
    if (n == 0) return 0;
    std::vector<DWRITE_LINE_METRICS> lines(n);
    if (FAILED(layout->GetLineMetrics(lines.data(), n, &n))) return 0;
    int limit = t->lineLimit > 0 && (UINT32)t->lineLimit < n ? t->lineLimit : (int)n;
    double top = 0;
    int count = 0;
    for (int i = 0; i < limit && count < max; i++) {
        out[count++] = top + lines[(size_t)i].baseline;
        top += lines[(size_t)i].height;
    }
    return count;
}

/// A single line shortened at its head or middle to fit `width`.
static IDWriteTextLayout *shortenedLayout(rw_text *t, float width) {
    if (t->shortened && t->shortenedWidth == width) return t->shortened;
    rwRelease(t->shortened);
    const std::wstring &s = t->string;
    auto candidate = [&](size_t keep) {
        std::wstring out;
        if (t->truncation == RW_TRUNCATE_HEAD) out = L"\x2026" + s.substr(s.size() - keep);
        else out = s.substr(0, (keep + 1) / 2) + L"\x2026" + s.substr(s.size() - keep / 2);
        return out;
    };
    size_t lo = 0, hi = s.size();
    IDWriteTextLayout *best = nullptr;
    while (lo <= hi) {
        size_t mid = (lo + hi) / 2;
        IDWriteTextLayout *l = makeLayout(t, candidate(mid), false, kUnbounded, kUnbounded);
        DWRITE_TEXT_METRICS m;
        bool fits = l && SUCCEEDED(l->GetMetrics(&m)) && m.widthIncludingTrailingWhitespace <= width;
        if (fits) {
            rwRelease(best);
            best = l;
            lo = mid + 1;
        } else {
            rwRelease(l);
            if (mid == 0) break;
            hi = mid - 1;
        }
    }
    if (best) best->SetMaxWidth(width);
    t->shortened = best;
    t->shortenedWidth = width;
    return best;
}

extern "C" void rw_draw_text(rw_window *w, rw_text *t, double x, double y, double width, double height, rw_color c) {
    if (!w->painting || !t) return;
    float bw = width > 0 ? (float)width : kUnbounded;
    IDWriteTextLayout *layout = layoutFor(t, bw, kUnbounded);
    if (!layout) return;
    if (t->lineLimit == 1 && t->truncation != RW_TRUNCATE_TAIL) {
        // Trimmed layouts report their trimmed width, so test the natural one.
        DWRITE_TEXT_METRICS m;
        IDWriteTextLayout *natural = layoutFor(t, kUnbounded, kUnbounded);
        if (natural && SUCCEEDED(natural->GetMetrics(&m)) && m.widthIncludingTrailingWhitespace > bw + 0.5f) {
            if (IDWriteTextLayout *s = shortenedLayout(t, bw)) layout = s;
        }
        if (layout != t->shortened) layout = layoutFor(t, bw, kUnbounded);
    } else if (t->lineLimit > 0) {
        DWRITE_TEXT_METRICS m;
        layout->GetMetrics(&m);
        float h = limitedHeight(t, layout, m.height);
        if (h < m.height) layoutFor(t, bw, h);   // the trimming sign goes on the last visible line
    }
    if (!layout) return;
    for (const RwRange &r : t->ranges) {
        if (!r.hasColor || r.length == 0 || layout != t->layout) continue;
        DWRITE_TEXT_RANGE range = {r.start, r.length};
        layout->SetDrawingEffect(rwRunBrush(w, r.color), range);
    }
    w->textBrush->SetColor(color(c, w->alpha));
    w->rt->DrawTextLayout(D2D1::Point2F((float)x, (float)y), layout, w->textBrush, kDrawTextColorFont);
    (void)height;
}

// MARK: Images

struct rw_image {
    UINT width = 0, height = 0;
    std::vector<BYTE> pixels;          // premultiplied BGRA
    ID2D1Bitmap *bitmap = nullptr;
    rw_window *owner = nullptr;
    unsigned generation = 0;
};

bool rwEnsureWIC() {
    if (rwG.wic) return true;
    return SUCCEEDED(CoCreateInstance(kWICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, __uuidof(IWICImagingFactory), (void **)&rwG.wic));
}

extern "C" rw_image *rw_image_load_file(const char *path) {
    if (!rwEnsureWIC()) return nullptr;
    std::wstring p = rwNativePath(path);
    IWICBitmapDecoder *decoder = nullptr;
    IWICBitmapFrameDecode *frame = nullptr;
    IWICFormatConverter *converter = nullptr;
    rw_image *img = nullptr;
    if (SUCCEEDED(rwG.wic->CreateDecoderFromFilename(p.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder)) &&
        SUCCEEDED(decoder->GetFrame(0, &frame)) &&
        SUCCEEDED(rwG.wic->CreateFormatConverter(&converter)) &&
        SUCCEEDED(converter->Initialize(frame, kPixelFormatPBGRA, WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeMedianCut))) {
        UINT w = 0, h = 0;
        converter->GetSize(&w, &h);
        if (w > 0 && h > 0) {
            img = new rw_image();
            img->width = w;
            img->height = h;
            img->pixels.resize((size_t)w * h * 4);
            if (FAILED(converter->CopyPixels(nullptr, w * 4, (UINT)img->pixels.size(), img->pixels.data()))) {
                delete img;
                img = nullptr;
            }
        }
    }
    rwRelease(converter);
    rwRelease(frame);
    rwRelease(decoder);
    return img;
}

extern "C" rw_image *rw_image_from_rgba(int width, int height, const uint8_t *rgba) {
    if (width <= 0 || height <= 0 || !rgba) return nullptr;
    rw_image *img = new rw_image();
    img->width = (UINT)width;
    img->height = (UINT)height;
    size_t n = (size_t)width * height;
    img->pixels.resize(n * 4);
    for (size_t i = 0; i < n; i++) {
        unsigned a = rgba[i * 4 + 3];
        img->pixels[i * 4 + 0] = (BYTE)(rgba[i * 4 + 2] * a / 255);
        img->pixels[i * 4 + 1] = (BYTE)(rgba[i * 4 + 1] * a / 255);
        img->pixels[i * 4 + 2] = (BYTE)(rgba[i * 4 + 0] * a / 255);
        img->pixels[i * 4 + 3] = (BYTE)a;
    }
    return img;
}

extern "C" void rw_image_size(rw_image *img, int *width, int *height) {
    *width = img ? (int)img->width : 0;
    *height = img ? (int)img->height : 0;
}

extern "C" void rw_image_free(rw_image *img) {
    if (!img) return;
    rwRelease(img->bitmap);
    delete img;
}

extern "C" void rw_draw_image(rw_window *w, rw_image *img, double x, double y, double width, double height) {
    if (!w->painting || !img || width <= 0 || height <= 0) return;
    if (!img->bitmap || img->owner != w || img->generation != w->generation) {
        rwRelease(img->bitmap);
        D2D1_BITMAP_PROPERTIES props = D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
        if (FAILED(w->rt->CreateBitmap(D2D1::SizeU(img->width, img->height), img->pixels.data(), img->width * 4, props, &img->bitmap))) return;
        img->owner = w;
        img->generation = w->generation;
    }
    w->rt->DrawBitmap(img->bitmap, D2D1::RectF((float)x, (float)y, (float)(x + width), (float)(y + height)), w->alpha,
                      D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
}

#endif
