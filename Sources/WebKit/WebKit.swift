// WebKit for Linux: WKWebView over WebKitGTK 6 (a WebKitWebView widget
// inside the view's native container), with WKWebViewConfiguration, the
// user content controller (script message handlers, user scripts),
// navigation and UI delegates, JavaScript evaluation and HTML/URL loading.
// Without WebKitGTK (Windows: WebView2 would be the native route, not wired
// up yet) the view loads nothing and calls fail through WKError.
//
// Hosting: WKWebView manages its own content (`managesOwnContent`), so
// AppKit leaves its container alone; the web view widget is placed in the
// container and resized with the view.

@_exported import AppKit
@_exported import Foundation
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif
import CRunwayWebKit
#if os(Linux)
import CGtk
import CRunwayGtk
#endif

public let WKErrorDomain = "WKErrorDomain"

public struct WKError: CustomNSError, Hashable, Sendable {
    public enum Code: Int, Sendable {
        case unknown = 1, webContentProcessTerminated, webViewInvalidated, javaScriptExceptionOccurred, javaScriptResultTypeIsUnsupported
        case contentRuleListStoreCompileFailed, contentRuleListStoreLookUpFailed, contentRuleListStoreRemoveFailed, contentRuleListStoreVersionMismatch
        case attributedStringContentFailedToLoad, attributedStringContentLoadTimedOut, javaScriptInvalidFrameTarget, navigationAppBoundDomain
        case javaScriptAppBoundDomain, duplicateCredential, malformedCredential, credentialNotFound
    }
    public let code: Code
    let message: String
    public init(_ code: Code, _ message: String = "") { self.code = code; self.message = message }
    public static var errorDomain: String { WKErrorDomain }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message.isEmpty ? "Web content error \(code.rawValue)" : message] }
}

// MARK: Configuration

public enum WKUserScriptInjectionTime: Int, Sendable { case atDocumentStart = 0, atDocumentEnd }

public final class WKUserScript: NSObject, @unchecked Sendable {
    public let source: String
    public let injectionTime: WKUserScriptInjectionTime
    public let isForMainFrameOnly: Bool
    public init(source: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool) {
        self.source = source; self.injectionTime = injectionTime; isForMainFrameOnly = forMainFrameOnly
        super.init()
    }
    public convenience init(source: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool, in contentWorld: WKContentWorld) {
        self.init(source: source, injectionTime: injectionTime, forMainFrameOnly: forMainFrameOnly)
    }
}

public final class WKContentWorld: NSObject, @unchecked Sendable {
    public let name: String?
    init(name: String?) { self.name = name; super.init() }
    public static let page = WKContentWorld(name: nil)
    public static let defaultClient = WKContentWorld(name: "defaultClient")
    public static func world(name: String) -> WKContentWorld { WKContentWorld(name: name) }
}

@preconcurrency @MainActor
public protocol WKScriptMessageHandler: AnyObject {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage)
}

@preconcurrency @MainActor
public protocol WKScriptMessageHandlerWithReply: AnyObject {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void)
}

@preconcurrency @MainActor
open class WKScriptMessage: NSObject {
    public let body: Any
    public let name: String
    open private(set) weak var webView: WKWebView?
    public let frameInfo: WKFrameInfo
    public let world = WKContentWorld.page
    init(body: Any, name: String, webView: WKWebView?) {
        self.body = body; self.name = name; self.webView = webView; frameInfo = WKFrameInfo(main: true, request: URLRequest(url: URL(string: "about:blank")!))
        super.init()
    }
}

@preconcurrency @MainActor
open class WKUserContentController: NSObject {
    let manager: UnsafeMutableRawPointer?
    open private(set) var userScripts: [WKUserScript] = []
    private var handlers: [String: WKScriptMessageHandler] = [:]
    weak var webView: WKWebView?
    private var boxes: [String: Unmanaged<Box>] = [:]

    final class Box { weak var owner: WKUserContentController?; init(_ o: WKUserContentController) { owner = o } }

    public override init() {
        manager = rw_ucm_new()
        super.init()
    }
    deinit {
        for (_, b) in boxes { b.release() }
        rw_unref(manager)
    }

    open func add(_ scriptMessageHandler: WKScriptMessageHandler, name: String) {
        handlers[name] = scriptMessageHandler
        guard let manager, boxes[name] == nil else { return }
        let box = Unmanaged.passRetained(Box(self))
        boxes[name] = box
        _ = rw_register_handler(manager, name, { ctx, name, json in
            guard let ctx, let name else { return }
            let owner = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue().owner
            let n = String(cString: name), body = json.map { String(cString: $0) } ?? "null"
            MainActor.assumeIsolated { owner?.receive(n, body) }
        }, box.toOpaque())
    }
    open func add(_ scriptMessageHandler: WKScriptMessageHandler, contentWorld world: WKContentWorld, name: String) { add(scriptMessageHandler, name: name) }
    open func addScriptMessageHandler(_ handler: WKScriptMessageHandlerWithReply, contentWorld: WKContentWorld, name: String) {}
    open func removeScriptMessageHandler(forName name: String) {
        handlers[name] = nil
        if let manager { rw_unregister_handler(manager, name) }
        boxes.removeValue(forKey: name)?.release()
    }
    open func removeScriptMessageHandler(forName name: String, contentWorld: WKContentWorld) { removeScriptMessageHandler(forName: name) }
    open func removeAllScriptMessageHandlers() { for n in Array(handlers.keys) { removeScriptMessageHandler(forName: n) } }
    open func addUserScript(_ s: WKUserScript) {
        userScripts.append(s)
        if let manager { rw_add_user_script(manager, s.source, s.injectionTime == .atDocumentStart ? 1 : 0, s.isForMainFrameOnly ? 1 : 0) }
    }
    open func removeAllUserScripts() {
        userScripts.removeAll()
        if let manager { rw_remove_all_user_scripts(manager) }
    }
    open func add(_ contentRuleList: AnyObject) {}

    func receive(_ name: String, _ json: String) {
        guard let h = handlers[name] else { return }
        h.userContentController(self, didReceive: WKScriptMessage(body: decodeJSON(json) ?? NSNull(), name: name, webView: webView))
    }
}

/// A JSON value (from JavaScriptCore) as Foundation objects, as WebKit hands them over.
func decodeJSON(_ json: String) -> Any? {
    guard let d = json.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
}

@preconcurrency @MainActor
open class WKPreferences: NSObject {
    open var javaScriptCanOpenWindowsAutomatically = false
    open var isFraudulentWebsiteWarningEnabled = true
    open var isElementFullscreenEnabled = false
    open var minimumFontSize: CGFloat = 0
    open var javaScriptEnabled = true
    open var tabFocusesLinks = false
    open var isTextInteractionEnabled = true
    open var isSiteSpecificQuirksModeEnabled = true
    public override init() { super.init() }
}

@preconcurrency @MainActor
open class WKWebpagePreferences: NSObject {
    open var allowsContentJavaScript = true
    open var preferredContentMode: ContentMode = .recommended
    public enum ContentMode: Int, Sendable { case recommended = 0, mobile, desktop }
    public override init() { super.init() }
}

@preconcurrency @MainActor
open class WKWebsiteDataStore: NSObject {
    public let isPersistent: Bool
    init(persistent: Bool) { isPersistent = persistent; super.init() }
    public static func `default`() -> WKWebsiteDataStore { WKWebsiteDataStore(persistent: true) }
    public static func nonPersistent() -> WKWebsiteDataStore { WKWebsiteDataStore(persistent: false) }
    public static func allWebsiteDataTypes() -> Set<String> { [] }
    open var httpCookieStore: WKHTTPCookieStore { WKHTTPCookieStore() }
    open func removeData(ofTypes dataTypes: Set<String>, modifiedSince date: Date, completionHandler: @escaping @MainActor () -> Void) { completionHandler() }
    open func fetchDataRecords(ofTypes dataTypes: Set<String>, completionHandler: @escaping @MainActor ([AnyObject]) -> Void) { completionHandler([]) }
}

@preconcurrency @MainActor
open class WKHTTPCookieStore: NSObject {
    open func getAllCookies(_ completionHandler: @escaping @MainActor ([HTTPCookie]) -> Void) { completionHandler([]) }
    open func setCookie(_ cookie: HTTPCookie, completionHandler: (@MainActor () -> Void)? = nil) { completionHandler?() }
    open func delete(_ cookie: HTTPCookie, completionHandler: (@MainActor () -> Void)? = nil) { completionHandler?() }
}

@preconcurrency @MainActor
public protocol WKURLSchemeHandler: AnyObject {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask)
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask)
}
public protocol WKURLSchemeTask: AnyObject {
    var request: URLRequest { get }
    func didReceive(_ response: URLResponse)
    func didReceive(_ data: Data)
    func didFinish()
    func didFailWithError(_ error: Error)
}

@preconcurrency @MainActor
open class WKWebViewConfiguration: NSObject {
    open var userContentController = WKUserContentController()
    open var preferences = WKPreferences()
    open var defaultWebpagePreferences = WKWebpagePreferences()
    open var websiteDataStore = WKWebsiteDataStore.default()
    open var applicationNameForUserAgent: String?
    open var suppressesIncrementalRendering = false
    open var allowsAirPlayForMediaPlayback = false
    open var mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes = .all
    open var upgradeKnownHostsToHTTPS = true
    open var limitsNavigationsToAppBoundDomains = false
    private(set) var schemeHandlers: [String: WKURLSchemeHandler] = [:]
    public override init() { super.init() }
    /// Recorded; custom schemes aren't routed to handlers yet on Linux.
    open func setURLSchemeHandler(_ urlSchemeHandler: WKURLSchemeHandler?, forURLScheme urlScheme: String) { schemeHandlers[urlScheme] = urlSchemeHandler }
    open func urlSchemeHandler(forURLScheme urlScheme: String) -> WKURLSchemeHandler? { schemeHandlers[urlScheme] }
}

public struct WKAudiovisualMediaTypes: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let audio = Self(rawValue: 1), video = Self(rawValue: 2), all = Self(rawValue: ~0)
}

// MARK: Navigation

public enum WKNavigationType: Int, Sendable { case linkActivated = 0, formSubmitted, backForward, reload, formResubmitted, other = -1 }
public enum WKNavigationActionPolicy: Int, Sendable { case cancel = 0, allow = 1, download = 2 }
public enum WKNavigationResponsePolicy: Int, Sendable { case cancel = 0, allow = 1, download = 2 }

@preconcurrency @MainActor
open class WKNavigation: NSObject {
    open var effectiveContentMode: WKWebpagePreferences.ContentMode { .recommended }
}

@preconcurrency @MainActor
open class WKFrameInfo: NSObject {
    public let isMainFrame: Bool
    public let request: URLRequest
    open weak var webView: WKWebView?
    init(main: Bool, request: URLRequest) { isMainFrame = main; self.request = request; super.init() }
}

@preconcurrency @MainActor
open class WKNavigationAction: NSObject {
    public let request: URLRequest
    public let navigationType: WKNavigationType
    public let targetFrame: WKFrameInfo?
    public let sourceFrame: WKFrameInfo
    public let modifierFlags: NSEvent.ModifierFlags = []
    public let buttonNumber = 0
    open var shouldPerformDownload: Bool { false }
    init(request: URLRequest, type: WKNavigationType, newWindow: Bool) {
        self.request = request
        navigationType = type
        targetFrame = newWindow ? nil : WKFrameInfo(main: true, request: request)
        sourceFrame = WKFrameInfo(main: true, request: request)
        super.init()
    }
}

@preconcurrency @MainActor
open class WKNavigationResponse: NSObject {
    public let response: URLResponse
    public let isForMainFrame = true
    public let canShowMIMEType = true
    init(response: URLResponse) { self.response = response; super.init() }
}

@preconcurrency @MainActor
public protocol WKNavigationDelegate: AnyObject {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void)
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void)
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!)
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!)
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error)
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!)
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error)
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView)
}
extension WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {}
    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {}
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {}
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {}
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {}
}

@preconcurrency @MainActor
public protocol WKUIDelegate: AnyObject {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView?
    func webViewDidClose(_ webView: WKWebView)
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void)
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void)
}
extension WKUIDelegate {
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    public func webViewDidClose(_ webView: WKWebView) {}
    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor () -> Void) { completionHandler() }
    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }
}

@preconcurrency @MainActor
open class WKWindowFeatures: NSObject {}

@preconcurrency @MainActor
open class WKSnapshotConfiguration: NSObject {
    open var rect: CGRect = .null
    open var snapshotWidth: NSNumber?
    open var afterScreenUpdates = true
    public override init() { super.init() }
}

@preconcurrency @MainActor
open class WKFindConfiguration: NSObject {
    open var backwards = false
    open var caseSensitive = false
    open var wraps = true
    public override init() { super.init() }
}

// MARK: The view

@preconcurrency @MainActor
open class WKWebView: NSView {
    public let configuration: WKWebViewConfiguration
    open weak var navigationDelegate: WKNavigationDelegate?
    open weak var uiDelegate: WKUIDelegate?
    open var allowsBackForwardNavigationGestures = false
    open var allowsMagnification = false
    open var allowsLinkPreview = false
    open var isInspectable = false
    open var underPageBackgroundColor: NSColor?
    open var customUserAgent: String? { didSet { if let v = view { rw_set_user_agent(v, customUserAgent ?? "") } } }
    nonisolated(unsafe) let view: UnsafeMutableRawPointer?
    private var box: Unmanaged<Box>?
    private var placed = false
    final class Box { weak var owner: WKWebView?; init(_ o: WKWebView) { owner = o } }

    public init(frame: CGRect, configuration: WKWebViewConfiguration) {
        let js = configuration.preferences.javaScriptEnabled && configuration.defaultWebpagePreferences.allowsContentJavaScript
        self.configuration = configuration
        view = configuration.userContentController.manager.flatMap { rw_webview_new($0, js ? 1 : 0, 0) }
        super.init(frame: frame)
        setUp()
    }
    public override convenience init(frame: CGRect) {
        self.init(frame: frame, configuration: WKWebViewConfiguration())
    }
    public required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }
    isolated deinit {
        box?.release()
        rw_unref(view)
    }

    open override var managesOwnContent: Bool { true }

    private func setUp() {
        configuration.userContentController.webView = self
        guard let view else { return }
        let b = Unmanaged.passRetained(Box(self))
        box = b
        rw_connect_load(view, { ctx, event, _, error, code in
            guard let ctx else { return }
            let owner = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue().owner
            let message = error.map { String(cString: $0) }
            MainActor.assumeIsolated { owner?.loadEvent(event, message, Int(code)) }
        }, b.toOpaque())
        rw_connect_policy(view, { ctx, decision, uri, newWindow, type in
            guard let ctx, let decision else { return 0 }
            let owner = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue().owner
            let u = uri.map { String(cString: $0) } ?? "about:blank"
            return MainActor.assumeIsolated { owner?.decide(decision, u, newWindow != 0, Int(type)) ?? 0 }
        }, b.toOpaque())
        place()
    }

    /// Puts the web view widget in this view's container, at its size.
    private func place() {
        #if os(Linux)
        guard let view else { return }
        var canvas: UnsafeMutablePointer<GtkWidget>?
        for c in Mirror(reflecting: widget).children where c.label == "canvas" || c.label == "outer" {
            if let w = c.value as? UnsafeMutablePointer<GtkWidget>?, let w { canvas = canvas ?? w }
            if let w = c.value as? UnsafeMutablePointer<GtkWidget>, c.label == "canvas" { canvas = w }
        }
        guard let canvas else { return }
        runway_canvas_place(canvas, view.assumingMemoryBound(to: GtkWidget.self), 0, 0, Int32(frame.width), Int32(frame.height))
        placed = true
        #endif
    }

    open override func frameSizeChanged(from old: CGSize) {
        super.frameSizeChanged(from: old)
        place()
    }

    private var navigation: WKNavigation?

    private func loadEvent(_ event: Int32, _ message: String?, _ code: Int) {
        let nav = navigation ?? WKNavigation()
        switch event {
        case Int32(RW_LOAD_STARTED):
            navigation = nav
            navigationDelegate?.webView(self, didStartProvisionalNavigation: nav)
        case Int32(RW_LOAD_REDIRECTED): navigationDelegate?.webView(self, didReceiveServerRedirectForProvisionalNavigation: nav)
        case Int32(RW_LOAD_COMMITTED): navigationDelegate?.webView(self, didCommit: nav)
        case Int32(RW_LOAD_FINISHED):
            navigationDelegate?.webView(self, didFinish: nav)
            navigation = nil
        default:
            let e = NSError(domain: NSURLErrorDomain, code: code == 0 ? NSURLErrorUnknown : -code, userInfo: [NSLocalizedDescriptionKey: message ?? "The page couldn't be loaded."])
            navigationDelegate?.webView(self, didFailProvisionalNavigation: nav, withError: e)
            navigation = nil
        }
    }

    private func decide(_ decision: UnsafeMutableRawPointer, _ uri: String, _ newWindow: Bool, _ type: Int) -> Int32 {
        guard let delegate = navigationDelegate else { return 0 }
        let navType: WKNavigationType = switch Int32(type) {
        case Int32(RW_NAV_LINK): .linkActivated
        case Int32(RW_NAV_FORM): .formSubmitted
        case Int32(RW_NAV_BACK_FORWARD): .backForward
        case Int32(RW_NAV_RELOAD): .reload
        case Int32(RW_NAV_RESUBMIT): .formResubmitted
        default: .other
        }
        let action = WKNavigationAction(request: URLRequest(url: URL(string: uri) ?? URL(string: "about:blank")!), type: navType, newWindow: newWindow)
        let d = UncheckedPointer(decision)
        delegate.webView(self, decidePolicyFor: action) { policy in rw_policy_decide(d.pointer, policy == .allow ? 1 : 0) }
        return 1
    }

    // MARK: Loading

    @discardableResult
    open func load(_ request: URLRequest) -> WKNavigation? {
        guard let view, let u = request.url else { return nil }
        rw_load_uri(view, u.absoluteString)
        return WKNavigation()
    }
    @discardableResult
    open func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        guard let view else { return nil }
        rw_load_html(view, string, baseURL?.absoluteString)
        return WKNavigation()
    }
    @discardableResult
    open func loadFileURL(_ url: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? { load(URLRequest(url: url)) }
    @discardableResult
    open func load(_ data: Data, mimeType: String, characterEncodingName: String, baseURL: URL) -> WKNavigation? {
        if mimeType.hasPrefix("text/html"), let s = String(data: data, encoding: .utf8) { return loadHTMLString(s, baseURL: baseURL) }
        let url = URL(string: "data:\(mimeType);base64,\(data.base64EncodedString())")!
        return load(URLRequest(url: url))
    }
    @discardableResult
    open func reload() -> WKNavigation? { if let view { rw_reload(view) }; return WKNavigation() }
    @discardableResult
    open func reloadFromOrigin() -> WKNavigation? { reload() }
    open func stopLoading() { if let view { rw_stop(view) } }
    @discardableResult
    open func goBack() -> WKNavigation? { if let view { rw_go_back(view) }; return WKNavigation() }
    @discardableResult
    open func goForward() -> WKNavigation? { if let view { rw_go_forward(view) }; return WKNavigation() }

    open var canGoBack: Bool { view.map { rw_can_go_back($0) != 0 } ?? false }
    open var canGoForward: Bool { view.map { rw_can_go_forward($0) != 0 } ?? false }
    open var isLoading: Bool { view.map { rw_is_loading($0) != 0 } ?? false }
    open var estimatedProgress: Double { view.map { rw_progress($0) } ?? 0 }
    open var title: String? { view.flatMap { rw_title($0) }.map { String(cString: $0) } }
    open var url: URL? { view.flatMap { rw_uri($0) }.flatMap { URL(string: String(cString: $0)) } }
    open var hasOnlySecureContent: Bool { url?.scheme == "https" }
    open var pageZoom: CGFloat {
        get { CGFloat(view.map { rw_zoom($0) } ?? 1) }
        set { if let view { rw_set_zoom(view, Double(newValue)) } }
    }
    open var magnification: CGFloat {
        get { pageZoom }
        set { pageZoom = newValue }
    }
    open func setMagnification(_ magnification: CGFloat, centeredAt point: CGPoint) { pageZoom = magnification }

    // MARK: JavaScript

    open func evaluateJavaScript(_ javaScriptString: String, completionHandler: (@MainActor (Any?, Error?) -> Void)? = nil) {
        guard let view else {
            completionHandler?(nil, WKError(.webViewInvalidated, "Web views aren't available on this platform."))
            return
        }
        final class Call { let done: (@MainActor (Any?, Error?) -> Void)?; init(_ d: (@MainActor (Any?, Error?) -> Void)?) { done = d } }
        let call = Unmanaged.passRetained(Call(completionHandler))
        rw_evaluate(view, javaScriptString, { ctx, json, error in
            guard let ctx else { return }
            let c = Unmanaged<Call>.fromOpaque(ctx).takeRetainedValue()
            let result = json.map { String(cString: $0) }, message = error.map { String(cString: $0) }
            MainActor.assumeIsolated {
                if let message { c.done?(nil, WKError(.javaScriptExceptionOccurred, message)) } else { c.done?(result.flatMap(decodeJSON), nil) }
            }
        }, call.toOpaque())
    }
    open func evaluateJavaScript(_ javaScriptString: String, in frame: WKFrameInfo?, in contentWorld: WKContentWorld,
                                 completionHandler: (@MainActor (Result<Any, Error>) -> Void)? = nil) {
        evaluateJavaScript(javaScriptString) { v, e in completionHandler?(e.map { .failure($0) } ?? .success(v ?? NSNull())) }
    }
    open func evaluateJavaScript(_ javaScriptString: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<UncheckedValue, Error>) in
            evaluateJavaScript(javaScriptString) { v, e in
                if let e { c.resume(throwing: e) } else { c.resume(returning: UncheckedValue(v)) }
            }
        }.value
    }
    open func callAsyncJavaScript(_ functionBody: String, arguments: [String: Any] = [:], in frame: WKFrameInfo?, in contentWorld: WKContentWorld,
                                  completionHandler: (@MainActor (Result<Any, Error>) -> Void)? = nil) {
        let args = (try? JSONSerialization.data(withJSONObject: arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let names = arguments.keys.sorted()
        let script = "(async function(\(names.joined(separator: ","))) { \(functionBody) })(\(names.map { "(\(args))[\"\($0)\"]" }.joined(separator: ",")))"
        evaluateJavaScript(script, in: frame, in: contentWorld, completionHandler: completionHandler)
    }

    open func takeSnapshot(with snapshotConfiguration: WKSnapshotConfiguration?, completionHandler: @escaping @MainActor (NSImage?, Error?) -> Void) {
        completionHandler(nil, WKError(.unknown, "Snapshots aren't supported here yet."))
    }
    open func find(_ string: String, configuration: WKFindConfiguration?, completionHandler: @escaping @MainActor (AnyObject) -> Void) {}
    open class func handlesURLScheme(_ urlScheme: String) -> Bool { ["http", "https", "file", "about", "data", "blob"].contains(urlScheme.lowercased()) }
}

struct UncheckedPointer: @unchecked Sendable { let pointer: UnsafeMutableRawPointer; init(_ p: UnsafeMutableRawPointer) { pointer = p } }
struct UncheckedValue: @unchecked Sendable { let value: Any?; init(_ v: Any?) { value = v } }
