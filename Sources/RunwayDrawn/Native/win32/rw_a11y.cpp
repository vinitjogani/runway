// UI Automation for drawn windows: each element of the tree the Swift half
// sends (rw_window_set_a11y) is a UIA fragment with its control type, name,
// help text, states and patterns (Invoke, Toggle, Value, RangeValue,
// SelectionItem), found by a stable id so clients' cached elements survive
// updates. The window answers WM_GETOBJECT with the root; the first request
// asks the Swift half for the tree (RW_EV_A11Y_WANTED). Actions run after
// the UIA call returns, as posted messages, the way controls do.
#ifdef _WIN32
#include "rw_internal.h"
#include <uiautomation.h>
#include <memory>
#include <string>
#include <unordered_map>

namespace {

struct Node {
    int parent;
    int role;
    unsigned states;
    double x, y, width, height;
    std::wstring name, value, hint, identifier;
    bool hasValue = false;
    std::vector<std::string> actions;
    bool hasRange = false;
    double number = 0, minimum = 0, maximum = 0;
    bool settable = false;
    long long uid;
    std::vector<int> children;
};

std::wstring wide(const char *s) {
    if (!s || !*s) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s, -1, &w[0], n);
    return w;
}

}  // namespace

/// A window's accessibility state, shared with its providers (which can
/// outlive it: then they answer that the element is gone).
struct RwA11yState {
    rw_window *window = nullptr;
    std::vector<Node> nodes;
    std::unordered_map<long long, int> byUid;
    long long focused = 0;
    bool wanted = false;
    // Requests to run once the UIA call has returned.
    struct Request { long long uid; int type; int action; std::string text; };
    std::vector<Request> pending;

    const Node *find(long long uid, int *index = nullptr) const {
        auto it = byUid.find(uid);
        if (it == byUid.end()) return nullptr;
        if (index) *index = it->second;
        return &nodes[it->second];
    }
};

#define RW_WM_A11Y (WM_APP + 0x51)

namespace {

class Provider : public IRawElementProviderSimple, public IRawElementProviderFragment, public IRawElementProviderFragmentRoot,
                 public IInvokeProvider, public IToggleProvider, public IValueProvider, public IRangeValueProvider,
                 public ISelectionItemProvider {
public:
    Provider(std::shared_ptr<RwA11yState> s, long long uid) : state(std::move(s)), uid(uid) {}

    // IUnknown
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG r = InterlockedDecrement(&refs);
        if (r == 0) delete this;
        return r;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IRawElementProviderSimple)) *out = static_cast<IRawElementProviderSimple *>(this);
        else if (riid == __uuidof(IRawElementProviderFragment)) *out = static_cast<IRawElementProviderFragment *>(this);
        else if (riid == __uuidof(IRawElementProviderFragmentRoot) && isRoot()) *out = static_cast<IRawElementProviderFragmentRoot *>(this);
        else if (riid == __uuidof(IInvokeProvider)) *out = static_cast<IInvokeProvider *>(this);
        else if (riid == __uuidof(IToggleProvider)) *out = static_cast<IToggleProvider *>(this);
        else if (riid == __uuidof(IValueProvider)) *out = static_cast<IValueProvider *>(this);
        else if (riid == __uuidof(IRangeValueProvider)) *out = static_cast<IRangeValueProvider *>(this);
        else if (riid == __uuidof(ISelectionItemProvider)) *out = static_cast<ISelectionItemProvider *>(this);
        else return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }

    // IRawElementProviderSimple
    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions *r) override {
        *r = (ProviderOptions)(ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID id, IUnknown **r) override {
        *r = nullptr;
        const Node *n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        bool checkable = (n->states & RW_STATE_CHECKABLE) != 0;
        bool tab = n->role == RW_ROLE_TOGGLEBUTTON && parentRole(n) == RW_ROLE_TABLIST;
        bool supported = false;
        switch (id) {
        case UIA_InvokePatternId: supported = !checkable && hasAction(n, "default"); break;
        case UIA_TogglePatternId: supported = checkable && !tab; break;
        case UIA_SelectionItemPatternId: supported = tab; break;
        case UIA_ValuePatternId: supported = n->settable || (n->hasValue && !n->hasRange); break;
        case UIA_RangeValuePatternId: supported = n->hasRange; break;
        }
        if (supported) { *r = static_cast<IRawElementProviderSimple *>(this); AddRef(); }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID id, VARIANT *r) override {
        VariantInit(r);
        const Node *n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        auto str = [&](const std::wstring &s) { r->vt = VT_BSTR; r->bstrVal = SysAllocString(s.c_str()); };
        auto boolean = [&](bool b) { r->vt = VT_BOOL; r->boolVal = b ? VARIANT_TRUE : VARIANT_FALSE; };
        auto integer = [&](int i) { r->vt = VT_I4; r->lVal = i; };
        switch (id) {
        case UIA_ControlTypePropertyId: integer(controlType(n)); break;
        case UIA_NamePropertyId: if (!n->name.empty()) str(n->name); break;
        case UIA_HelpTextPropertyId: if (!n->hint.empty()) str(n->hint); break;
        case UIA_AutomationIdPropertyId: if (!n->identifier.empty()) str(n->identifier); break;
        case UIA_FrameworkIdPropertyId: str(L"Runway"); break;
        case UIA_IsEnabledPropertyId: boolean(!(n->states & RW_STATE_DISABLED)); break;
        case UIA_IsKeyboardFocusablePropertyId: boolean((n->states & RW_STATE_FOCUSABLE) != 0); break;
        case UIA_HasKeyboardFocusPropertyId: boolean((n->states & RW_STATE_FOCUSED) != 0); break;
        case UIA_IsPasswordPropertyId: boolean((n->states & RW_STATE_PROTECTED) != 0); break;
        case UIA_IsOffscreenPropertyId: boolean(false); break;
        case UIA_IsControlElementPropertyId: boolean(n->role != RW_ROLE_GROUP || !n->name.empty()); break;
        case UIA_IsContentElementPropertyId: boolean(n->role != RW_ROLE_GROUP || !n->name.empty()); break;
        case UIA_HeadingLevelPropertyId: if (n->role == RW_ROLE_HEADING) integer(HeadingLevel2); break;
        case UIA_LocalizedControlTypePropertyId:
            if (n->role == RW_ROLE_SWITCH) str(L"switch");
            else if (n->role == RW_ROLE_HEADING) str(L"heading");
            break;
        case UIA_IsDialogPropertyId: if (n->states & RW_STATE_MODAL) boolean(true); break;
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **r) override {
        *r = nullptr;
        if (isRoot() && state->window && state->window->hwnd) return UiaHostProviderFromHwnd(state->window->hwnd, r);
        return S_OK;
    }

    // IRawElementProviderFragment
    HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection d, IRawElementProviderFragment **r) override {
        *r = nullptr;
        int index;
        const Node *n = state->find(uid, &index);
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        int target = -1;
        if (d == NavigateDirection_Parent) target = n->parent;
        else if (d == NavigateDirection_FirstChild) target = n->children.empty() ? -1 : n->children.front();
        else if (d == NavigateDirection_LastChild) target = n->children.empty() ? -1 : n->children.back();
        else if (n->parent >= 0) {
            const auto &sib = state->nodes[n->parent].children;
            for (size_t i = 0; i < sib.size(); i++) if (sib[i] == index) {
                if (d == NavigateDirection_NextSibling && i + 1 < sib.size()) target = sib[i + 1];
                if (d == NavigateDirection_PreviousSibling && i > 0) target = sib[i - 1];
            }
        }
        if (target >= 0) *r = new Provider(state, state->nodes[target].uid);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY **r) override {
        *r = nullptr;
        if (isRoot()) return S_OK;   // the host window's id stands
        int ids[3] = {UiaAppendRuntimeId, (int)(uid & 0x7fffffff), (int)((uid >> 31) & 0x7fffffff)};
        SAFEARRAY *a = SafeArrayCreateVector(VT_I4, 0, 3);
        if (!a) return E_OUTOFMEMORY;
        for (LONG i = 0; i < 3; i++) SafeArrayPutElement(a, &i, &ids[i]);
        *r = a;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect *r) override {
        *r = {};
        const Node *n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        rw_window *w = state->window;
        if (!w || !w->hwnd) return S_OK;
        POINT o = {0, 0};
        ClientToScreen(w->hwnd, &o);
        double s = w->scale();
        *r = {o.x + n->x * s, o.y + n->y * s, n->width * s, n->height * s};
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY **r) override { *r = nullptr; return S_OK; }
    HRESULT STDMETHODCALLTYPE SetFocus() override { return request(RW_EV_A11Y_FOCUS, 0); }
    HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot **r) override {
        *r = nullptr;
        if (!state->window) return UIA_E_ELEMENTNOTAVAILABLE;
        if (state->nodes.empty()) return S_OK;
        *r = new Provider(state, state->nodes[0].uid);
        return S_OK;
    }

    // IRawElementProviderFragmentRoot
    HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(double sx, double sy, IRawElementProviderFragment **r) override {
        *r = nullptr;
        rw_window *w = state->window;
        if (!w || !w->hwnd || state->nodes.empty()) return S_OK;
        POINT p = {(LONG)sx, (LONG)sy};
        ScreenToClient(w->hwnd, &p);
        double x = p.x / w->scale(), y = p.y / w->scale();
        // The deepest element containing the point; later siblings are in front.
        int at = 0;
        for (bool descended = true; descended;) {
            descended = false;
            const auto &kids = state->nodes[at].children;
            for (auto it = kids.rbegin(); it != kids.rend(); ++it) {
                const Node &c = state->nodes[*it];
                if (x >= c.x && y >= c.y && x < c.x + c.width && y < c.y + c.height) { at = *it; descended = true; break; }
            }
        }
        *r = new Provider(state, state->nodes[at].uid);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment **r) override {
        *r = nullptr;
        for (const Node &n : state->nodes)
            if (n.states & RW_STATE_FOCUSED) { *r = new Provider(state, n.uid); break; }
        return S_OK;
    }

    // IInvokeProvider
    HRESULT STDMETHODCALLTYPE Invoke() override { return action("default"); }

    // IToggleProvider
    HRESULT STDMETHODCALLTYPE Toggle() override { return action("default"); }
    HRESULT STDMETHODCALLTYPE get_ToggleState(ToggleState *r) override {
        const Node *n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        *r = (n->states & RW_STATE_MIXED) ? ToggleState_Indeterminate : (n->states & RW_STATE_CHECKED) ? ToggleState_On : ToggleState_Off;
        return S_OK;
    }

    // IValueProvider
    HRESULT STDMETHODCALLTYPE SetValue(LPCWSTR v) override {
        const Node *n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!n->settable) return UIA_E_ELEMENTNOTENABLED;
        int len = WideCharToMultiByte(CP_UTF8, 0, v, -1, nullptr, 0, nullptr, nullptr);
        std::string s(len > 0 ? len - 1 : 0, '\0');
        if (len > 1) WideCharToMultiByte(CP_UTF8, 0, v, -1, &s[0], len, nullptr, nullptr);
        return request(RW_EV_A11Y_SET, 0, s);
    }
    HRESULT STDMETHODCALLTYPE get_Value(BSTR *r) override {
        const Node *n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        *r = SysAllocString(n->value.c_str());
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL *r) override {
        const Node *n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        // Shared with IRangeValueProvider: a range that steps is adjustable.
        *r = n->settable || (n->hasRange && hasAction(n, "increment")) ? FALSE : TRUE;
        return S_OK;
    }

    // IRangeValueProvider (get_Value and get_IsReadOnly clash with
    // IValueProvider's names; these are the range versions).
    HRESULT STDMETHODCALLTYPE SetValue(double v) override {
        const Node *n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        // Steps toward the value with the element's increment and decrement.
        if (v > n->number && hasAction(n, "increment")) return action("increment");
        if (v < n->number && hasAction(n, "decrement")) return action("decrement");
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_Value(double *r) override { const Node *n = node(); if (!n) return UIA_E_ELEMENTNOTAVAILABLE; *r = n->number; return S_OK; }
    HRESULT STDMETHODCALLTYPE get_Maximum(double *r) override { const Node *n = node(); if (!n) return UIA_E_ELEMENTNOTAVAILABLE; *r = n->maximum; return S_OK; }
    HRESULT STDMETHODCALLTYPE get_Minimum(double *r) override { const Node *n = node(); if (!n) return UIA_E_ELEMENTNOTAVAILABLE; *r = n->minimum; return S_OK; }
    HRESULT STDMETHODCALLTYPE get_LargeChange(double *r) override { *r = 0; return S_OK; }
    HRESULT STDMETHODCALLTYPE get_SmallChange(double *r) override { *r = 0; return S_OK; }

    // ISelectionItemProvider (tabs)
    HRESULT STDMETHODCALLTYPE Select() override { return action("default"); }
    HRESULT STDMETHODCALLTYPE AddToSelection() override { return action("default"); }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL *r) override {
        const Node *n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        *r = (n->states & (RW_STATE_SELECTED | RW_STATE_CHECKED)) ? TRUE : FALSE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_SelectionContainer(IRawElementProviderSimple **r) override {
        *r = nullptr;
        const Node *n = node();
        if (n && n->parent >= 0) *r = new Provider(state, state->nodes[n->parent].uid);
        return S_OK;
    }

private:
    std::shared_ptr<RwA11yState> state;
    long long uid;
    LONG refs = 1;

    const Node *node() const { return state->window ? state->find(uid) : nullptr; }
    bool isRoot() const { return !state->nodes.empty() && state->nodes[0].uid == uid; }
    int parentRole(const Node *n) const { return n->parent >= 0 ? state->nodes[n->parent].role : -1; }
    static bool hasAction(const Node *n, const char *name) {
        for (auto &a : n->actions) if (a == name) return true;
        return false;
    }
    HRESULT action(const char *name) {
        const Node *n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        if (n->states & RW_STATE_DISABLED) return UIA_E_ELEMENTNOTENABLED;
        for (size_t k = 0; k < n->actions.size(); k++)
            if (n->actions[k] == name || (k == 0 && strcmp(name, "default") == 0)) return request(RW_EV_A11Y_ACTION, (int)k);
        return UIA_E_INVALIDOPERATION;
    }
    HRESULT request(int type, int actionIndex, std::string text = std::string()) {
        if (!node()) return UIA_E_ELEMENTNOTAVAILABLE;
        state->pending.push_back({uid, type, actionIndex, std::move(text)});
        PostMessageW(state->window->hwnd, RW_WM_A11Y, 0, 0);
        return S_OK;
    }
    long controlType(const Node *n) const {
        switch (n->role) {
        case RW_ROLE_BUTTON: case RW_ROLE_COLORWELL: return UIA_ButtonControlTypeId;
        case RW_ROLE_MENUBUTTON: return UIA_SplitButtonControlTypeId;
        case RW_ROLE_CHECKBOX: case RW_ROLE_SWITCH: return UIA_CheckBoxControlTypeId;
        case RW_ROLE_TEXT: case RW_ROLE_HEADING: return UIA_TextControlTypeId;
        case RW_ROLE_TEXTFIELD: case RW_ROLE_TEXTAREA: case RW_ROLE_SEARCHFIELD: return UIA_EditControlTypeId;
        case RW_ROLE_IMAGE: return UIA_ImageControlTypeId;
        case RW_ROLE_LINK: return UIA_HyperlinkControlTypeId;
        case RW_ROLE_SLIDER: return UIA_SliderControlTypeId;
        case RW_ROLE_COMBOBOX: return UIA_ComboBoxControlTypeId;
        case RW_ROLE_TABLIST: return UIA_TabControlTypeId;
        case RW_ROLE_PROGRESS: return UIA_ProgressBarControlTypeId;
        case RW_ROLE_STEPPER: return UIA_SpinnerControlTypeId;
        case RW_ROLE_SEPARATOR: return UIA_SeparatorControlTypeId;
        case RW_ROLE_TOGGLEBUTTON: return parentRole(n) == RW_ROLE_TABLIST ? UIA_TabItemControlTypeId : UIA_ButtonControlTypeId;
        case RW_ROLE_WINDOW: case RW_ROLE_SCROLLAREA: return UIA_PaneControlTypeId;
        default: return UIA_GroupControlTypeId;
        }
    }
};

}  // namespace

static std::shared_ptr<RwA11yState> &stateFor(rw_window *w) {
    if (!w->a11y) { w->a11y = std::make_shared<RwA11yState>(); w->a11y->window = w; }
    return w->a11y;
}

extern "C" void rw_window_set_a11y(rw_window *w, const rw_a11y_node *nodes, int count) {
    if (!w || count <= 0) return;
    auto &s = stateFor(w);
    std::vector<Node> list(count);
    s->byUid.clear();
    long long focused = 0;
    for (int i = 0; i < count; i++) {
        const rw_a11y_node &n = nodes[i];
        Node &d = list[i];
        d.parent = (n.parent >= 0 && n.parent < i) ? n.parent : (i == 0 ? -1 : 0);
        d.role = n.role; d.states = n.states;
        d.x = n.x; d.y = n.y; d.width = n.width; d.height = n.height;
        d.name = wide(n.name); d.value = wide(n.value); d.hint = wide(n.hint); d.identifier = wide(n.identifier);
        d.hasValue = n.value != nullptr;
        if (n.actions) {
            std::string all(n.actions);
            size_t start = 0;
            while (start <= all.size()) {
                size_t end = all.find('\n', start);
                if (end == std::string::npos) end = all.size();
                if (end > start) d.actions.push_back(all.substr(start, end - start));
                start = end + 1;
            }
        }
        d.hasRange = n.has_range != 0; d.number = n.number; d.minimum = n.minimum; d.maximum = n.maximum;
        d.settable = n.settable != 0;
        d.uid = n.uid ? n.uid : i + 1;
        if (d.parent >= 0) list[d.parent].children.push_back(i);
        if (n.states & RW_STATE_FOCUSED) focused = d.uid;
        s->byUid[d.uid] = i;
    }
    s->nodes = std::move(list);
    // Diagnostics: RUNWAY_A11Y_INVOKE=<name> invokes that element once,
    // through the same provider interfaces a UIA client uses.
    static bool diagnosed = false;
    if (!diagnosed) {
        wchar_t want[256];
        if (GetEnvironmentVariableW(L"RUNWAY_A11Y_INVOKE", want, 256) > 0) {
            for (const Node &n : s->nodes) if (n.name == want) {
                diagnosed = true;
                auto *p = new Provider(s, n.uid);
                IInvokeProvider *inv = nullptr, *viaPattern = nullptr;
                IUnknown *pattern = nullptr;
                p->GetPatternProvider(UIA_InvokePatternId, &pattern);
                if (pattern) { pattern->QueryInterface(__uuidof(IInvokeProvider), (void **)&viaPattern); pattern->Release(); }
                inv = viaPattern;
                HRESULT hr = inv ? inv->Invoke() : E_NOINTERFACE;
                fprintf(stderr, "a11y: invoke \"%ls\": %lx\n", want, hr);
                if (inv) inv->Release();
                p->Release();
                break;
            }
        }
    }
    if (!w->hwnd || !UiaClientsAreListening()) { s->focused = focused; return; }
    auto *root = new Provider(s, s->nodes[0].uid);
    UiaRaiseStructureChangedEvent(root, StructureChangeType_ChildrenInvalidated, nullptr, 0);
    root->Release();
    if (focused && focused != s->focused) {
        auto *p = new Provider(s, focused);
        UiaRaiseAutomationEvent(p, UIA_AutomationFocusChangedEventId);
        p->Release();
    }
    s->focused = focused;
}

extern "C" int rw_window_a11y_wanted(rw_window *w) { return w && w->a11y && w->a11y->wanted ? 1 : 0; }

extern "C" void rw_set_app_name(const char *name) { (void)name; }

/// WM_GETOBJECT: the root element, asking the Swift half for the tree the first time.
bool rwA11yGetObject(rw_window *w, WPARAM wp, LPARAM lp, LRESULT *result) {
    if ((long)lp != UiaRootObjectId) return false;
    auto &s = stateFor(w);
    if (!s->wanted) {
        s->wanted = true;
        rwSend(RW_EV_A11Y_WANTED, w->ctx);
    }
    if (s->nodes.empty()) return false;
    auto *root = new Provider(s, s->nodes[0].uid);
    *result = UiaReturnRawElementProvider(w->hwnd, wp, lp, root);
    root->Release();
    return true;
}

/// RW_WM_A11Y: runs the requests UIA calls queued.
void rwA11yRunPending(rw_window *w) {
    if (!w->a11y) return;
    auto pending = std::move(w->a11y->pending);
    w->a11y->pending.clear();
    for (auto &r : pending) {
        int index;
        if (!w->a11y->find(r.uid, &index)) continue;
        rw_event ev = {};
        ev.type = r.type;
        ev.ctx = w->ctx;
        ev.clicks = index;
        ev.key = r.action;
        ev.text = r.text.c_str();
        rwSendEvent(ev);
    }
}

/// The window is going: providers clients still hold answer that it's gone.
void rwA11yWindowGone(rw_window *w) {
    if (!w->a11y) return;
    w->a11y->window = nullptr;
    w->a11y->nodes.clear();
    w->a11y->byUid.clear();
    w->a11y.reset();
}
#endif
